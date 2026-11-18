<#
.SYNOPSIS
    Builds a D365 F&O X++ Visual Studio project (.rnrproj) from the command line the way Visual Studio
    does on a CHE or VHD development VM, and prints the diagnostics that matter for that project.

.DESCRIPTION
    X++ has no per-project compile unit: Visual Studio's "Build project" compiles the whole
    package (module) that the project's model belongs to, incrementally, into the package's bin
    folder that the AOS runs. This script does the same:
      1. stops the batch service and IIS (the AOS) if they run - needs an elevated session
      2. compiles the package with xppc.exe into PackagesLocalDirectory\<Package>\bin
      3. compiles the package's label files with LabelC.exe when they changed since the last build
      4. syncs the project's tables, views and data entities (and their extensions) with SyncEngine.exe
         when their files changed since the last sync (-Sync forces it)
      5. starts IIS and the batch service again
    Logs go to %TEMP%\xppc-logs\<module>, the change state to %TEMP%\xppc-state.

    With -CheckOnly it only compiles, into a scratch folder (%TEMP%\xppc-scratch\<module>), and stops,
    deploys and syncs nothing: the AOS keeps running the deployed binaries.

    The report contains:
      * pre-checks of the project file and its element files (missing file, malformed XML, BOM/line endings)
      * every compile error in the package, tagged [project] or [other]
      * warnings for project elements only (the rest are counted, or listed with -AllWarnings)
      * for class/table code, the XML file line and source text of each diagnostic
      * the label compile, DB sync and AOS restart results

    Exit code: 0 = no errors, 1 = compile, label or sync errors, or unusable project files, 2 = setup failure.

.PARAMETER Project
    The .rnrproj file, or a folder containing exactly one.
.PARAMETER PackagesDir
    PackagesLocalDirectory. Auto-detected (<drive>:\AosService\PackagesLocalDirectory or $env:D365_PACKAGES_DIR).
.PARAMETER CheckOnly
    Compile into a scratch folder only: no AOS restart, no deployment, no labels, no sync.
.PARAMETER OutputDir
    With -CheckOnly: the scratch output folder. Default: %TEMP%\xppc-scratch\<module>. Keep it stable so
    incremental builds stay fast.
.PARAMETER Sync
    Sync the project's tables, views and data entities even when their files didn't change since the last sync
    (for example after a database restore).
.PARAMETER SqlServer
    SQL Server of the AOS database, for the sync. Default: localhost.
.PARAMETER SqlDatabase
    The AOS database, for the sync. Default: AxDB.
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
.EXAMPLE
    .\Invoke-XppProjectBuild.ps1 -Project C:\Repos\Contoso\Projects\ABC123_Feature -CheckOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,
    [string]$PackagesDir,
    [switch]$CheckOnly,
    [string]$OutputDir,
    [switch]$Full,
    [switch]$Sync,
    [string]$SqlServer = 'localhost',
    [string]$SqlDatabase = 'AxDB',
    [switch]$RemoveStaleCache,
    [switch]$AllWarnings,
    [switch]$CheckLabels,
    [int]$MaxWarnings = 100
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'XppCommon.ps1')
. (Join-Path $PSScriptRoot 'XppMetadataCheck.ps1')
. (Join-Path $PSScriptRoot 'XppDeploy.ps1')

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
    if ($CheckOnly) {
        if (-not $OutputDir) { $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) "xppc-scratch\$($info.Module)" }
        $logDir = $OutputDir
    } else {
        if ($OutputDir) { throw '-OutputDir works only with -CheckOnly: the build writes to the package bin folder.' }
        if (-not (Test-XppElevated)) {
            throw 'The build stops and starts IIS and the batch service, which needs an elevated session (run as administrator). Use -CheckOnly to only compile.'
        }
        $OutputDir = Join-Path $info.PackageDir 'bin'
        $logDir = Join-Path ([System.IO.Path]::GetTempPath()) "xppc-logs\$($info.Module)"
    }
    New-Item -ItemType Directory -Force -Path $OutputDir, $logDir | Out-Null
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
if ($CheckOnly) { Write-Output "Output  : $OutputDir (scratch, -CheckOnly: nothing deployed, the AOS keeps running)" }
else { Write-Output "Output  : $OutputDir (package bin, used by the AOS)" }

