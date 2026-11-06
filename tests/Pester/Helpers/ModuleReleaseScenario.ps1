# Shared helpers for the data-driven release engine tests; dot-source it from BeforeDiscovery and BeforeAll.
Set-StrictMode -Version 3.0

function Get-ModuleReleaseUnitCatalogueName {
    return , @('version', 'timers', 'commands', 'pull-request-body', 'classifier', 'authorization', 'notes', 'notes-edit')
}

function Get-ModuleReleaseCatalogue {
    param([Parameter(Mandatory)] [string] $Name)
    return Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..' '..' 'fixtures' 'module-release' "$Name.psd1")
}

function Copy-ModuleReleaseFixture {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        return ($Value -replace "`r`n?", "`n")
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys)
        if ($Value -isnot [System.Collections.Specialized.OrderedDictionary]) {
            $keys = @($keys | Sort-Object -Property @{ Expression = { [string]$_ } } -CaseSensitive)
        }
        $copy = [ordered]@{}
        foreach ($key in $keys) {
            $copy[$key] = Copy-ModuleReleaseFixture -Value $Value[$key]
        }
        return $copy
    }
    if ($Value -is [System.Collections.IList]) {
        $items = [object[]]::new($Value.Count)
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $items[$index] = Copy-ModuleReleaseFixture -Value $Value[$index]
        }
        return , $items
    }
    return $Value
}

function Split-ModuleReleasePath {
    param([Parameter(Mandatory)] [string] $Path)

    $segments = foreach ($match in [regex]::Matches($Path, '(?<name>[^.\[\]]+)|\[(?<index>\d+)\]')) {
        if ($match.Groups['index'].Success) {
            [int]$match.Groups['index'].Value
        }
        else {
            $match.Groups['name'].Value
        }
    }
    return , @($segments)
}

function Get-ModuleReleaseChild {
    param([AllowNull()] [object] $Container, [Parameter(Mandatory)] [object] $Segment)

    if ($Segment -is [int]) {
        if ($Container -is [System.Collections.IList] -and $Container -isnot [string] -and $Segment -lt $Container.Count) {
            return [pscustomobject]@{ Found = $true; Value = $Container[$Segment] }
        }
        return [pscustomobject]@{ Found = $false; Value = $null }
    }
    if ($Container -is [System.Collections.IDictionary]) {
        if (@($Container.Keys) -ccontains $Segment) {
            return [pscustomobject]@{ Found = $true; Value = $Container[$Segment] }
        }
        return [pscustomobject]@{ Found = $false; Value = $null }
    }
    if ($Container -is [System.Management.Automation.PSCustomObject]) {
        $property = $Container.PSObject.Properties | Where-Object { $_.Name -ceq $Segment }
        if ($null -ne $property) {
            return [pscustomobject]@{ Found = $true; Value = $property.Value }
        }
    }
    return [pscustomobject]@{ Found = $false; Value = $null }
}

function Get-ModuleReleaseValueAtPath {
    param([AllowNull()] [object] $Document, [Parameter(Mandatory)] [string] $Path)

    $current = [pscustomobject]@{ Found = $true; Value = $Document }
    foreach ($segment in (Split-ModuleReleasePath -Path $Path)) {
        $current = Get-ModuleReleaseChild -Container $current.Value -Segment $segment
        if (-not $current.Found) {
            break
        }
    }
    return $current
}

function Set-ModuleReleaseFixturePatch {
    param([Parameter(Mandatory)] [object] $Document, [Parameter(Mandatory)] [System.Collections.IDictionary] $Patch)

    $remove = $Patch.Contains('Remove')
    $path = if ($remove) { $Patch['Remove'] } else { $Patch['Set'] }
    $segments = Split-ModuleReleasePath -Path $path
    $parent = $Document
    for ($index = 0; $index -lt $segments.Count - 1; $index++) {
        $child = Get-ModuleReleaseChild -Container $parent -Segment $segments[$index]
        if (-not $child.Found) {
            throw [System.ArgumentException]::new("Patch path '$path' does not exist.")
        }
        $parent = $child.Value
    }
    $leaf = $segments[-1]
    if ($remove) {
        if ($parent -isnot [System.Collections.IDictionary]) {
            throw [System.ArgumentException]::new("Patch path '$path' can only remove object properties.")
        }
        $parent.Remove($leaf)
        return
    }
    $parent[$leaf] = Copy-ModuleReleaseFixture -Value $Patch['Value']
}

