<#
.SYNOPSIS
    Adds D365 F&O elements to a Visual Studio X++ project (.rnrproj) the way Visual Studio does,
    and normalizes the element files to the Visual Studio file format.

.DESCRIPTION
    For every element:
      * checks the source file exists in the project's model and is well-formed XML
      * rewrites it as UTF-8 without BOM, CRLF, no newline at end of file (skip with -NoNormalize)
      * adds <Content Include="AxType\Name"> with the element-type folder link, sorted like Visual
        Studio, plus the <Folder> entry; already-present elements are left alone
    Label files (AxLabelFile) also get their dependent .label.txt item.
    The project file keeps its formatting; only the new nodes are inserted.

    With -Create a missing project is created (plus a .sln next to its folder), using the same
    layout Visual Studio uses: <root>\<Name>\<Name>.sln and <root>\<Name>\<Name>\<Name>.rnrproj.

    Exit code: 0 = all elements OK, 1 = some element missing/invalid, 2 = setup failure.

.PARAMETER Project
    The .rnrproj file (or a folder containing exactly one). With -Create: the .rnrproj path to create.
.PARAMETER Element
    Elements as 'AxClass\Name' (or AxClass/Name), or paths to element XML files. Several values or a
    comma-separated string.
.PARAMETER Create
    Create the project if it does not exist. Requires -Model.
.PARAMETER Model
    Model for a new project (a model name, e.g. ContosoCustomizations - not the package folder name).

.EXAMPLE
    .\Add-XppProjectItem.ps1 -Project C:\Repos\Contoso\Projects\ABC123_Feature -Element AxClass\ABCFoo, AxTableExtension\SalesTable.ABC
.EXAMPLE
    .\Add-XppProjectItem.ps1 -Project C:\Repos\Contoso\Projects\ABC124_NewFeature\ABC124_NewFeature\ABC124_NewFeature.rnrproj -Create -Model ContosoCustomizations -Element AxClass\ABCFoo
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,
    [Parameter(Mandatory = $true)]
    [string[]]$Element,
    [string]$PackagesDir,
    [switch]$Create,
    [string]$Model,
    [switch]$NoNormalize
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'XppCommon.ps1')

$FolderByType = @{
    AxClass = 'Classes'; AxTable = 'Tables'; AxTableExtension = 'Table Extensions'
    AxView = 'Views'; AxViewExtension = 'View Extensions'; AxMap = 'Maps'; AxMapExtension = 'Map Extensions'
    AxForm = 'Forms'; AxFormExtension = 'Form Extensions'
    AxEnum = 'Base Enums'; AxEnumExtension = 'Base Enum Extensions'; AxEdtExtension = 'EDT Extensions'
    AxQuerySimpleExtension = 'Query Extensions'
    AxMenu = 'Menus'; AxMenuExtension = 'Menu Extensions'
    AxMenuItemAction = 'Action Menu Items'; AxMenuItemDisplay = 'Display Menu Items'; AxMenuItemOutput = 'Output Menu Items'
    AxMenuItemActionExtension = 'Action Menu Item Extensions'; AxMenuItemDisplayExtension = 'Display Menu Item Extensions'
    AxMenuItemOutputExtension = 'Output Menu Item Extensions'
    AxDataEntityView = 'Data Entities'; AxDataEntityViewExtension = 'Data Entity Extensions'
    AxCompositeDataEntityView = 'Composite Data Entities'; AxAggregateDataEntity = 'Aggregate Data Entities'
    AxReport = 'Reports'; AxLabelFile = 'Label Files'; AxResource = 'Resources'; AxTile = 'Tiles'
    AxSecurityPrivilege = 'Security Privileges'; AxSecurityDuty = 'Security Duties'; AxSecurityRole = 'Security Roles'
    AxSecurityPolicy = 'Security Policies'; AxSecurityDutyExtension = 'Security Duty Extensions'
    AxSecurityRoleExtension = 'Security Role Extensions'
    AxService = 'Services'; AxServiceGroup = 'Service Groups'
    AxConfigurationKey = 'Configuration Keys'; AxLicenseCode = 'License Codes'; AxMacroDictionary = 'Macros'
}
# EDTs and queries are filed by their concrete kind (the i:type of the root element).
$FolderBySubType = @{
    AxEdtString = 'EDT Strings'; AxEdtInt = 'EDT Integers'; AxEdtInt64 = 'EDT Integer64s'; AxEdtReal = 'EDT Reals'
    AxEdtEnum = 'EDT Enums'; AxEdtDate = 'EDT Dates'; AxEdtUtcDateTime = 'EDT UtcDateTimes'; AxEdtGuid = 'EDT Guids'
    AxEdtContainer = 'EDT Containers'; AxEdtTime = 'EDT Times'
    AxQuerySimple = 'Simple Queries'; AxQueryComposite = 'Composite Queries'
}

