<#
.SYNOPSIS
    Compiles a D365 F&O X++ Visual Studio project (.rnrproj) from the command line with xppc
    and prints the diagnostics that matter for that project.

.DESCRIPTION
    X++ has no per-project compile unit: Visual Studio's "Build project" compiles the whole
    package (module) that the project's model belongs to, incrementally. This script does the
    same with xppc.exe, but writes the assemblies to a scratch folder, so the deployed binaries
    in PackagesLocalDirectory\<Package>\bin (used by the running AOS) are never touched. The
    scratch folder keeps its own incremental state, so it does not hide changes from the next
    Visual Studio build. The only shared state xppc updates is the package's gitignored
    XppMetadata compiler cache, the same one Visual Studio updates.

    The report contains:
      * pre-checks of the project's element files (missing file, malformed XML, BOM/line endings)
      * every compile error in the package, tagged [project] or [other]
      * warnings for project elements only (the rest are counted, or listed with -AllWarnings)
      * for class/table code, the XML file line and source text of each diagnostic

    Exit code: 0 = no errors, 1 = compile errors or unusable project files, 2 = setup failure.

.PARAMETER Project
    The .rnrproj file, or a folder containing exactly one.
.PARAMETER PackagesDir
    PackagesLocalDirectory. Auto-detected (<drive>:\AosService\PackagesLocalDirectory or $env:D365_PACKAGES_DIR).
.PARAMETER OutputDir
    Scratch output folder. Default: %TEMP%\xppc-scratch\<module>. Keep it stable so incremental builds stay fast.
.PARAMETER Full
    Full compile instead of incremental. Use before handing work back, after renames/deletes, or when
    you need every warning of the project elements (incremental only reports recompiled elements).
.PARAMETER RemoveStaleCache
    Delete XppMetadata cache files whose source element no longer exists (after renaming/deleting elements).
.PARAMETER AllWarnings
    Also list warnings for elements outside the project.
.PARAMETER CheckLabels
    Also check that every @File:Id / @SYS123 label referenced by the project elements exists, and that the
    model's label files have no duplicate IDs (xppc checks neither). Off by default: older code often references
    legacy label files that are not on the box, which makes the output noisy.

.EXAMPLE
    .\Invoke-XppProjectBuild.ps1 -Project C:\Repos\Contoso\Projects\ABC123_Feature\ABC123_Feature\ABC123_Feature.rnrproj
.EXAMPLE
    .\Invoke-XppProjectBuild.ps1 -Project C:\Repos\Contoso\Projects\ABC123_Feature -Full
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,
    [string]$PackagesDir,
    [string]$OutputDir,
    [switch]$Full,
    [switch]$RemoveStaleCache,
    [switch]$AllWarnings,
    [switch]$CheckLabels,
    [int]$MaxWarnings = 100
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'XppCommon.ps1')

# ---------------------------------------------------------------- source line mapping
# xppc reports class/table lines in Visual Studio's combined code view: the declaration without its
# closing brace, followed by every method body back to back. Rebuild that view from the CDATA blocks.
function Get-XppSourceSegments([string]$File) {
    $text = [System.IO.File]::ReadAllText($File)
    $rx = New-Object System.Text.RegularExpressions.Regex('<(Declaration|Source)><!\[CDATA\[(.*?)\]\]>', 'Singleline')
    $segments = New-Object System.Collections.Generic.List[object]
    $line = 1
    $pos = 0
    foreach ($m in $rx.Matches($text)) {
        $contentStart = $m.Groups[2].Index
        for ($i = $pos; $i -lt $contentStart; $i++) { if ($text[$i] -eq "`n") { $line++ } }
        $pos = $contentStart
        $content = $m.Groups[2].Value
        $first = $line
        if ($content.StartsWith("`r`n")) { $content = $content.Substring(2); $first++ }
        elseif ($content.StartsWith("`n")) { $content = $content.Substring(1); $first++ }
        if ($content.EndsWith("`r`n")) { $content = $content.Substring(0, $content.Length - 2) }
        elseif ($content.EndsWith("`n")) { $content = $content.Substring(0, $content.Length - 1) }
        $lines = @($content -split "`r?`n")
        if ($m.Groups[1].Value -eq 'Declaration' -and $lines.Count -gt 0 -and $lines[-1].Trim() -eq '}') {
            if ($lines.Count -eq 1) { $lines = @() } else { $lines = $lines[0..($lines.Count - 2)] }
        }
        $segments.Add([pscustomobject]@{ Kind = $m.Groups[1].Value; FirstFileLine = $first; Lines = $lines })
    }
    if ($segments.Count -eq 0 -or $segments[0].Kind -ne 'Declaration') { return $null }
    return $segments
}

