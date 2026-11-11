<#
.SYNOPSIS
    Shows D365FO form patterns, and checks or applies the pattern of a form, with the platform's own
    pattern engine (the same code as the form designer's "Apply pattern" command).

.DESCRIPTION
    -List                     List the active patterns (name, version, category, friendly name).
    -Pattern <name>           Print the control tree a pattern requires: one line per node with its
                              control type, required/optional, "many", sub-patterns and the property
                              values the pattern enforces.
    -Form <AxForm .xml>       Check the form design and every control that has a (sub-)pattern. Prints
                              each missing required control, each control the pattern doesn't allow,
                              and each property value that differs from the pattern.
    -Form <xml> -Apply        Apply the patterns (design + sub-patterns) and save the form, the way the
                              designer's "Apply pattern" does: it sets Pattern/PatternVersion and every
                              property the pattern enforces (Style, WidthMode, ArrangeMethod, ...). The
                              control structure must already match; nothing is saved if it doesn't.
                              -Pattern <name> with -Apply sets the design pattern first.

    Read-only except -Apply, which rewrites only the form file passed in -Form.
    Exit codes: 0 = OK / matches / applied, 1 = the form doesn't match its patterns, 2 = setup failure.
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string]$Pattern,
    [string]$Version,
    [string]$Form,
    [switch]$Apply,
    [string]$PackagesDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\d365-xpp-compile\scripts\XppCommon.ps1')

function Write-Out([string]$Text) { [Console]::Out.WriteLine($Text) }

try {
    $pld = Find-PackagesDir $PackagesDir
    $bin = Join-Path $pld 'bin'
    foreach ($dll in 'Microsoft.Dynamics.AX.Metadata.dll', 'Microsoft.Dynamics.AX.Metadata.Patterns.dll', 'Microsoft.Dynamics.AX.Metadata.Storage.dll') {
        [void][Reflection.Assembly]::LoadFrom((Join-Path $bin $dll))
    }
    $catalog = New-Object Microsoft.Dynamics.AX.Metadata.Patterns.PatternFactory -ArgumentList $true
}
catch {
    Write-Out "SETUP FAILED: $($_.Exception.Message)"
    exit 2
}

function Get-Pattern([string]$Name, [string]$Ver) {
    $all = @($catalog.GetPatternsByName($Name, $false))
    if ($all.Count -eq 0) { return $null }
    if ($Ver) {
        $match = @($all | Where-Object { $_.Version -eq $Ver })
        if ($match.Count -gt 0) { return $match[0] }
    }
    $active = @($all | Where-Object { $_.Active })
    if ($active.Count -gt 0) { return $active[0] }
    return $all[0]
}

function Format-Restrictions($Node) {
    $parts = @()
    foreach ($r in @($Node.RestrictedProperties)) {
        if ($null -eq $r) { continue }
        $op = if ("$($r.Op)" -eq 'Equals') { '=' } else { " $($r.Op) " }
        $val = if ($null -eq $r.ExpectedValue -or $r.ExpectedValue -eq '') { "''" } else { $r.ExpectedValue }
        $txt = "$($r.Name)$op$val"
        if ($r.Condition) { $txt += " (if $($r.Condition))" }
        $parts += $txt
    }
    return ($parts -join ', ')
}

