# Shared helpers for the d365-xpp-compile skill scripts. Dot-source this file; do not run it.
# Windows PowerShell 5.1 compatible.

$script:MsBuildNs = 'http://schemas.microsoft.com/developer/msbuild/2003'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Resolve-XppProjectFile([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Path).ProviderPath
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $found = @(Get-ChildItem -LiteralPath $Path -Filter *.rnrproj -Recurse -Depth 2 -File)
        if ($found.Count -eq 1) { return $found[0].FullName }
        if ($found.Count -gt 1) {
            throw "Several .rnrproj files under '$Path': $(($found | ForEach-Object FullName) -join ', '). Pass the one to use."
        }
    }
    throw "Project '$Path' not found. Pass a .rnrproj file or a folder that contains one."
}

# PackagesLocalDirectory = the folder that holds bin\xppc.exe and one sub-folder per package.
function Find-PackagesDir([string]$Hint) {
    if ($Hint) {
        if (Test-Path -LiteralPath (Join-Path $Hint 'bin\xppc.exe')) { return (Resolve-Path -LiteralPath $Hint).ProviderPath }
        throw "No bin\xppc.exe under -PackagesDir '$Hint'."
    }
    if ($env:D365_PACKAGES_DIR -and (Test-Path -LiteralPath (Join-Path $env:D365_PACKAGES_DIR 'bin\xppc.exe'))) {
        return $env:D365_PACKAGES_DIR
    }
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        $candidate = Join-Path $drive.RootDirectory.FullName 'AosService\PackagesLocalDirectory'
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\xppc.exe')) { return $candidate }
    }
    throw 'PackagesLocalDirectory (with bin\xppc.exe) not found under <drive>:\AosService on any drive. Pass -PackagesDir or set $env:D365_PACKAGES_DIR.'
}

# A model lives in exactly one package; the package descriptor folder holds one <Model>.xml per model.
function Get-XppModelInfo([string]$PackagesDir, [string]$ModelName) {
    foreach ($pkg in Get-ChildItem -LiteralPath $PackagesDir -Directory) {
        $descriptor = Join-Path $pkg.FullName "Descriptor\$ModelName.xml"
        if (-not (Test-Path -LiteralPath $descriptor)) { continue }
        [xml]$d = [System.IO.File]::ReadAllText($descriptor)
        $info = $d.AxModelInfo
        $models = @(Get-ChildItem -LiteralPath (Join-Path $pkg.FullName 'Descriptor') -Filter *.xml | ForEach-Object BaseName)
        return [pscustomobject]@{
            Model      = [string]$info.Name
            Module     = [string]$info.ModelModule
            PackageDir = $pkg.FullName
            ModelDir   = Join-Path $pkg.FullName ([string]$info.Name)
            Models     = $models
        }
    }
    throw "Model '$ModelName' not found: no <package>\Descriptor\$ModelName.xml under '$PackagesDir'."
}

function Read-XppProject([string]$ProjectFile) {
    $bytes = [System.IO.File]::ReadAllBytes($ProjectFile)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($ProjectFile)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('m', $script:MsBuildNs)
    $modelNode = $doc.SelectSingleNode('/m:Project/m:PropertyGroup/m:Model', $ns)
    $items = @(foreach ($c in $doc.SelectNodes('/m:Project/m:ItemGroup/m:Content', $ns)) {
        $include = $c.GetAttribute('Include')
        if ($include -match '^(Ax[A-Za-z]+)\\(.+)$') {
            [pscustomobject]@{ Type = $Matches[1]; Name = $Matches[2]; Include = $include }
        }
    })
    $model = $null
    if ($modelNode) { $model = $modelNode.InnerText.Trim() }
    [pscustomobject]@{
        File   = $ProjectFile
        Name   = [System.IO.Path]::GetFileNameWithoutExtension($ProjectFile)
        Doc    = $doc
        Ns     = $ns
        HasBom = $hasBom
        Model  = $model
        Items  = $items
    }
}

# Element XML convention written by Visual Studio: UTF-8 without BOM, CRLF, no newline after the closing tag.
function Test-XppFileFormat([string]$File) {
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $text = $script:Utf8NoBom.GetString($bytes)
    $issues = New-Object System.Collections.Generic.List[string]
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $issues.Add('UTF-8 BOM')
        $text = $text.Substring(1)
    }
    if ([regex]::IsMatch($text, "(?<!`r)`n")) { $issues.Add('LF line endings') }
    if ($text -match "[`r`n]\z") { $issues.Add('newline at end of file') }
    $xmlError = $null
    try {
        $x = New-Object System.Xml.XmlDocument
        $x.LoadXml($text)
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $xmlError = $e.Message
    }
    [pscustomobject]@{ FormatIssues = $issues.ToArray(); XmlError = $xmlError }
}

# Rewrites the file in the Visual Studio convention. Returns $true when the file changed.
function Repair-XppFileFormat([string]$File) {
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $original = $script:Utf8NoBom.GetString($bytes)
    $text = $original
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    $text = $text.TrimEnd([char[]]@("`r", "`n"))
    if ($text -cne $original) {
        [System.IO.File]::WriteAllBytes($File, $script:Utf8NoBom.GetBytes($text))
        return $true
    }
    return $false
}