function Resolve-XppSourceLine($Segments, [int]$Line, [int]$Column) {
    $remaining = $Line
    foreach ($s in $Segments) {
        if ($remaining -le $s.Lines.Count) {
            $text = $s.Lines[$remaining - 1]
            return [pscustomobject]@{
                FileLine = $s.FirstFileLine + $remaining - 1
                Text     = $text
                Suspect  = ($Column -gt $text.Length + 1)
            }
        }
        $remaining -= $s.Lines.Count
    }
    return $null
}

# ---------------------------------------------------------------- setup
try {
    $projectFile = Resolve-XppProjectFile $Project
    $proj = Read-XppProject $projectFile
    if (-not $proj.Model) { throw "No <Model> in $projectFile." }
    $pld = Find-PackagesDir $PackagesDir
    $info = Get-XppModelInfo $pld $proj.Model
    $xppc = Join-Path $pld 'bin\xppc.exe'
    if (-not $OutputDir) { $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) "xppc-scratch\$($info.Module)" }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
} catch {
    Write-Output "SETUP FAILED: $($_.Exception.Message)"
    exit 2
}

$mode = 'incremental'
if ($Full) { $mode = 'full' }
Write-Output "=== X++ project build: $($proj.Name) ==="
Write-Output "Project : $projectFile"
Write-Output "Model   : $($info.Model) (package folder $(Split-Path $info.PackageDir -Leaf), module $($info.Module)); $($proj.Items.Count) project elements"
Write-Output "Compiler: $xppc ($mode)"
Write-Output "Output  : $OutputDir (scratch; deployed bin untouched)"

# ---------------------------------------------------------------- pre-checks
$blocking = 0
$preNotes = New-Object System.Collections.Generic.List[string]
$projectNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($item in $proj.Items) {
    [void]$projectNames.Add($item.Name)
    $file = Join-Path $info.ModelDir "$($item.Type)\$($item.Name).xml"
    if (-not (Test-Path -LiteralPath $file)) {
        $preNotes.Add("  [missing] $($item.Include): no source file $file")
        $blocking++
        continue
    }
    $check = Test-XppFileFormat $file
    if ($check.XmlError) {
        $preNotes.Add("  [xml]     $($item.Include): malformed XML - $($check.XmlError)")
        $blocking++
    }
    if ($check.FormatIssues.Count -gt 0) {
        $preNotes.Add("  [format]  $($item.Include): $($check.FormatIssues -join ', ') (fix: Add-XppProjectItem.ps1 normalizes)")
    }
}

