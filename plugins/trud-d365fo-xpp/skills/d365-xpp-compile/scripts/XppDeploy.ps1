# Deploy steps of Invoke-XppProjectBuild.ps1: what a Visual Studio build does on a CHE or VHD development VM
# besides compiling. Dot-source this file; do not run it. Windows PowerShell 5.1 compatible.

function Test-XppElevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Stops the batch service and IIS (the AOS) when they run. Returns what was running, for Start-XppAos.
function Stop-XppAos {
    $state = [pscustomobject]@{ Batch = $false; Iis = $false }
    $batch = Get-Service -Name DynamicsAxBatch -ErrorAction SilentlyContinue
    if ($batch -and $batch.Status -eq 'Running') {
        Stop-Service -InputObject $batch -Force -WarningAction SilentlyContinue
        $state.Batch = $true
    }
    $w3 = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
    if ($w3 -and $w3.Status -eq 'Running') {
        $out = & (Join-Path $env:windir 'System32\iisreset.exe') /stop 2>&1
        if ($LASTEXITCODE -ne 0) { throw "iisreset /stop failed: $(($out | Out-String).Trim())" }
        $state.Iis = $true
    }
    return $state
}

# Starts again what Stop-XppAos stopped. Returns a short status text.
function Start-XppAos($State) {
    $done = New-Object System.Collections.Generic.List[string]
    if ($State.Iis) {
        $out = & (Join-Path $env:windir 'System32\iisreset.exe') /start 2>&1
        if ($LASTEXITCODE -ne 0) { $done.Add("iisreset /start FAILED: $(($out | Out-String).Trim())") } else { $done.Add('IIS started') }
    }
    if ($State.Batch) {
        try { Start-Service -Name DynamicsAxBatch -WarningAction SilentlyContinue; $done.Add('batch service started') }
        catch { $done.Add("batch service start FAILED: $($_.Exception.Message)") }
    }
    if ($done.Count -eq 0) { return 'nothing was running, nothing started' }
    return ($done -join ', ')
}

# Change tracking between builds: a map of file path -> last write time, kept per module under %TEMP%.
function Get-XppStateFile([string]$Module, [string]$Kind) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'xppc-state'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return (Join-Path $dir "$Module.$Kind.txt")
}

function Get-XppFileStamps([string[]]$Files) {
    $map = @{}
    foreach ($f in $Files) {
        if (Test-Path -LiteralPath $f) { $map[$f.ToLowerInvariant()] = [string](Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks }
    }
    return $map
}

# True when the files differ from the stamps saved after the last successful run (or nothing was saved).
function Test-XppFilesChanged([string]$StateFile, $Stamps) {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $true }
    $saved = @{}
    foreach ($l in [System.IO.File]::ReadAllLines($StateFile)) {
        $tab = $l.IndexOf("`t")
        if ($tab -gt 0) { $saved[$l.Substring(0, $tab)] = $l.Substring($tab + 1) }
    }
    if ($saved.Count -ne $Stamps.Count) { return $true }
    foreach ($k in $Stamps.Keys) { if ($saved[$k] -ne $Stamps[$k]) { return $true } }
    return $false
}

function Save-XppFileStamps([string]$StateFile, $Stamps) {
    $lines = @($Stamps.Keys | Sort-Object | ForEach-Object { "$_`t$($Stamps[$_])" })
    [System.IO.File]::WriteAllLines($StateFile, [string[]]$lines)
}

# Runs a console tool, saves its output to $LogFile, returns its exit code.
function Invoke-XppTool([string]$Exe, [string[]]$Arguments, [string]$LogFile) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.WorkingDirectory = Split-Path $Exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [System.IO.File]::WriteAllText($LogFile, $o.Result + $e.Result)
    return $p.ExitCode
}

# Error lines of a tool log, for the report.
function Get-XppLogErrors([string]$LogFile, [int]$Max = 15) {
    if (-not (Test-Path -LiteralPath $LogFile)) { return @() }
    return @(Select-String -LiteralPath $LogFile -Pattern 'error|exception|failed' |
        ForEach-Object { $_.Line.Trim() } | Where-Object { $_ } | Select-Object -Unique -First $Max)
}

# The project's elements that live in the database: tables, views, data entities and their extensions.
# Extensions sync under the name of the element they extend (SalesTable.ContosoExt -> SalesTable).
function Get-XppSyncElements($Items, $Info) {
    $types = @('AxTable', 'AxTableExtension', 'AxView', 'AxViewExtension', 'AxDataEntityView', 'AxDataEntityViewExtension')
    $names = New-Object System.Collections.Generic.List[string]
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Items) {
        if ($types -notcontains $item.Type) { continue }
        $name = $item.Name
        if ($item.Type -like '*Extension') { $name = $name.Split('.')[0] }
        if (-not $names.Contains($name)) { $names.Add($name) }
        $files.Add((Join-Path $Info.ModelDir "$($item.Type)\$($item.Name).xml"))
    }
    return [pscustomobject]@{ Names = $names.ToArray(); Files = $files.ToArray() }
}

function Get-XppLabelFiles($Info) {
    return @(foreach ($m in $Info.Models) {
        $dir = Join-Path $Info.PackageDir "$m\AxLabelFile"
        if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object FullName }
    })
}