function Format-ModuleReleaseValue {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [string]) {
        return "'$Value'"
    }
    try {
        return (ConvertTo-Json -InputObject $Value -Depth 12 -Compress -WarningAction SilentlyContinue)
    }
    catch {
        return [string]$Value
    }
}

function Get-ModuleReleaseKeys {
    param([AllowNull()] [object] $Value)

    if ($Value -is [System.Collections.IDictionary]) {
        return , @($Value.Keys | ForEach-Object { [string]$_ })
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        return , @($Value.PSObject.Properties.Name)
    }
    return $null
}

function Add-ModuleReleaseExpectationMismatch {
    param(
        [Parameter(Mandatory)] [ValidateSet('Match', 'Regex', 'Count')] [string] $Mode,
        [AllowNull()] [object] $Expected,
        [AllowNull()] [object] $Actual,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Mismatches
    )

    switch ($Mode) {
        'Regex' {
            $text = if ($null -eq $Actual) { $null } elseif ($Actual -is [System.Collections.IList] -and $Actual -isnot [string]) { @($Actual) -join "`n" } else { [string]$Actual }
            if ($null -eq $text -or $text -cnotmatch [string]$Expected) {
                $Mismatches.Add("${Path}: expected a match for /$Expected/ but found $(Format-ModuleReleaseValue -Value $Actual).")
            }
        }
        'Count' {
            $count = if ($null -eq $Actual) { 0 } elseif ($Actual -is [System.Collections.ICollection]) { $Actual.Count } else { 1 }
            if ($count -ne [int]$Expected) {
                $Mismatches.Add("${Path}: expected $Expected items but found $count in $(Format-ModuleReleaseValue -Value $Actual).")
            }
        }
        'Match' {
            Add-ModuleReleaseMismatch -Expected $Expected -Actual $Actual -Path $Path -Mismatches $Mismatches
        }
    }
}

function Add-ModuleReleaseMismatch {
    param(
        [AllowNull()] [object] $Expected,
        [AllowNull()] [object] $Actual,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Mismatches
    )

    if ($null -eq $Expected) {
        if ($null -ne $Actual) {
            $Mismatches.Add("${Path}: expected null but found $(Format-ModuleReleaseValue -Value $Actual).")
        }
        return
    }

    if ($Expected -is [System.Collections.IDictionary]) {
        $actualKeys = Get-ModuleReleaseKeys -Value $Actual
        if ($null -eq $actualKeys) {
            $Mismatches.Add("${Path}: expected an object but found $(Format-ModuleReleaseValue -Value $Actual).")
            return
        }
        foreach ($key in @($Expected.Keys | Sort-Object -Property @{ Expression = { [string]$_ } } -CaseSensitive)) {
            $name = [string]$key
            $mode = 'Match'
            if ($name.EndsWith('~')) {
                $mode = 'Regex'
                $name = $name.Substring(0, $name.Length - 1)
            }
            elseif ($name.EndsWith('#')) {
                $mode = 'Count'
                $name = $name.Substring(0, $name.Length - 1)
            }
            if ($actualKeys -cnotcontains $name) {
                $Mismatches.Add("$Path.${name}: is missing.")
                continue
            }
            $child = Get-ModuleReleaseChild -Container $Actual -Segment $name
            Add-ModuleReleaseExpectationMismatch -Mode $mode -Expected $Expected[$key] -Actual $child.Value -Path "$Path.$name" -Mismatches $Mismatches
        }
        return
    }

    if ($Expected -is [System.Collections.IList] -and $Expected -isnot [string]) {
        $items = if ($null -eq $Actual) {
            , @()
        }
        elseif ($Actual -is [System.Collections.IList] -and $Actual -isnot [string]) {
            , @($Actual)
        }
        else {
            , @(, $Actual)
        }
        if ($items.Count -ne $Expected.Count) {
            $Mismatches.Add("${Path}: expected $($Expected.Count) items but found $($items.Count) in $(Format-ModuleReleaseValue -Value $Actual).")
            return
        }
        for ($index = 0; $index -lt $Expected.Count; $index++) {
            Add-ModuleReleaseMismatch -Expected $Expected[$index] -Actual $items[$index] -Path "$Path[$index]" -Mismatches $Mismatches
        }
        return
    }

    if ($Expected -is [bool]) {
        if ($Actual -isnot [bool] -or $Actual -ne $Expected) {
            $Mismatches.Add("${Path}: expected $Expected but found $(Format-ModuleReleaseValue -Value $Actual).")
        }
        return
    }

    $isScalar = $null -ne $Actual -and $Actual -isnot [bool] -and $Actual -isnot [System.Collections.IDictionary] -and $Actual -isnot [System.Management.Automation.PSCustomObject] -and ($Actual -is [string] -or $Actual -isnot [System.Collections.IList])
    if (-not $isScalar -or [string]$Expected -cne [string]$Actual) {
        $Mismatches.Add("${Path}: expected $(Format-ModuleReleaseValue -Value $Expected) but found $(Format-ModuleReleaseValue -Value $Actual).")
    }
}