function Get-VsFolder([string]$Type, [string]$File) {
    if ($Type -eq 'AxEdt' -or $Type -eq 'AxQuery') {
        [xml]$x = [System.IO.File]::ReadAllText($File)
        $sub = $x.DocumentElement.GetAttribute('type', 'http://www.w3.org/2001/XMLSchema-instance')
        if ($FolderBySubType.ContainsKey($sub)) { return $FolderBySubType[$sub] }
        if ($Type -eq 'AxEdt') { return 'Extended Data Types' }
        return 'Queries'
    }
    if ($FolderByType.ContainsKey($Type)) { return $FolderByType[$Type] }
    # Fallback: AxWorkflowApproval -> 'Workflow Approvals'
    return (($Type -replace '^Ax', '') -creplace '(?<=[a-z])(?=[A-Z])', ' ') + 's'
}

function New-XppProjectFiles([string]$ProjectFile, [string]$ModelName) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ProjectFile)
    $projDir = Split-Path $ProjectFile
    $solutionDir = Split-Path $projDir
    $guid = [guid]::NewGuid()
    $targets = 'Microsoft.Dynamics.Framework.Tools.BuildTasks.17.0.targets'
    $targetsDir = Join-Path ${env:ProgramFiles(x86)} 'MSBuild\Microsoft\Dynamics\AX'
    if (Test-Path -LiteralPath $targetsDir) {
        $found = Get-ChildItem -LiteralPath $targetsDir -Filter 'Microsoft.Dynamics.Framework.Tools.BuildTasks.*.targets' |
            Sort-Object { [version]($_.Name -replace '^Microsoft\.Dynamics\.Framework\.Tools\.BuildTasks\.(.+)\.targets$', '$1') } |
            Select-Object -Last 1
        if ($found) { $targets = $found.Name }
    }
    $rnrproj = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="14.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <Configuration Condition=" '`$(Configuration)' == '' ">Debug</Configuration>
    <Platform Condition=" '`$(Platform)' == '' ">AnyCPU</Platform>
    <BuildTasksDirectory Condition=" '`$(BuildTasksDirectory)' == ''">`$(MSBuildProgramFiles32)\MSBuild\Microsoft\Dynamics\AX</BuildTasksDirectory>
    <Model>$ModelName</Model>
    <TargetFrameworkVersion>v4.6</TargetFrameworkVersion>
    <OutputPath>bin</OutputPath>
    <SchemaVersion>2.0</SchemaVersion>
    <GenerateCrossReferences>True</GenerateCrossReferences>
    <RunAppCheckerRules>False</RunAppCheckerRules>
    <LogAppcheckerDiagsAsErrors>False</LogAppcheckerDiagsAsErrors>
    <DeployOnline>False</DeployOnline>
    <ProjectGuid>{$($guid.ToString())}</ProjectGuid>
    <Name>$name</Name>
    <RootNamespace>$name</RootNamespace>
  </PropertyGroup>
  <PropertyGroup Condition="'`$(Configuration)|`$(Platform)' == 'Debug|AnyCPU'">
    <Configuration>Debug</Configuration>
    <DBSyncInBuild>False</DBSyncInBuild>
    <GenerateFormAdaptors>False</GenerateFormAdaptors>
    <Company>
    </Company>
    <Partition>initial</Partition>
    <PlatformTarget>AnyCPU</PlatformTarget>
    <DataEntityExpandParentChildRelations>False</DataEntityExpandParentChildRelations>
    <DataEntityUseLabelTextAsFieldName>False</DataEntityUseLabelTextAsFieldName>
  </PropertyGroup>
  <PropertyGroup Condition=" '`$(Configuration)' == 'Debug' ">
    <DebugSymbols>true</DebugSymbols>
    <EnableUnmanagedDebugging>false</EnableUnmanagedDebugging>
  </PropertyGroup>
  <Import Project="`$(MSBuildBinPath)\Microsoft.Common.targets" />
  <Import Project="`$(BuildTasksDirectory)\$targets" />