# Optional (-CheckLabels): xppc does not validate label references - an unknown @File:Id compiles and shows up raw at runtime.
$labelIdCache = @{}
function Get-LabelIds([string]$FileId) {
    if ($labelIdCache.ContainsKey($FileId)) { return , $labelIdCache[$FileId] }
    $ids = $null
    $txt = @(Resolve-Path -Path (Join-Path $pld "*\*\AxLabelFile\LabelResources\en-US\$FileId.en-US.label.txt") -ErrorAction SilentlyContinue)
    if ($txt.Count -eq 0) {
        $txt = @(Resolve-Path -Path (Join-Path $pld "*\*\AxLabelFile\LabelResources\*\$FileId.*.label.txt") -ErrorAction SilentlyContinue)
    }
    if ($txt.Count -gt 0) {
        $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($l in [System.IO.File]::ReadLines($txt[0].ProviderPath)) {
            $eq = $l.IndexOf('=')
            if ($eq -gt 0 -and $l[0] -ne ' ') { [void]$ids.Add($l.Substring(0, $eq).TrimStart([char]0xFEFF)) }
        }
    }
    $labelIdCache[$FileId] = $ids
    return , $ids
}

$missingLabels = 0
if ($CheckLabels) {
    $labelRx = New-Object System.Text.RegularExpressions.Regex('@([A-Za-z][A-Za-z0-9_]*):([A-Za-z0-9_]+)|@([A-Z]{2,6})(\d+)\b')
    foreach ($item in $proj.Items) {
        if ($item.Type -eq 'AxLabelFile') { continue }
        $file = Join-Path $info.ModelDir "$($item.Type)\$($item.Name).xml"
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($m in $labelRx.Matches([System.IO.File]::ReadAllText($file))) {
            if (-not $seen.Add($m.Value)) { continue }
            if ($m.Groups[1].Success) { $fileId = $m.Groups[1].Value; $key = $m.Groups[2].Value }
            else { $fileId = $m.Groups[3].Value; $key = $m.Value }
            $ids = Get-LabelIds $fileId
            if ($null -eq $ids) {
                $preNotes.Add("  [label]   $($item.Include): $($m.Value) - label file '$fileId' not found")
                $missingLabels++
            } elseif (-not $ids.Contains($key)) {
                $preNotes.Add("  [label]   $($item.Include): $($m.Value) does not exist in label file '$fileId'")
                $missingLabels++
            }
        }
    }

    # Duplicate IDs in this model's label files break the label compile in Visual Studio.
    $labelRoot = Join-Path $info.ModelDir 'AxLabelFile\LabelResources'
    if (Test-Path -LiteralPath $labelRoot) {
        foreach ($txt in Get-ChildItem -LiteralPath $labelRoot -Recurse -Filter *.label.txt -File) {
            $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($l in [System.IO.File]::ReadLines($txt.FullName)) {
                $eq = $l.IndexOf('=')
                if ($eq -le 0 -or $l[0] -eq ' ') { continue }
                $id = $l.Substring(0, $eq).TrimStart([char]0xFEFF)
                if (-not $ids.Add($id)) {
                    $preNotes.Add("  [label]   duplicate label id '$id' in $($txt.FullName)")
                    $missingLabels++
                }
            }
        }
    }
}