function Compare-ModuleReleaseValue {
    param([AllowNull()] [object] $Expected, [AllowNull()] [object] $Actual, [string] $Path = '$')

    $mismatches = [System.Collections.Generic.List[string]]::new()
    Add-ModuleReleaseMismatch -Expected (Copy-ModuleReleaseFixture -Value $Expected) -Actual $Actual -Path $Path -Mismatches $mismatches
    return , $mismatches.ToArray()
}

function Compare-ModuleReleaseState {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Expected, [AllowNull()] [object] $State)

    $mismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($Expected.Keys | Sort-Object -Property @{ Expression = { [string]$_ } } -CaseSensitive)) {
        $path = [string]$key
        $mode = 'Match'
        if ($path.EndsWith('~')) {
            $mode = 'Regex'
            $path = $path.Substring(0, $path.Length - 1)
        }
        elseif ($path.EndsWith('#')) {
            $mode = 'Count'
            $path = $path.Substring(0, $path.Length - 1)
        }
        $found = Get-ModuleReleaseValueAtPath -Document $State -Path $path
        if (-not $found.Found) {
            $mismatches.Add("State.${path}: is missing.")
            continue
        }
        Add-ModuleReleaseExpectationMismatch -Mode $mode -Expected (Copy-ModuleReleaseFixture -Value $Expected[$key]) -Actual $found.Value -Path "State.$path" -Mismatches $mismatches
    }
    return , $mismatches.ToArray()
}

function New-ModuleReleaseStateJson {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Catalogue, [Parameter(Mandatory)] [System.Collections.IDictionary] $Scenario)

    if ($Scenario.Contains('Json')) {
        return ($Scenario['Json'] -replace "`r`n?", "`n")
    }
    $base = if ($Scenario['Kind'] -eq 'Record') { $Catalogue['BaseRecord'] } else { $Catalogue['BaseState'] }
    $document = Copy-ModuleReleaseFixture -Value $base
    foreach ($patch in @($Scenario['Patches'] | Where-Object { $null -ne $_ })) {
        Set-ModuleReleaseFixturePatch -Document $document -Patch $patch
    }
    return (ConvertTo-Json -InputObject $document -Depth 32)
}

function Merge-ModuleReleaseFacts {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Target, [AllowNull()] [System.Collections.IDictionary] $Overrides)

    if ($null -eq $Overrides) {
        return
    }
    foreach ($key in $Overrides.Keys) {
        $value = $Overrides[$key]
        if ($value -is [System.Collections.IDictionary] -and $Target[$key] -is [System.Collections.IDictionary]) {
            Merge-ModuleReleaseFacts -Target $Target[$key] -Overrides $value
            continue
        }
        $Target[$key] = Copy-ModuleReleaseFixture -Value $value
    }
}

function New-ModuleReleasePullRequestFact {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Spec)

    $number = [int]$Spec['Number']
    $body = @"
## Description

Change $number.