</Project>
"@
    $rnrproj = ($rnrproj -replace "`r`n", "`n") -replace "`n", "`r`n"
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    [System.IO.File]::WriteAllText($ProjectFile, $rnrproj.TrimEnd(), $script:Utf8NoBom)
    Write-Output "created project  $ProjectFile"

    if (-not (Get-ChildItem -LiteralPath $solutionDir -Filter *.sln -File -ErrorAction SilentlyContinue)) {
        $g = $guid.ToString().ToUpperInvariant()
        $sg = [guid]::NewGuid().ToString().ToUpperInvariant()
        $sln = @"

Microsoft Visual Studio Solution File, Format Version 12.00
# Visual Studio Version 17
VisualStudioVersion = 17.0.31903.59
MinimumVisualStudioVersion = 10.0.40219.1
Project("{FC65038C-1B2F-41E1-A629-BED71D161FFF}") = "$name", "$name\$name.rnrproj", "{$g}"
EndProject
Global
	GlobalSection(SolutionConfigurationPlatforms) = preSolution
		Debug|Any CPU = Debug|Any CPU
	EndGlobalSection
	GlobalSection(ProjectConfigurationPlatforms) = postSolution
		{$g}.Debug|Any CPU.ActiveCfg = Debug|Any CPU
		{$g}.Debug|Any CPU.Build.0 = Debug|Any CPU
	EndGlobalSection
	GlobalSection(SolutionProperties) = preSolution
		HideSolutionNode = FALSE
	EndGlobalSection
	GlobalSection(ExtensibilityGlobals) = postSolution
		SolutionGuid = {$sg}
	EndGlobalSection
EndGlobal
"@
        $sln = ($sln -replace "`r`n", "`n") -replace "`n", "`r`n"
        $slnFile = Join-Path $solutionDir "$name.sln"
        [System.IO.File]::WriteAllText($slnFile, $sln, (New-Object System.Text.UTF8Encoding($true)))
        Write-Output "created solution $slnFile"
    }
}

function Get-ItemGroupFor($Proj, [string]$ChildName) {
    $doc = $Proj.Doc
    $group = $doc.SelectSingleNode("/m:Project/m:ItemGroup[m:$ChildName]", $Proj.Ns)
    if ($group) { return $group }
    $root = $doc.DocumentElement
    $group = $doc.CreateElement('ItemGroup', $script:MsBuildNs)
    [void]$group.AppendChild($doc.CreateWhitespace("`r`n  "))
    $anchor = $null
    if ($ChildName -eq 'Folder') { $anchor = $doc.SelectSingleNode('/m:Project/m:ItemGroup[m:Content]', $Proj.Ns) }
    if (-not $anchor) { $anchor = $doc.SelectSingleNode('/m:Project/m:Import', $Proj.Ns) }
    if ($anchor) {
        [void]$root.InsertBefore($group, $anchor)
        [void]$root.InsertBefore($doc.CreateWhitespace("`r`n  "), $anchor)
    } else {
        [void]$root.AppendChild($doc.CreateWhitespace("`r`n  "))
        [void]$root.AppendChild($group)
        [void]$root.AppendChild($doc.CreateWhitespace("`r`n"))
    }
    return $group
}

# Inserts the element among its siblings in Include order, with Visual Studio's indentation.
function Add-SortedChild($Group, $NewElement) {
    $doc = $Group.OwnerDocument
    $key = $NewElement.GetAttribute('Include')
    $before = $null
    foreach ($c in $Group.ChildNodes) {
        if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.LocalName -eq $NewElement.LocalName -and
            [string]::Compare($c.GetAttribute('Include'), $key, [System.StringComparison]::OrdinalIgnoreCase) -gt 0) {
            $before = $c
            break
        }
    }
    if ($before) {
        [void]$Group.InsertBefore($NewElement, $before)
        [void]$Group.InsertBefore($doc.CreateWhitespace("`r`n    "), $before)
        return
    }
    $last = $Group.LastChild
    if ($last -and $last.NodeType -eq [System.Xml.XmlNodeType]::Whitespace) {
        [void]$Group.InsertBefore($doc.CreateWhitespace("`r`n    "), $last)
        [void]$Group.InsertBefore($NewElement, $last)
    } else {
        [void]$Group.AppendChild($doc.CreateWhitespace("`r`n    "))
        [void]$Group.AppendChild($NewElement)
        [void]$Group.AppendChild($doc.CreateWhitespace("`r`n  "))
    }
}

function Add-ProjectContent($Proj, [string]$Include, [string]$Name, [string]$Link, [string]$DependentUpon) {
    $existing = $Proj.Doc.SelectNodes('/m:Project/m:ItemGroup/m:Content', $Proj.Ns) |
        Where-Object { $_.GetAttribute('Include') -eq $Include }
    if ($existing) { return $false }
    $doc = $Proj.Doc
    $el = $doc.CreateElement('Content', $script:MsBuildNs)
    $el.SetAttribute('Include', $Include)
    $children = [ordered]@{ SubType = 'Content'; Name = $Name }
    if ($Link) { $children['Link'] = $Link }
    if ($DependentUpon) { $children['DependentUpon'] = $DependentUpon }
    foreach ($k in $children.Keys) {
        [void]$el.AppendChild($doc.CreateWhitespace("`r`n      "))
        $child = $doc.CreateElement($k, $script:MsBuildNs)
        $child.InnerText = $children[$k]
        [void]$el.AppendChild($child)
    }
    [void]$el.AppendChild($doc.CreateWhitespace("`r`n    "))
    Add-SortedChild (Get-ItemGroupFor $Proj 'Content') $el
    return $true
}

