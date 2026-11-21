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

function ConvertTo-AvmEntraGroupNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object] $Names)

    if ($Names -isnot [System.Collections.IList]) {
        throw [System.ArgumentException]::new('Entra group names must be an array of display-name strings.')
    }
    $result = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($name in $Names) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
            $name -cne $name.Trim() -or $name.Length -gt 256 -or $name -match '[\x00-\x1f\x7f]') {
            throw [System.ArgumentException]::new('Entra group names must be nonempty, trimmed display-name strings without control characters.')
        }
        if ($seen.Add($name)) { $result.Add($name) }
    }
    return ,$result.ToArray()
}

function ConvertTo-AvmExistingIdentitySetting {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)] [object] $Value)

    $setting = ConvertTo-AvmSettingDictionary -Value $Value
    $expectedKeys = @('name', 'resourceGroupName', 'manageEntraGroups')
    if ($setting.Count -ne $expectedKeys.Count -or
        @($setting.Keys | Where-Object { $_ -cnotin $expectedKeys }).Count -gt 0 -or
        $setting['name'] -isnot [string] -or
        $setting['name'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{2,89}$' -or
        $setting['resourceGroupName'] -isnot [string] -or
        $setting['resourceGroupName'] -cnotmatch '^[A-Za-z0-9_().-]{1,90}$' -or
        $setting['resourceGroupName'].EndsWith('.') -or
        $setting['manageEntraGroups'] -isnot [bool]) {
        throw [System.ArgumentException]::new(
            'existingIdentity must contain only a valid name, resourceGroupName, and Boolean manageEntraGroups.'
        )
    }
    return [ordered]@{
        name              = $setting['name']
        resourceGroupName = $setting['resourceGroupName']
        manageEntraGroups = $setting['manageEntraGroups']
    }
}

function Resolve-AvmGroupExistingIdentity {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Groups,
        [Parameter(Mandatory)] [string] $SelectorProperty,
        [Parameter(Mandatory)] [string] $Item
    )

    $selected = @(
        foreach ($entry in @(Get-AvmOrderedGroup -Groups $Groups -SelectorProperty $SelectorProperty -Item $Item)) {
            if ($entry.Group.Contains('existingIdentity')) {
                ConvertTo-AvmExistingIdentitySetting -Value $entry.Group['existingIdentity']
            }
        }
    )
    if ($selected.Count -gt 1) {
        throw [System.ArgumentException]::new("Only one matching group may configure existingIdentity for '$Item'.")
    }
    if ($selected.Count -eq 0) { return $null }
    return $selected[0]
}

function Resolve-AvmGroupEntraGroups {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Groups,
        [Parameter(Mandatory)] [string] $SelectorProperty,
        [Parameter(Mandatory)] [string] $Item
    )

    foreach ($entry in $Groups) {
        $group = ConvertTo-AvmSettingDictionary -Value $entry
        if ($group.Contains('entraGroups')) {
            $null = ConvertTo-AvmEntraGroupNames -Names $group['entraGroups']
        }
    }
    $names = @(
        foreach ($entry in @(Get-AvmOrderedGroup -Groups $Groups -SelectorProperty $SelectorProperty -Item $Item)) {
            if ($entry.Group.Contains('entraGroups')) { $entry.Group['entraGroups'] }
        }
    )
    return ConvertTo-AvmEntraGroupNames -Names $names
}

function Resolve-AvmGroupAzureLocalEnvironment {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Groups,
        [Parameter(Mandatory)] [string] $SelectorProperty,
        [Parameter(Mandatory)] [string] $Item
    )

    $mode = $null
    foreach ($entry in @(Get-AvmOrderedGroup -Groups $Groups -SelectorProperty $SelectorProperty -Item $Item)) {
        if (-not $entry.Group.Contains('azureLocalEnvironment')) { continue }
        if ($entry.Group['azureLocalEnvironment'] -isnot [string] -or
            $entry.Group['azureLocalEnvironment'] -cnotin @('consumer', 'lifecycle', 'migration')) {
            throw [System.ArgumentException]::new(
                "Group '$($entry.Group['name'])' azureLocalEnvironment must be consumer, lifecycle, or migration."
            )
        }
        if ($null -ne $mode -and $mode -cne $entry.Group['azureLocalEnvironment']) {
            throw [System.ArgumentException]::new(
                "Matching groups configure conflicting Azure Local modes for '$Item'."
            )
        }
        $mode = $entry.Group['azureLocalEnvironment']
    }
    return $mode
}