$cacheRoot = Join-Path $info.PackageDir 'XppMetadata'
$stale = @()
if (Test-Path -LiteralPath $cacheRoot) {
    $stale = @(foreach ($f in [System.IO.Directory]::EnumerateFiles($cacheRoot, '*.xml', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $f.Substring($cacheRoot.Length + 1)   # <Model>\<AxType>\<Name>.xml
        if (-not (Test-Path -LiteralPath (Join-Path $info.PackageDir $rel))) { $f }
    })
}
foreach ($f in $stale) {
    if ($RemoveStaleCache) {
        Remove-Item -LiteralPath $f -Force
        $preNotes.Add("  [cache]   removed stale compiler cache $f")
    } else {
        $preNotes.Add("  [cache]   stale compiler cache (source deleted/renamed): $f  -> rerun with -RemoveStaleCache")
    }
}

if ($preNotes.Count -eq 0) { Write-Output "Checks  : $($proj.Items.Count) element files OK" }
else { Write-Output 'Checks  :'; $preNotes | ForEach-Object { Write-Output $_ } }
if ($blocking -gt 0) {
    Write-Output ''
    Write-Output "RESULT: NOT COMPILED - fix the $blocking [missing]/[xml] problem(s) above first."
    exit 1
}

# ---------------------------------------------------------------- compile
$logFile = Join-Path $OutputDir 'build.log'
$xmlLog = Join-Path $OutputDir 'build.xml'
$stdoutFile = Join-Path $OutputDir 'xppc.out.txt'
Remove-Item -LiteralPath $logFile, $xmlLog, $stdoutFile -ErrorAction SilentlyContinue

$xppcArgs = @(
    "-metadata=$pld", "-compilermetadata=$pld", "-modelmodule=$($info.Module)", "-output=$OutputDir",
    "-referenceFolder=$pld", "-refPath=$(Join-Path $info.PackageDir 'bin')", "-refPath=$(Join-Path $pld 'bin')",
    "-log=$logFile", "-xmlLog=$xmlLog"
)
if (-not $Full) { $xppcArgs += '-incremental' }
$firstBuild = -not (Test-Path -LiteralPath (Join-Path $OutputDir "Dynamics.AX.$($info.Module).dll"))

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $xppc
$psi.Arguments = ($xppcArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
$psi.WorkingDirectory = Split-Path $xppc
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = [System.Diagnostics.Process]::Start($psi)
$stdoutTask = $p.StandardOutput.ReadToEndAsync()
$stderrTask = $p.StandardError.ReadToEndAsync()
$p.WaitForExit()
$sw.Stop()
$consoleText = $stdoutTask.Result + $stderrTask.Result
[System.IO.File]::WriteAllText($stdoutFile, $consoleText)
Write-Output "Compile : $([int]$sw.Elapsed.TotalSeconds) s, xppc exit code $($p.ExitCode); logs $logFile, $xmlLog"

if (-not (Test-Path -LiteralPath $xmlLog)) {
    Write-Output ''
    Write-Output 'RESULT: COMPILER FAILED - no diagnostics log was written. xppc output:'
    Write-Output $consoleText.Trim()
    exit 2
}

# ---------------------------------------------------------------- diagnostics
[xml]$log = [System.IO.File]::ReadAllText($xmlLog)
$segmentCache = @{}
function Get-ElementFile([string]$AxType, [string]$Name) {
    foreach ($m in @($info.Model) + @($info.Models | Where-Object { $_ -ne $info.Model })) {
        $f = Join-Path $info.PackageDir "$m\$AxType\$Name.xml"
        if (Test-Path -LiteralPath $f) { return $f }
    }
    return $null
}

$diags = @(foreach ($d in $log.Diagnostics.Items.Diagnostic) {
    $path = [string]$d.Path
    $kind = $null; $name = $null; $member = $null
    if ($path -match '^dynamics://([^/]+)/([^/]+)(?:/(.+))?$') { $kind = $Matches[1]; $name = $Matches[2]; $member = $Matches[3] }
    elseif ($path -match '^Ax([^/]+)/([^/]+)(?:/(.+))?$') { $kind = $Matches[1]; $name = $Matches[2]; $member = $Matches[3] }
    $line = 0; $col = 0
    if ($d.Line) { $line = [int]$d.Line }
    if ($d.Column) { $col = [int]$d.Column }
    [pscustomobject]@{
        Severity    = [string]$d.Severity
        Type        = [string]$d.DiagnosticType
        ElementType = [string]$d.ElementType
        Kind        = $kind
        Name        = $name
        Member      = $member
        Path        = $path
        Line        = $line
        Column      = $col
        Moniker     = [string]$d.Moniker
        Message     = ([string]$d.Message).Trim()
        InProject   = ($name -and $projectNames.Contains($name))
    }
})

function Write-Diagnostic($n, $d) {
    $scope = '[other]  '
    if ($d.InProject) { $scope = '[project]' }
    $where = "$($d.Kind) $($d.Name)"
    if (-not $d.Kind) { $where = $d.Path }
    if ($d.Member) {
        $member = $d.Member -replace '^Method/', ''
        $where += ", $member"
    }
    if ($d.Line -gt 0) { $where += ", line $($d.Line) col $($d.Column)" }
    Write-Output ("{0,3}. {1} {2}  ({3})" -f $n, $scope, $where, $d.Moniker)
    Write-Output "     $($d.Message)"
    if ($d.Line -gt 0 -and $d.Kind -and $d.ElementType -notlike 'Form*') {
        $file = Get-ElementFile "Ax$($d.Kind)" $d.Name
        if ($file) {
            if (-not $segmentCache.ContainsKey($file)) { $segmentCache[$file] = Get-XppSourceSegments $file }
            $segments = $segmentCache[$file]
            $hit = $null
            if ($segments) { $hit = Resolve-XppSourceLine $segments $d.Line $d.Column }
            if ($hit) {
                $note = ''
                if ($hit.Suspect) { $note = '  (column beyond line end - verify)' }
                Write-Output "     at $($file):$($hit.FileLine)$note"
                Write-Output "     > $($hit.Text.Trim())"
            } else {
                Write-Output "     in $file"
            }
        }
    } elseif ($d.Kind) {
        $file = Get-ElementFile "Ax$($d.Kind)" $d.Name
        if ($file) { Write-Output "     in $file" }
    }
}

$errors = @($diags | Where-Object Severity -eq 'Error')
$warnings = @($diags | Where-Object Severity -eq 'Warning')
$projWarnings = @($warnings | Where-Object InProject)
$otherWarnings = @($warnings | Where-Object { -not $_.InProject })
$projErrors = @($errors | Where-Object InProject)

Write-Output ''
if ($errors.Count -gt 0) {
    Write-Output "ERRORS ($($errors.Count); $($projErrors.Count) in project elements)"
    $n = 0
    foreach ($d in @($projErrors) + @($errors | Where-Object { -not $_.InProject })) { $n++; Write-Diagnostic $n $d }
    Write-Output ''
}

$shownWarnings = $projWarnings
if ($AllWarnings) { $shownWarnings = @($projWarnings) + @($otherWarnings) }
if ($shownWarnings.Count -gt 0) {
    $title = "WARNINGS in project elements ($($projWarnings.Count))"
    if ($AllWarnings) { $title = "WARNINGS ($($warnings.Count); $($projWarnings.Count) in project elements)" }
    Write-Output $title
    $n = 0
    foreach ($d in $shownWarnings) {
        $n++
        if ($n -gt $MaxWarnings) { Write-Output "  ... $($shownWarnings.Count - $MaxWarnings) more in $xmlLog"; break }
        Write-Diagnostic $n $d
    }
    Write-Output ''
}

$summary = "$($errors.Count) errors, $($projWarnings.Count) warnings in project elements, $($otherWarnings.Count) warnings elsewhere (not listed)"
if ($AllWarnings) { $summary = "$($errors.Count) errors, $($warnings.Count) warnings" }
if (-not $Full) {
    if ($firstBuild) { $summary += '; first build in this output folder, so everything was compiled' }
    else { $summary += '; incremental - only elements changed since the last build in this folder were recompiled' }
}
if ($missingLabels -gt 0) { $summary += "; $missingLabels label problem(s), see [label] under Checks" }
if ($errors.Count -gt 0) {
    Write-Output "RESULT: FAILED - $summary"
    exit 1
}
if ($p.ExitCode -ne 0) {
    Write-Output "RESULT: FAILED - xppc exit code $($p.ExitCode) without error diagnostics. xppc output:"
    Write-Output $consoleText.Trim()
    exit 1
}
if ($missingLabels -gt 0) {
    Write-Output "RESULT: FAILED - $summary"
    exit 1
}
Write-Output "RESULT: SUCCEEDED - $summary"
exit 0