function Add-Folder($Proj, [string]$Folder) {
    $include = "$Folder\"
    $existing = $Proj.Doc.SelectNodes('/m:Project/m:ItemGroup/m:Folder', $Proj.Ns) |
        Where-Object { $_.GetAttribute('Include') -eq $include }
    if ($existing) { return }
    $el = $Proj.Doc.CreateElement('Folder', $script:MsBuildNs)
    $el.SetAttribute('Include', $include)
    Add-SortedChild (Get-ItemGroupFor $Proj 'Folder') $el
}

function Save-XppProject($Proj) {
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($Proj.HasBom)
    $settings.Indent = $false
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::None
    $writer = [System.Xml.XmlWriter]::Create($Proj.File, $settings)
    try { $Proj.Doc.Save($writer) } finally { $writer.Close() }
}

# ---------------------------------------------------------------- main
try {
    $pld = Find-PackagesDir $PackagesDir
    $projectFile = $null
    if ($Create -and $Project -like '*.rnrproj' -and -not (Test-Path -LiteralPath $Project)) {
        if (-not $Model) { throw '-Create needs -Model (the model name the project belongs to).' }
        [void](Get-XppModelInfo $pld $Model)   # fail early on a wrong model name
        New-XppProjectFiles $Project $Model
        $projectFile = (Resolve-Path -LiteralPath $Project).ProviderPath
    } else {
        $projectFile = Resolve-XppProjectFile $Project
    }
    $proj = Read-XppProject $projectFile
    if (-not $proj.Model) { throw "No <Model> in $projectFile." }
    $info = Get-XppModelInfo $pld $proj.Model
} catch {
    Write-Output "SETUP FAILED: $($_.Exception.Message)"
    exit 2
}

$specs = @($Element | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$failed = 0
$changed = $false
foreach ($spec in $specs) {
    $type = $null; $name = $null; $file = $null
    if ($spec -like '*.xml' -and (Test-Path -LiteralPath $spec -PathType Leaf)) {
        $file = (Resolve-Path -LiteralPath $spec).ProviderPath
        $type = Split-Path (Split-Path $file) -Leaf
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
        $modelFolder = Split-Path (Split-Path (Split-Path $file)) -Leaf
        if ($modelFolder -ne $info.Model) {
            Write-Output "error   $spec : belongs to model '$modelFolder', the project is on model '$($info.Model)'"
            $failed++
            continue
        }
    } elseif ($spec -match '^(Ax[A-Za-z]+)[\\/](.+?)(\.xml)?$') {
        $type = $Matches[1]
        $name = $Matches[2]
        $file = Join-Path $info.ModelDir "$type\$name.xml"
    } else {
        Write-Output "error   $spec : expected 'AxType\Name' or a path to the element .xml"
        $failed++
        continue
    }
    if ($type -notlike 'Ax*') {
        Write-Output "error   $spec : '$type' is not an element type folder (AxClass, AxTable, ...)"
        $failed++
        continue
    }
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Output "error   $type\$name : source file not found: $file"
        $failed++
        continue
    }

    if (-not $NoNormalize) {
        $before = Test-XppFileFormat $file
        if (Repair-XppFileFormat $file) { Write-Output "fixed   $type\$name : $($before.FormatIssues -join ', ')" }
    }
    $check = Test-XppFileFormat $file
    if ($check.XmlError) {
        Write-Output "error   $type\$name : malformed XML - $($check.XmlError)"
        $failed++
    }

    $folder = Get-VsFolder $type $file
    if (Add-ProjectContent $proj "$type\$name" $name "$folder\$name" $null) {
        Add-Folder $proj $folder
        $changed = $true
        Write-Output "added   $type\$name -> $folder"
    } else {
        Write-Output "exists  $type\$name"
    }

    if ($type -eq 'AxLabelFile') {
        [xml]$lx = [System.IO.File]::ReadAllText($file)
        $txt = [string]$lx.DocumentElement.LabelContentFileName
        if ($txt -and (Add-ProjectContent $proj $txt $txt $null "$type\$name")) {
            $changed = $true
            Write-Output "added   $txt (label resource of $name)"
        }
    }
}

if ($changed) {
    Save-XppProject $proj
    Write-Output "saved   $projectFile"
}
if ($failed -gt 0) { exit 1 }
exit 0