- [ ] Breaking changes

### What changes

Describe what breaks for consumers.

### Required upgrade

Describe what consumers must change.
"@
    if ($Spec.Contains('Breaking')) {
        $breaking = $Spec['Breaking']
        $body = @"
## Description

Change $number.

- [x] Breaking changes

### What changes

$($breaking['WhatChanges'])

### Required upgrade

$($breaking['RequiredUpgrade'])
"@
    }

    $fact = [ordered]@{
        Number       = $number
        Title        = "feat: change $number"
        Author       = 'alice'
        MergedAt     = $Spec['MergedAt']
        MergeCommit  = '{0:d40}' -f $number
        Body         = $body
        Labels       = @()
        ChangedFiles = @([ordered]@{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $false })
    }
    foreach ($key in @('Title', 'Author', 'MergeCommit', 'Body', 'ChangedFiles')) {
        if ($Spec.Contains($key)) {
            $fact[$key] = Copy-ModuleReleaseFixture -Value $Spec[$key]
        }
    }
    $fact['Labels'] = @(
        foreach ($label in @($Spec['Labels'] | Where-Object { $null -ne $_ })) {
            if ($label -is [string]) {
                [ordered]@{ Name = $label; AddedBy = 'alice'; AddedAt = $null }
            }
            else {
                Copy-ModuleReleaseFixture -Value $label
            }
        }
    )
    return $fact
}

function New-ModuleReleaseFacts {
    param(
        [AllowNull()] [System.Collections.IDictionary] $Overrides,
        [Parameter(Mandatory)] [string] $Now,
        [AllowEmptyCollection()] [object[]] $Merges = @(),
        [AllowEmptyCollection()] [object[]] $LabelEvents = @(),
        [AllowEmptyCollection()] [object[]] $Comments = @()
    )

    $facts = [ordered]@{
        Repository    = 'Azure/terraform-azurerm-avm-res-example'
        Now           = $Now
        LatestVersion = '0.8.2'
        MainHead      = '0123456789abcdef0123456789abcdef01234567'
        Freeze        = 'none'
        Authorization = [ordered]@{
            Owners     = @('alice', '@Azure/example-owners')
            ActorTeams = [ordered]@{
                carol = @('Azure/azure-verified-modules-engineering-owners')
                dave  = @('Azure/example-owners')
                erin  = @('Azure/azure-verified-modules-module-contributors')
            }
        }
    }
    Merge-ModuleReleaseFacts -Target $facts -Overrides $Overrides
    $facts['MergedPullRequests'] = @($Merges | ForEach-Object { New-ModuleReleasePullRequestFact -Spec $_ })
    $facts['LabelEvents'] = @(
        foreach ($labelEvent in $LabelEvents) {
            $copy = Copy-ModuleReleaseFixture -Value $labelEvent
            if (-not $copy.Contains('Action')) {
                $copy['Action'] = 'labeled'
            }
            $copy
        }
    )
    $facts['Comments'] = @($Comments | ForEach-Object { Copy-ModuleReleaseFixture -Value $_ })
    return $facts
}

function Get-ModuleReleaseIntegrityIssues {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [System.Collections.IDictionary] $Catalogue)

    $issues = [System.Collections.Generic.List[string]]::new()
    foreach ($scenario in @($Catalogue['Scenarios'])) {
        $id = [string]$scenario['Id']
        if ([string]::IsNullOrWhiteSpace($id)) {
            $issues.Add("${Name}: a scenario has no Id.")
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$scenario['Title'])) {
            $issues.Add("${id}: has no Title.")
        }
        if (-not $scenario.ContainsKey('Design') -and -not $scenario.ContainsKey('Assumption')) {
            $issues.Add("${id}: cites neither a Design section nor an Assumption.")
        }
        $steps = if ($scenario.ContainsKey('Steps')) { @($scenario['Steps']) } else { @($scenario) }
        foreach ($step in $steps) {
            if (-not $step.ContainsKey('Expected') -and -not $step.ContainsKey('Throws')) {
                $issues.Add("${id}: a step has neither Expected nor Throws.")
            }
        }
    }
    return , $issues.ToArray()
}
