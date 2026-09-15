#Requires -Version 7.4

function ConvertTo-AvmSettingDictionary {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Value)

    if ($Value -is [System.Collections.IDictionary]) {
        return $Value
    }
    if ($Value -isnot [pscustomobject]) {
        throw [System.ArgumentException]::new('Settings must be an object.')
    }
    $result = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Get-AvmOrderedGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Groups,
        [Parameter(Mandatory)] [string] $SelectorProperty,
        [Parameter(Mandatory)] [string] $Item
    )

    $entries = for ($index = 0; $index -lt $Groups.Count; $index++) {
        $group = ConvertTo-AvmSettingDictionary -Value $Groups[$index]
        if ($group['name'] -isnot [string] -or [string]::IsNullOrWhiteSpace($group['name'])) {
            throw [System.ArgumentException]::new('Every group must have a nonempty name.')
        }
        $selectors = $group[$SelectorProperty]
        if ($selectors -isnot [System.Collections.IList] -or $selectors.Count -eq 0 -or
            @($selectors | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw [System.ArgumentException]::new("Group '$($group['name'])' must have a nonempty $SelectorProperty array of strings.")
        }
        $order = 0
        if ($null -ne $group['order']) {
            if ($group['order'] -isnot [int] -and $group['order'] -isnot [long]) {
                throw [System.ArgumentException]::new("Group '$($group['name'])' order must be an integer.")
            }
            $order = $group['order']
        }
        if ($selectors -contains '*' -or $selectors -contains $Item) {
            [pscustomobject]@{ Group = $group; Order = $order; Index = $index }
        }
    }
    return @($entries | Sort-Object -Property Order, Index)
}

function Resolve-AvmGroupTestTenant {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Groups,
        [Parameter(Mandatory)] [string] $SelectorProperty,
        [Parameter(Mandatory)] [string] $Item
    )

    foreach ($entry in $Groups) {
        $group = ConvertTo-AvmSettingDictionary -Value $entry
        if ($group.Contains('testTenant') -and
            ($group['testTenant'] -isnot [string] -or $group['testTenant'] -cnotin @('legacy', 'bami'))) {
            throw [System.ArgumentException]::new("Group '$($group['name'])' testTenant must be exactly 'legacy' or 'bami'.")
        }
    }
    $tenant = 'legacy'
    foreach ($entry in @(Get-AvmOrderedGroup -Groups $Groups -SelectorProperty $SelectorProperty -Item $Item)) {
        if ($entry.Group.Contains('testTenant')) {
            $tenant = $entry.Group['testTenant']
        }
    }
    return $tenant
}