# ---------------------------------------------------------------- pre-checks
$blocking = 0
$ignoredCount = 0
$preNotes = New-Object System.Collections.Generic.List[string]
$metadataCheck = $true
try { Initialize-XppMetadataCheck $pld } catch {
    $metadataCheck = $false
    $preNotes.Add("  [note]    ignored-XML check skipped: $($_.Exception.Message)")
}
$projectFormat = Test-XppFileFormat $projectFile
if ($projectFormat.FormatIssues -contains 'LF line endings') {
    $preNotes.Add("  [format]  project file: LF line endings (fix: Add-XppProjectItem.ps1 normalizes)")
}
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
    elseif ($metadataCheck) {
        foreach ($issue in (Test-XppMetadataXml $file)) {
            $preNotes.Add("  [ignored] $($item.Include): $issue")
            $ignoredCount++
        }
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

# ---------------------------------------------------------------- compile, labels, sync
$logFile = Join-Path $logDir 'build.log'
$xmlLog = Join-Path $logDir 'build.xml'
$stdoutFile = Join-Path $logDir 'xppc.out.txt'
Remove-Item -LiteralPath $logFile, $xmlLog, $stdoutFile -ErrorAction SilentlyContinue
# Logs of earlier builds of this script that wrote them into the package bin.
if (-not $CheckOnly) { Remove-Item -LiteralPath (Join-Path $OutputDir 'build.log'), (Join-Path $OutputDir 'build.xml'), (Join-Path $OutputDir 'xppc.out.txt') -ErrorAction SilentlyContinue }

$xppcArgs = @(
    "-metadata=$pld", "-compilermetadata=$pld", "-modelmodule=$($info.Module)", "-output=$OutputDir",
    "-referenceFolder=$pld", "-refPath=$(Join-Path $info.PackageDir 'bin')", "-refPath=$(Join-Path $pld 'bin')",
    "-log=$logFile", "-xmlLog=$xmlLog"
)
if (-not $Full) { $xppcArgs += '-incremental' }
$firstBuild = -not (Test-Path -LiteralPath (Join-Path $OutputDir "Dynamics.AX.$($info.Module).dll"))

$aosState = $null
$deployProblems = New-Object System.Collections.Generic.List[string]
$deployLines = New-Object System.Collections.Generic.List[string]
$diagsReady = $false
try {
    if (-not $CheckOnly) {
        $aosState = Stop-XppAos
        $stopped = @()
        if ($aosState.Iis) { $stopped += 'IIS' }
        if ($aosState.Batch) { $stopped += 'batch service' }
        if ($stopped.Count -gt 0) { Write-Output "AOS     : stopped $($stopped -join ' and ')" }
        else { Write-Output 'AOS     : IIS and the batch service were not running' }
    }

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

    if (Test-Path -LiteralPath $xmlLog) {
        [xml]$log = [System.IO.File]::ReadAllText($xmlLog)
        $diagsReady = $true
        $compiledOk = ($p.ExitCode -eq 0) -and -not @($log.Diagnostics.Items.Diagnostic | Where-Object { $_.Severity -eq 'Error' })

        if (-not $CheckOnly -and $compiledOk) {
            # Labels: LabelC compiles the package's label files into <Package>\Resources, as Visual Studio does.
            $labelFiles = Get-XppLabelFiles $info
            if ($labelFiles.Count -gt 0) {
                $labelState = Get-XppStateFile $info.Module 'labels'
                $labelStamps = Get-XppFileStamps $labelFiles
                $resources = Join-Path $info.PackageDir 'Resources'
                if ($Full -or -not (Test-Path -LiteralPath $resources) -or (Test-XppFilesChanged $labelState $labelStamps)) {
                    $labelLog = Join-Path $logDir 'labelc.log'
                    $labelErr = Join-Path $logDir 'labelc.err'
                    Remove-Item -LiteralPath $labelErr -ErrorAction SilentlyContinue
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $code = Invoke-XppTool (Join-Path $pld 'bin\LabelC.exe') @("-metadata=$pld", "-modelmodule=$($info.Module)",
                        "-output=$resources", "-outlog=$labelLog", "-errlog=$labelErr") (Join-Path $logDir 'labelc.out.txt')
                    $sw.Stop()
                    $errText = ''
                    if (Test-Path -LiteralPath $labelErr) { $errText = ([System.IO.File]::ReadAllText($labelErr)).Trim() }
                    if ($code -ne 0 -or $errText) {
                        $deployLines.Add("Labels  : FAILED (LabelC exit code $code); log $labelErr")
                        if ($errText) { $deployProblems.Add("label compile: $errText") } else { $deployProblems.Add("label compile: LabelC exit code $code") }
                    } else {
                        Save-XppFileStamps $labelState $labelStamps
                        $deployLines.Add("Labels  : compiled ($([int]$sw.Elapsed.TotalSeconds) s)")
                    }
                } else {
                    $deployLines.Add('Labels  : unchanged, not compiled')
                }
            }

            # DB sync: the project's tables, views and data entities, when their files changed since the last sync.
            $syncSet = Get-XppSyncElements $proj.Items $info
            if ($syncSet.Names.Count -gt 0) {
                $syncState = Get-XppStateFile $info.Module 'sync'
                $syncStamps = Get-XppFileStamps $syncSet.Files
                if ($Sync -or (Test-XppFilesChanged $syncState $syncStamps)) {
                    $syncLog = Join-Path $logDir 'syncengine.log'
                    $connect = "Data Source=$SqlServer;Initial Catalog=$SqlDatabase;Integrated Security=True;Enlist=True;Application Name=SyncEngine"
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $code = Invoke-XppTool (Join-Path $pld 'bin\SyncEngine.exe') @('-syncmode=partiallist', "-synclist=$($syncSet.Names -join ',')",
                        "-metadatabinaries=$pld", "-connect=$connect", '-fallbacktobinaries') $syncLog
                    $sw.Stop()
                    if ($code -ne 0) {
                        $deployLines.Add("Sync    : FAILED (SyncEngine exit code $code) for $($syncSet.Names -join ', '); log $syncLog")
                        foreach ($l in (Get-XppLogErrors $syncLog)) { $deployProblems.Add("sync: $l") }
                        if ($deployProblems.Count -eq 0) { $deployProblems.Add("sync: SyncEngine exit code $code") }
                    } else {
                        Save-XppFileStamps $syncState $syncStamps
                        $deployLines.Add("Sync    : $($syncSet.Names -join ', ') ($([int]$sw.Elapsed.TotalSeconds) s)")
                    }
                } else {
                    $deployLines.Add("Sync    : $($syncSet.Names -join ', ') unchanged since the last sync, not synced (-Sync forces it)")
                }
            }
        } elseif (-not $CheckOnly) {
            $deployLines.Add('Labels  : skipped, the compile failed')
            $deployLines.Add('Sync    : skipped, the compile failed')
        }
    }
} catch {
    $buildError = $_.Exception.Message
} finally {
    if ($aosState) {
        foreach ($l in $deployLines) { Write-Output $l }
        $deployLines.Clear()
        Write-Output "AOS     : $(Start-XppAos $aosState); the first page load after the restart takes about a minute"
    }
}
foreach ($l in $deployLines) { Write-Output $l }

if ($buildError) {
    Write-Output ''
    Write-Output "RESULT: BUILD FAILED - $buildError"
    exit 2
}
if (-not $diagsReady) {
    Write-Output ''
    Write-Output 'RESULT: COMPILER FAILED - no diagnostics log was written. xppc output:'
    Write-Output $consoleText.Trim()
    exit 2
}

# ---------------------------------------------------------------- diagnostics
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
if ($ignoredCount -gt 0) { $summary += "; $ignoredCount XML element(s) the metadata reader ignores, see [ignored] under Checks" }
if ($errors.Count -gt 0) {
    Write-Output "RESULT: FAILED - $summary"
    exit 1
}
if ($p.ExitCode -ne 0) {
    # Fatal errors (for example an invalid token in a class source) are only in the text log.
    $fatal = @()
    if (Test-Path -LiteralPath $logFile) { $fatal = @(Select-String -LiteralPath $logFile -Pattern 'Fatal Error' | ForEach-Object { $_.Line.Trim() } | Select-Object -Unique) }
    if ($fatal.Count -gt 0) {
        Write-Output "FATAL ERRORS ($($fatal.Count))"
        $fatal | ForEach-Object { Write-Output "  $_" }
        Write-Output ''
        Write-Output "RESULT: FAILED - xppc exit code $($p.ExitCode), $($fatal.Count) fatal error(s)"
    }
    else {
        Write-Output "RESULT: FAILED - xppc exit code $($p.ExitCode) without error diagnostics. xppc output:"
        Write-Output $consoleText.Trim()
    }
    exit 1
}
if ($deployProblems.Count -gt 0) {
    Write-Output "DEPLOY PROBLEMS ($($deployProblems.Count))"
    $deployProblems | ForEach-Object { Write-Output "  $_" }
    Write-Output ''
    Write-Output "RESULT: FAILED - compiled, but the label compile or DB sync failed; $summary"
    exit 1
}
if ($missingLabels -gt 0 -or $ignoredCount -gt 0) {
    Write-Output "RESULT: FAILED - $summary"
    exit 1
}
Write-Output "RESULT: SUCCEEDED - $summary"
exit 0