function ConvertFrom-AvmAzureLocalEnvironmentLock {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Json)

    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Json)
        $expected = @(
            'schemaVersion', 'storageAccountResourceId', 'containerName',
            'blobName', 'fixtureResourceGroupId'
        )
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw [ArgumentException]::new('Azure Local environment lock must be one JSON object.')
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $document.RootElement.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) {
                throw [ArgumentException]::new('Azure Local environment lock contains duplicate properties.')
            }
        }
        if (@($seen | Where-Object { $_ -cnotin $expected }).Count -gt 0 -or
            @($expected | Where-Object { $_ -cnotin $seen }).Count -gt 0) {
            throw [ArgumentException]::new('Azure Local environment lock must contain exactly the version 1 properties.')
        }
        $lock = ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate -ErrorAction Stop
        if ($lock['schemaVersion'] -isnot [int] -and $lock['schemaVersion'] -isnot [long] -or
            $lock['schemaVersion'] -ne 1) {
            throw [ArgumentException]::new('Azure Local environment lock schemaVersion must be integer 1.')
        }
        $fixtureMatch = [regex]::Match(
            [string]$lock['fixtureResourceGroupId'],
            '\A/subscriptions/(?<id>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/resourceGroups/[^/]+\z',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $subscription = [guid]::Empty
        if (-not $fixtureMatch.Success -or
            -not [guid]::TryParseExact($fixtureMatch.Groups['id'].Value, 'D', [ref]$subscription) -or
            $lock['storageAccountResourceId'] -isnot [string] -or
            $lock['storageAccountResourceId'] -cnotmatch
                '\A/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}\z' -or
            $lock['containerName'] -isnot [string] -or
            $lock['containerName'] -cnotmatch '\A[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])\z' -or
            $lock['containerName'].Contains('--')) {
            throw [ArgumentException]::new('Azure Local environment lock target fields are invalid.')
        }
        $digest = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($subscription.ToString('D')))
        ).ToLowerInvariant()
        if ($lock['blobName'] -isnot [string] -or $lock['blobName'] -cne "avm-hci-$digest") {
            throw [ArgumentException]::new(
                'Azure Local environment lock blobName must use the canonical fixture subscription digest.'
            )
        }
        return [ordered]@{
            schemaVersion = [int]1
            storageAccountResourceId = $lock['storageAccountResourceId']
            containerName = $lock['containerName']
            blobName = $lock['blobName']
            fixtureResourceGroupId = $lock['fixtureResourceGroupId']
        }
    }
    catch [Text.Json.JsonException], [ArgumentException] {
        throw [ArgumentException]::new(
            'AVM_AZURE_LOCAL_ENVIRONMENT_LOCK must be the validated version 1 JSON object.',
            $_.Exception
        )
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

function ConvertFrom-AvmAzureLocalEntraGroups {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Json)

    try {
        $groups = ConvertFrom-Json -InputObject $Json -NoEnumerate -ErrorAction Stop
    }
    catch [ArgumentException] {
        throw [ArgumentException]::new('AVM_AZURE_LOCAL_ENTRA_GROUPS must be a valid JSON array.', $_.Exception)
    }
    if ($groups -isnot [array]) {
        throw [ArgumentException]::new('AVM_AZURE_LOCAL_ENTRA_GROUPS must be a JSON array.')
    }
    $names = ConvertTo-AvmEntraGroupNames -Names $groups
    if (@($names).Count -eq 0) {
        throw [ArgumentException]::new('AVM_AZURE_LOCAL_ENTRA_GROUPS must contain at least one scoped group.')
    }
    return $names
}
