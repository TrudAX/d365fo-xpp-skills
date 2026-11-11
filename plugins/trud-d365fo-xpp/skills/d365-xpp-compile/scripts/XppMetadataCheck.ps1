# Finds XML elements in an AOT element file that the D365FO metadata deserializer silently ignores:
# an unknown property name, a wrong XML namespace, or a property out of order. Visual Studio and xppc
# read element files with a DataContractSerializer, which skips such elements without an error, so the
# element compiles but loses those properties (a menu item without its namespace loses all of them).
# Dot-source this file; do not run it. Windows PowerShell 5.1 compatible.

$script:XmcAssembly = $null
$script:XmcMembers = @{}
$script:XmcTypes = @{}
$script:XmcXsiNs = [System.Xml.Schema.XmlSchema]::InstanceNamespace

function Initialize-XppMetadataCheck([string]$PackagesDir) {
    if ($script:XmcAssembly) { return }
    Add-Type -AssemblyName System.Runtime.Serialization
    $dll = Join-Path $PackagesDir 'bin\Microsoft.Dynamics.AX.Metadata.dll'
    $script:XmcAssembly = [System.Reflection.Assembly]::LoadFrom($dll)
}

function Get-XmcContractNs([Type]$Type) {
    $a = @($Type.GetCustomAttributes([System.Runtime.Serialization.DataContractAttribute], $false))
    if ($a.Count -gt 0) { return [string]$a[0].Namespace }
    return $null
}

function Test-XmcIsContract([Type]$Type) {
    return (@($Type.GetCustomAttributes([System.Runtime.Serialization.DataContractAttribute], $true)).Count -gt 0)
}

# Data members in DataContractSerializer order: base class first; within a class by Order, then by name (ordinal).
function Get-XmcMembers([Type]$Type) {
    if ($script:XmcMembers.ContainsKey($Type)) { return $script:XmcMembers[$Type] }
    $chain = @()
    $x = $Type
    while ($x -and $x -ne [object]) { $chain = @(, $x) + $chain; $x = $x.BaseType }
    $list = New-Object System.Collections.Generic.List[object]
    $flags = [System.Reflection.BindingFlags]'Instance,Public,NonPublic,DeclaredOnly'
    foreach ($level in $chain) {
        $ns = Get-XmcContractNs $level
        $levelMembers = New-Object System.Collections.Generic.List[object]
        foreach ($m in @($level.GetProperties($flags)) + @($level.GetFields($flags))) {
            $dm = @($m.GetCustomAttributes([System.Runtime.Serialization.DataMemberAttribute], $false))
            if ($dm.Count -eq 0) { continue }
            $name = $dm[0].Name
            if (-not $name) { $name = $m.Name }
            $memberType = $null
            if ($m -is [System.Reflection.PropertyInfo]) { $memberType = $m.PropertyType } else { $memberType = $m.FieldType }
            $levelMembers.Add([pscustomobject]@{ Name = $name; Order = $dm[0].Order; Type = $memberType; Ns = $ns })
        }
        $sorted = $levelMembers.ToArray()
        [Array]::Sort($sorted, [System.Comparison[object]] {
            param($a, $b)
            if ($a.Order -ne $b.Order) { return $a.Order.CompareTo($b.Order) }
            return [string]::CompareOrdinal($a.Name, $b.Name)
        })
        foreach ($m in $sorted) { $list.Add($m) }
    }
    $script:XmcMembers[$Type] = $list
    return $list
}

function Resolve-XmcType([string]$Name) {
    if ($script:XmcTypes.ContainsKey($Name)) { return $script:XmcTypes[$Name] }
    $local = $Name.Split(':')[-1]
    $t = $script:XmcAssembly.GetType("Microsoft.Dynamics.AX.Metadata.MetaModel.$local")
    if (-not $t) { $t = $script:XmcAssembly.GetTypes() | Where-Object { $_.Name -eq $local } | Select-Object -First 1 }
    $script:XmcTypes[$Name] = $t
    return $t
}

function Get-XmcItemType([Type]$Type) {
    if ($Type -eq [string] -or -not ([System.Collections.IEnumerable].IsAssignableFrom($Type))) { return $null }
    $x = $Type
    while ($x) {
        if ($x.IsGenericType) { $ga = $x.GetGenericArguments(); return $ga[$ga.Count - 1] }
        $x = $x.BaseType
    }
    return $null
}

function Test-XmcNode([System.Xml.XmlElement]$Element, [Type]$Type, [string]$Path, $Issues) {
    $it = $Element.GetAttribute('type', $script:XmcXsiNs)
    if ($it) {
        $rt = Resolve-XmcType $it
        if (-not $rt) { $Issues.Add("$Path`: unknown i:type '$it'"); return }
        $Type = $rt
    }
    if (-not $Type -or $Type.IsPrimitive -or $Type.IsEnum -or $Type -eq [string]) { return }
    $members = Get-XmcMembers $Type
    if ($members.Count -eq 0) { return }
    $nameNode = $null
    foreach ($c in $Element.ChildNodes) { if ($c -is [System.Xml.XmlElement] -and $c.LocalName -eq 'Name') { $nameNode = $c; break } }
    $here = $Path
    if ($nameNode) { $here = "$Path[$($nameNode.InnerText)]" }
    $last = -1
    $lastName = ''
    foreach ($c in $Element.ChildNodes) {
        if ($c -isnot [System.Xml.XmlElement]) { continue }
        $idx = -1
        for ($i = 0; $i -lt $members.Count; $i++) { if ($members[$i].Name -ceq $c.LocalName) { $idx = $i; break } }
        if ($idx -lt 0) { $Issues.Add("$here/$($c.LocalName): not a property of $($Type.Name)"); continue }
        $m = $members[$idx]
        if ($c.NamespaceURI -ne $m.Ns) {
            $Issues.Add("$here/$($c.LocalName): in XML namespace '$($c.NamespaceURI)', must be in '$($m.Ns)' (check the xmlns attributes)")
            continue
        }
        if ($idx -lt $last) { $Issues.Add("$here/$($c.LocalName): out of order, must come before $lastName"); continue }
        $last = $idx
        $lastName = $c.LocalName
        $item = Get-XmcItemType $m.Type
        if ($item) {
            foreach ($g in $c.ChildNodes) {
                if ($g -is [System.Xml.XmlElement]) { Test-XmcNode $g $item "$here/$($c.LocalName)" $Issues }
            }
        }
        elseif ((Test-XmcIsContract $m.Type) -or $m.Type.IsAbstract) {
            Test-XmcNode $c $m.Type "$here/$($c.LocalName)" $Issues
        }
    }
}

# Returns the ignored elements of one AOT element file (empty when the file is fully read).
function Test-XppMetadataXml([string]$File) {
    $issues = New-Object System.Collections.Generic.List[string]
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($File)
    $root = $doc.DocumentElement
    $type = Resolve-XmcType $root.LocalName
    if (-not $type) { return , $issues }
    $rootNs = Get-XmcContractNs $type
    if ($null -ne $rootNs -and $root.NamespaceURI -ne $rootNs) {
        $issues.Add("<$($root.LocalName)> is in XML namespace '$($root.NamespaceURI)', must be in '$rootNs': the whole element is read as empty (set xmlns=`"$rootNs`" on the root)")
        return , $issues
    }
    Test-XmcNode $root $type $root.LocalName $issues
    return , $issues
}
