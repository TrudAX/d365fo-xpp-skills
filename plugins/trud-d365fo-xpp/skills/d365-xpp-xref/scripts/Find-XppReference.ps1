<#
.SYNOPSIS
    Queries the D365FO cross-reference database (DYNAMICSXREFDB) and prints a compact,
    tab-separated report of who references an element.

.DESCRIPTION
    Two modes:
      -Target   <path>     find references TO an element path, e.g. /Tables/SalesLine/Fields/SalesPrice
      -FindPath <pattern>  list element paths that exist in the database (use it to find the exact -Target)

    Paths and patterns accept * or % as wildcards. A -Target without a wildcard is matched exactly.
    Read-only: the script only runs SELECT statements, with Windows authentication.

    Exit codes: 0 = rows found, 1 = nothing found, 2 = setup or connection failure.

.EXAMPLE
    .\Find-XppReference.ps1 -Target /Tables/SalesLine/Fields/SalesPrice -SourceModule ApplicationSuite -SourceType Classes
.EXAMPLE
    .\Find-XppReference.ps1 -Target /Classes/SalesLineType/Methods/validateWrite -GroupBy Member
.EXAMPLE
    .\Find-XppReference.ps1 -FindPath '/Tables/SalesLine/Fields/Sales*'
#>
[CmdletBinding(DefaultParameterSetName = 'Target')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Target')]
    [string]$Target,

    [Parameter(Mandatory = $true, ParameterSetName = 'FindPath')]
    [string]$FindPath,

    # Module (model) that contains the referencing code, e.g. ApplicationSuite. Wildcards allowed.
    [Parameter(ParameterSetName = 'Target')]
    [string]$SourceModule,

    # First path segment of the referencing element, e.g. Classes, Tables, Forms. Wildcards allowed.
    [Parameter(ParameterSetName = 'Target')]
    [string]$SourceType,

    [Parameter(ParameterSetName = 'Target')]
    [ValidateSet('Any', 'MethodCall', 'TypeReference', 'InterfaceImplementation', 'ClassExtended',
                 'TestCall', 'Property', 'Attribute', 'TestHelperCall', 'Tag', 'MethodOverride')]
    [string]$Kind = 'Any',

    # Object = one row per referencing element; Member = one row per method; None = every reference with line numbers.
    [Parameter(ParameterSetName = 'Target')]
    [ValidateSet('Object', 'Member', 'None')]
    [string]$GroupBy = 'Object',

    [int]$Top = 500,

    [string]$Server = '.',

    [string]$Database = 'DYNAMICSXREFDB',

    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

$kindNames = @('Undefined', 'MethodCall', 'TypeReference', 'InterfaceImplementation', 'ClassExtended',
               'TestCall', 'Property', 'Attribute', 'TestHelperCall', 'Tag', 'MethodOverride')

function ConvertTo-LikePattern([string]$text) {
    # Escape LIKE special characters except %, then turn * into %.
    $t = $text.Replace('[', '[[]').Replace('_', '[_]')
    return $t.Replace('*', '%')
}

function Test-Wildcard([string]$text) {
    return ($text.Contains('*') -or $text.Contains('%'))
}

$cmdParams = @{}
$where = New-Object System.Collections.Generic.List[string]

if ($PSCmdlet.ParameterSetName -eq 'FindPath') {
    $cmdParams['@path'] = ConvertTo-LikePattern $FindPath
    $sql = @"
SET NOCOUNT ON;
SELECT TOP (@top) n.[Path], m.[Module]
FROM dbo.[Names] n
LEFT JOIN dbo.[Modules] m ON m.[Id] = n.[ModuleId]
WHERE n.[Path] LIKE @path
ORDER BY n.[Path];
"@
    $header = "Path`tModule"
}
else {
    if (Test-Wildcard $Target) {
        $where.Add('t.[Path] LIKE @target')
        $cmdParams['@target'] = ConvertTo-LikePattern $Target
    }
    else {
        $where.Add('t.[Path] = @target')
        $cmdParams['@target'] = $Target
    }
    if ($SourceModule) {
        $where.Add('m.[Module] LIKE @module')
        $cmdParams['@module'] = ConvertTo-LikePattern $SourceModule
    }
    if ($SourceType) {
        $where.Add('s.[Path] LIKE @srcType')
        $cmdParams['@srcType'] = '/' + (ConvertTo-LikePattern $SourceType.Trim('/')) + '/%'
    }
    if ($Kind -ne 'Any') {
        $where.Add('r.[Kind] = @kind')
        $cmdParams['@kind'] = [array]::IndexOf($kindNames, $Kind)
    }

    # Split the source path /<Type>/<Object>/<Member...> into its parts.
    $from = @"
FROM dbo.[Names] t
JOIN dbo.[References] r ON r.[TargetId] = t.[Id]
JOIN dbo.[Names] s ON s.[Id] = r.[SourceId]
LEFT JOIN dbo.[Modules] m ON m.[Id] = s.[ModuleId]
CROSS APPLY (SELECT CHARINDEX('/', s.[Path] + '/', 2) AS p1) a
CROSS APPLY (SELECT CHARINDEX('/', s.[Path] + '/', a.p1 + 1) AS p2) b
CROSS APPLY (SELECT SUBSTRING(s.[Path], 2, a.p1 - 2) AS SrcType,
                    SUBSTRING(s.[Path], a.p1 + 1, CASE WHEN b.p2 > a.p1 THEN b.p2 - a.p1 - 1 ELSE 0 END) AS SrcObject,
                    SUBSTRING(s.[Path], b.p2, 4000) AS SrcMember) x
WHERE $($where -join ' AND ')
"@

    switch ($GroupBy) {
        'Object' {
            $sql = "SET NOCOUNT ON; SELECT TOP (@top) x.SrcType, x.SrcObject, m.[Module], COUNT(*) AS Refs $from GROUP BY x.SrcType, x.SrcObject, m.[Module] ORDER BY x.SrcType, x.SrcObject;"
            $header = "Type`tObject`tModule`tRefs"
        }
        'Member' {
            $sql = "SET NOCOUNT ON; SELECT TOP (@top) x.SrcType, x.SrcObject, x.SrcMember, m.[Module], COUNT(*) AS Refs, MIN(r.[Line]) AS FirstLine $from GROUP BY x.SrcType, x.SrcObject, x.SrcMember, m.[Module] ORDER BY x.SrcType, x.SrcObject, x.SrcMember;"
            $header = "Type`tObject`tMember`tModule`tRefs`tFirstLine"
        }
        'None' {
            $sql = "SET NOCOUNT ON; SELECT TOP (@top) s.[Path], m.[Module], r.[Line], r.[Column], r.[Kind], t.[Path] $from ORDER BY s.[Path], r.[Line], r.[Column];"
            $header = "SourcePath`tModule`tLine`tColumn`tKind`tTarget"
        }
    }
}
$cmdParams['@top'] = $Top

$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=$Server;Database=$Database;Integrated Security=SSPI;Application Name=Find-XppReference"
try {
    $conn.Open()
}
catch {
    Write-Output "ERROR: cannot open database '$Database' on server '$Server': $($_.Exception.Message)"
    Write-Output "Check that SQL Server is running and the cross-reference database exists (pass -Server / -Database if it is not the local default)."
    exit 2
}

try {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = $TimeoutSeconds
    foreach ($k in $cmdParams.Keys) {
        [void]$cmd.Parameters.AddWithValue($k, $cmdParams[$k])
    }
    $reader = $cmd.ExecuteReader()
    $rows = New-Object System.Collections.Generic.List[string]
    while ($reader.Read()) {
        $values = New-Object object[] $reader.FieldCount
        [void]$reader.GetValues($values)
        if ($GroupBy -eq 'None' -and $PSCmdlet.ParameterSetName -eq 'Target') {
            $k = [int]$values[4]
            if ($k -ge 0 -and $k -lt $kindNames.Length) { $values[4] = $kindNames[$k] }
        }
        $rows.Add(($values | ForEach-Object { "$_" }) -join "`t")
    }
    $reader.Close()
}
catch {
    Write-Output "ERROR: query failed: $($_.Exception.Message)"
    exit 2
}
finally {
    $conn.Close()
}

if ($PSCmdlet.ParameterSetName -eq 'FindPath') {
    Write-Output "Paths like '$FindPath': $($rows.Count) row(s)$(if ($rows.Count -ge $Top) { " (limited by -Top $Top)" })"
}
else {
    $filters = @()
    if ($SourceModule) { $filters += "module=$SourceModule" }
    if ($SourceType) { $filters += "type=$SourceType" }
    if ($Kind -ne 'Any') { $filters += "kind=$Kind" }
    $filterText = ''
    if ($filters.Count -gt 0) { $filterText = ' [' + ($filters -join ', ') + ']' }
    Write-Output "References to '$Target'$filterText, grouped by $($GroupBy): $($rows.Count) row(s)$(if ($rows.Count -ge $Top) { " (limited by -Top $Top)" })"
}

if ($rows.Count -eq 0) {
    exit 1
}
Write-Output $header
$rows | ForEach-Object { Write-Output $_ }
exit 0