function Write-PatternNode($Node, [int]$Depth) {
    foreach ($child in @($Node.SubNodes)) {
        if ($null -eq $child) { continue }
        $flags = @()
        $flags += $(if ($child.RequireOne) { 'required' } else { 'optional' })
        if ($child.AllowMany) { $flags += 'many' }
        if ($child.IsOneOf) { $flags += 'one of the following' }
        if ($child.Unordered) { $flags += 'any order' }
        if ($child.ChildrenUnconstrained) { $flags += 'any children' }
        $line = ('  ' * $Depth) + '-'
        if ($child.Type) { $line += " $($child.Type)" }
        if ($child.FriendlyName) { $line += " `"$($child.FriendlyName)`"" }
        $line += " [$($flags -join ', ')]"
        $subs = @($child.SubPatterns | Where-Object { $_ })
        if ($subs.Count -gt 0) { $line += " sub-pattern: $($subs -join ' | ')" }
        $restr = Format-Restrictions $child
        if ($restr) { $line += "  {$restr}" }
        Write-Out $line
        if ($subs.Count -eq 0) { Write-PatternNode $child ($Depth + 1) }
    }
}

# ---------- -List ----------
if ($List) {
    Write-Out 'Active form patterns (category | name | version | friendly name):'
    foreach ($p in (@($catalog.AllPatterns) | Where-Object { $_.Active } | Sort-Object Category, Name)) {
        Write-Out ("{0} | {1} | {2} | {3}" -f $p.Category, $p.Name, $p.Version, $p.FriendlyName)
    }
    exit 0
}

# ---------- -Pattern (show) ----------
if ($Pattern -and -not $Form) {
    $pat = Get-Pattern $Pattern $Version
    if (-not $pat) {
        Write-Out "Pattern '$Pattern' not found. Run with -List to see the pattern names."
        exit 2
    }
    Write-Out "Pattern $($pat.Name) $($pat.Version) ($($pat.FriendlyName))$(if (-not $pat.Active) { ' - NOT the active version' })"
    $rootRestr = Format-Restrictions $pat.Root
    Write-Out "$($pat.Root.Type)$(if ($rootRestr) { "  {$rootRestr}" })"
    Write-PatternNode $pat.Root 1
    Write-Out ''
    Write-Out 'Children must appear in this order unless marked "any order". A node with a sub-pattern is a container control whose <Pattern> must be one of the listed sub-patterns; run -Pattern <sub-pattern> for its contents.'
    exit 0
}

if (-not $Form) {
    Write-Out 'Pass -List, -Pattern <name>, or -Form <path to AxForm xml> [-Apply].'
    exit 2
}

# ---------- -Form (check / apply) ----------
try {
    $formPath = (Resolve-Path -LiteralPath $Form).ProviderPath
    $formName = [IO.Path]::GetFileNameWithoutExtension($formPath)
    $factory = New-Object Microsoft.Dynamics.AX.Metadata.Storage.MetadataProviderFactory
    $provider = $factory.CreateDiskProvider($pld)
    $modelInfo = $provider.ModelManifest.GetModelInfoFromFilePath($formPath)
    if (-not $modelInfo) { throw "'$formPath' is not inside a model folder of $pld." }
    # Read the form from the model that holds this file, not from whichever model has a form of that name.
    $loadInfo = New-Object Microsoft.Dynamics.AX.Metadata.MetaModel.ModelLoadInfo -ArgumentList $modelInfo
    $axForm = $provider.Forms.Read($formName, $loadInfo)
    if (-not $axForm) { throw "Form '$formName' could not be read. Check that the file is well-formed AxForm XML." }
}
catch {
    Write-Out "SETUP FAILED: $($_.Exception.Message)"
    exit 2
}

$analyzer = New-Object Microsoft.Dynamics.AX.Metadata.Patterns.PatternAnalyzer
$script:problems = New-Object System.Collections.Generic.List[string]

function Get-ControlLabel($Control) {
    if ($null -eq $Control) { return '?' }
    if ($Control -is [Microsoft.Dynamics.AX.Metadata.MetaModel.AxFormDesign]) { return 'Design' }
    $t = "$($Control.Type)"
    if ($t) { return "$($Control.Name) ($t)" }
    return "$($Control.Name)"
}

function Get-Children($Control) {
    $c = $null
    try { $c = $Control.Controls } catch { }
    if ($null -eq $c) { return @() }
    return @($c)
}

# Walks one PatternResult. Sub-pattern containers are collected for their own pass.
function Read-Result($Result, [string]$Path, $SubTargets) {
    foreach ($v in @($Result.Violations)) {
        if ($null -eq $v) { continue }
        $actual = if ($null -eq $v.ActualValue -or $v.ActualValue -eq '') { '(not set)' } else { $v.ActualValue }
        $script:problems.Add("$Path`: $($v.PropertyName) is $actual, pattern wants $($v.Op) $($v.PatternValue)")
    }
    $matched = New-Object System.Collections.Generic.HashSet[object]
    $childResults = $Result.ChildResults
    $node = $Result.Node
    if ($node -and @($node.SubPatterns | Where-Object { $_ }).Count -gt 0) {
        return
    }
    $patternChildren = if ($node) { @($node.SubNodes) } else { @() }
    foreach ($group in $patternChildren) {
        if ($null -eq $group) { continue }
        # A "one of" node is matched through one of its options.
        $options = if ($group.IsOneOf) { @($group.SubNodes | Where-Object { $_ }) } else { @($group) }
        $found = 0
        foreach ($opt in $options) {
            if ($childResults -and $childResults.ContainsKey($opt)) { $found += @($childResults[$opt]).Count }
        }
        if ($found -eq 0 -and $group.RequireOne) {
            $names = @()
            foreach ($opt in $options) {
                $what = "$($opt.Type)"
                if ($opt.FriendlyName) { $what += " `"$($opt.FriendlyName)`"" }
                $subs = @($opt.SubPatterns | Where-Object { $_ })
                if ($subs.Count -gt 0) { $what += " with sub-pattern $($subs -join ' | ')" }
                $names += $what
            }
            $script:problems.Add("$Path`: missing required child $($names -join ' or ')")
        }
        foreach ($pn in $options) {
        $list = $null
        if ($childResults -and $childResults.ContainsKey($pn)) { $list = $childResults[$pn] }
        foreach ($cr in @($list)) {
            if ($null -eq $cr) { continue }
            [void]$matched.Add($cr.Control)
            $childPath = "$Path/$(Get-ControlLabel $cr.Control)"
            $subs = @($pn.SubPatterns | Where-Object { $_ })
            if ($subs.Count -gt 0) {
                $sub = "$($cr.Control.Pattern)"
                if (-not $sub) {
                    $script:problems.Add("$childPath`: needs <Pattern> set to one of: $($subs -join ', ')")
                }
                elseif ($subs -notcontains $sub) {
                    $script:problems.Add("$childPath`: Pattern $sub is not allowed here; use one of: $($subs -join ', ')")
                }
                else {
                    $SubTargets.Add(@($cr.Control, $childPath))
                }
            }
            Read-Result $cr $childPath $SubTargets
        }
        }
    }
    if ($Result.ExtraChildren -and $Result.Control) {
        foreach ($c in (Get-Children $Result.Control)) {
            if (-not $matched.Contains($c)) {
                $script:problems.Add("$Path/$(Get-ControlLabel $c): not allowed by the pattern here (wrong type, wrong position, or extra)")
            }
        }
    }
}

function Test-Target($Control, [string]$Path, [string]$PatternName, [string]$PatternVersion) {
    $pat = Get-Pattern $PatternName $PatternVersion
    if (-not $pat) {
        $script:problems.Add("$Path`: unknown pattern '$PatternName'")
        return
    }
    $result = $analyzer.TestPattern($Control, $pat, $null)
    $subTargets = New-Object System.Collections.Generic.List[object]
    Read-Result $result $Path $subTargets
    foreach ($t in $subTargets) {
        Test-Target $t[0] $t[1] "$($t[0].Pattern)" "$($t[0].PatternVersion)"
    }
}

function Get-PatternedControls($Control, [string]$Path, $Acc) {
    foreach ($c in (Get-Children $Control)) {
        $p = "$Path/$(Get-ControlLabel $c)"
        $pn = $null
        try { $pn = "$($c.Pattern)" } catch { }
        if ($pn) { $Acc.Add(@($c, $p)) }
        Get-PatternedControls $c $p $Acc
    }
}

$design = $axForm.Design
if ($Pattern) {
    $design.Pattern = $Pattern
    $design.PatternVersion = ''
}
if (-not "$($design.Pattern)") {
    Write-Out "Form $formName has no <Pattern> on its Design. Set it (or pass -Pattern <name> -Apply), then run again."
    exit 1
}

if ($Apply) {
    # Outer pattern first, then every sub-pattern container, top-down, each with its active version.
    $failed = @()
    $designPat = Get-Pattern "$($design.Pattern)" $null
    if (-not $designPat) {
        Write-Out "Unknown pattern '$($design.Pattern)' on the Design."
        exit 1
    }
    if (-not [Microsoft.Dynamics.AX.Metadata.Patterns.Extensions]::ApplyPattern($design, $designPat)) {
        $failed += "Design: $($designPat.Name) $($designPat.Version)"
    }
    $containers = New-Object System.Collections.Generic.List[object]
    Get-PatternedControls $design 'Design' $containers
    foreach ($t in $containers) {
        $subPat = Get-Pattern "$($t[0].Pattern)" $null
        if (-not $subPat) { $failed += "$($t[1]): unknown pattern '$($t[0].Pattern)'"; continue }
        if (-not [Microsoft.Dynamics.AX.Metadata.Patterns.Extensions]::ApplyPattern($t[0], $subPat)) {
            $failed += "$($t[1]): $($subPat.Name) $($subPat.Version)"
        }
    }
    if ($failed.Count -gt 0) {
        Write-Out "NOT APPLIED - the control structure doesn't match. Nothing was saved."
        foreach ($f in $failed) { Write-Out "  cannot apply: $f" }
        $script:problems.Clear()
        Test-Target $design 'Design' "$($design.Pattern)" "$($design.PatternVersion)"
        foreach ($p in $script:problems) { Write-Out "  $p" }
        exit 1
    }
    try {
        $saveInfo = $provider.ModelManifest.ConstructSaveInfo($modelInfo)
        $provider.Forms.Update($axForm, $saveInfo)
    }
    catch {
        Write-Out "SAVE FAILED: $($_.Exception.Message)"
        exit 2
    }
    $axForm = $provider.Forms.Read($formName, $loadInfo)
    $design = $axForm.Design
}

$script:problems.Clear()
Test-Target $design 'Design' "$($design.Pattern)" "$($design.PatternVersion)"
$header = "Form $formName - pattern $($design.Pattern) $($design.PatternVersion)"
if ($script:problems.Count -eq 0) {
    if ($Apply) { Write-Out "$header - APPLIED and saved; the form matches its patterns." }
    else { Write-Out "$header - OK, the form matches its patterns." }
    exit 0
}
Write-Out "$header - $($script:problems.Count) problem(s):"
foreach ($p in $script:problems) { Write-Out "  $p" }
if (-not $Apply) { Write-Out 'Property problems are fixed by -Apply. Missing or extra controls must be fixed in the XML first.' }
exit 1
