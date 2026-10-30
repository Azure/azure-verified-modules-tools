#Requires -Version 7.4

. (Join-Path $PSScriptRoot 'GroupSettings.ps1')

function Assert-AvmBicepModulePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if ($Path -cnotmatch '^avm/(res|ptn|utl)/[a-z0-9]+(-[a-z0-9]+)*/[a-z0-9]+(-[a-z0-9]+)*$' -or $Path.Length -gt 68) {
        throw [System.ArgumentException]::new("Invalid root Bicep module path '$Path'; expected a canonical path of at most 68 characters.")
    }
}

function Get-AvmTestIdentityName {
    [CmdletBinding(DefaultParameterSetName = 'Terraform')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Terraform')] [string] $Repository,
        [Parameter(Mandatory, ParameterSetName = 'Bicep')] [string] $ModulePath,
        [switch] $Legacy
    )

    if ($PSCmdlet.ParameterSetName -ceq 'Bicep') {
        Assert-AvmBicepModulePath -Path $ModulePath
        $source = $ModulePath
        $stem = $source.Replace('/', '-')
        $prefix = if ($Legacy) { 'id-avm-bicep-' } else { 'id-test-bicep-' }
        if ($Legacy) {
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).Substring(0, 8).ToLowerInvariant()
            return $prefix + $stem + '-' + $hash
        }
    }
    else {
        $parts = $Repository.Split('/')
        if ($parts.Count -ne 2 -or $parts[0] -cnotmatch '^[A-Za-z0-9-]+$' -or $parts[1].Length -gt 100 -or
            $parts[1].ToLowerInvariant() -cnotmatch '^terraform-(azure|azurerm|azapi)-avm-(res|ptn|utl)-[a-z0-9]+(-[a-z0-9]+)*$') {
            throw [System.ArgumentException]::new('Test identity naming requires an owner-qualified AVM Terraform repository.')
        }
        if ($Legacy) { return $Repository.Replace('/', '-').Replace('windows', 'w5s') }
        $source = $parts[1].ToLowerInvariant()
        $stem = $source.Substring('terraform-'.Length).Replace('windows', 'w5s')
        $prefix = 'id-test-terraform-'
    }
    $name = $prefix + $stem
    if ($name.Length -gt 90) {
        throw [System.ArgumentException]::new('The complete test identity name exceeds the repository limit of 90 characters; names are never truncated.')
    }
    return $name
}

function ConvertFrom-AvmTestTenantJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Json)

    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        $pending = [System.Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
        $pending.Push($document.RootElement)
        while ($pending.Count -gt 0) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) {
                        throw [System.ArgumentException]::new('Test tenant JSON contains duplicate property names.')
                    }
                    $pending.Push($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) {
                    $pending.Push($item)
                }
            }
        }
        return ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate -Depth 30
    }
    catch {
        throw [System.ArgumentException]::new('Invalid test tenant JSON.', $_.Exception)
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
}

function ConvertTo-AvmBicepModuleClientIdJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $ClientIds,
        [string[]] $ForbiddenClientIds = @()
    )

    if ($ClientIds.Count -eq 0) {
        throw [System.ArgumentException]::new('The module client-ID mapping must not be empty.')
    }
    $normalized = [ordered]@{}
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ClientIds.Keys | Sort-Object -CaseSensitive)) {
        if ($path -isnot [string]) { throw [System.ArgumentException]::new('Module mapping keys must be canonical path strings.') }
        Assert-AvmBicepModulePath -Path $path
        $id = [guid]::Empty
        if ($ClientIds[$path] -isnot [string] -or -not [guid]::TryParseExact($ClientIds[$path], 'D', [ref]$id) -or
            $id -eq [guid]::Empty -or $id.ToString() -in $ForbiddenClientIds -or -not $seen.Add($id.ToString())) {
            throw [System.ArgumentException]::new('Each module must have its own nonempty client ID, never a shared or controller identity.')
        }
        $normalized[$path] = $id.ToString()
    }
    $json = ConvertTo-Json -InputObject $normalized -Compress -Depth 3
    if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt 48KB) {
        throw [System.InvalidOperationException]::new('The compact module client-ID mapping exceeds the 48 KB Actions variable limit; publication requires a different storage contract.')
    }
    return $json
}

function Get-AvmBamiSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values,
        [switch] $BicepOnly
    )

    $guidNames = @('TEST_BAMI_TENANT_ID', 'TEST_BAMI_BICEP_CLIENT_ID', 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID')
    if (-not $BicepOnly) {
        $guidNames += @('TEST_BAMI_CONTROLLER_CLIENT_ID', 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID')
    }
    $result = [ordered]@{}
    foreach ($name in $guidNames) {
        $value = $Values[$name]
        $id = [guid]::Empty
        if ($value -isnot [string] -or -not [guid]::TryParseExact($value, 'D', [ref] $id) -or $id -eq [guid]::Empty) {
            throw [System.ArgumentException]::new("$name must be a nonempty GUID in a complete BAMI bundle.")
        }
        $result[$name] = $id.ToString()
    }
    $groupNames = @('TEST_BAMI_MANAGEMENT_GROUP_ID')
    if (-not $BicepOnly) {
        $groupNames += 'TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'
    }
    foreach ($name in $groupNames) {
        $value = $Values[$name]
        if ($value -isnot [string] -or $value -cnotmatch '^[a-zA-Z0-9_().-]{1,90}$' -or $value.EndsWith('.')) {
            throw [System.ArgumentException]::new("$name must be a management-group or resource-group name, not a resource ID.")
        }
        $result[$name] = $value
    }
    $subscriptions = $Values['TEST_BAMI_SUBSCRIPTION_IDS']
    if ($subscriptions -is [string]) {
        $subscriptions = ConvertFrom-AvmTestTenantJson -Json $subscriptions
    }
    if ($subscriptions -isnot [System.Collections.IList] -or $subscriptions.Count -ne 28) {
        throw [System.ArgumentException]::new('TEST_BAMI_SUBSCRIPTION_IDS must contain exactly 28 {name,id} objects with an optional tag.')
    }
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $normalized = foreach ($subscription in $subscriptions) {
        $entry = ConvertTo-AvmSettingDictionary -Value $subscription
        $hasTag = @($entry.psbase.Keys) -ccontains 'tag'
        $id = [guid]::Empty
        if ($entry.psbase.Count -ne (2 + [int]$hasTag) -or $entry['name'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($entry['name']) -or $entry['name'] -match '[\x00-\x1f\x7f]' -or
            $entry['name'] -cne $entry['name'].Trim() -or $entry['id'] -isnot [string] -or
            -not [guid]::TryParseExact($entry['id'], 'D', [ref] $id) -or $id -eq [guid]::Empty -or
            -not $seenIds.Add($id.ToString()) -or -not $seenNames.Add($entry['name'])) {
            throw [System.ArgumentException]::new('BAMI subscriptions must have unique nonempty names and GUID IDs, with only an optional tag field.')
        }
        $normalizedSubscription = [ordered]@{ name = $entry['name']; id = $id.ToString() }
        if ($hasTag) {
            if ($entry['tag'] -isnot [string] -or $entry['tag'].Length -gt 64 -or
                $entry['tag'] -cnotmatch '\A[A-Za-z0-9]+(?:[ -][A-Za-z0-9]+)*\z') {
                throw [System.ArgumentException]::new('A BAMI subscription tag must be a string of at most 64 alphanumeric characters separated by single spaces or hyphens.')
            }
            $normalizedSubscription['tag'] = $entry['tag']
        }
        $normalizedSubscription
    }
    if ($seenIds.Contains($result['TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'])) {
        throw [System.ArgumentException]::new('The BAMI Persistent subscription must not be in the disposable test pool.')
    }
    if (-not $BicepOnly) {
        if ($result['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'] -ceq $result['TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID']) {
            throw [System.ArgumentException]::new('The BAMI administration and Persistent subscriptions must be different.')
        }
        if ($seenIds.Contains($result['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])) {
            throw [System.ArgumentException]::new('The BAMI administration subscription must not be in the disposable test pool.')
        }
    }
    $result['TEST_BAMI_SUBSCRIPTION_IDS'] = ConvertTo-Json -InputObject @($normalized) -Depth 4 -Compress
    if (-not $BicepOnly -and $result['TEST_BAMI_CONTROLLER_CLIENT_ID'] -ceq $result['TEST_BAMI_BICEP_CLIENT_ID']) {
        throw [System.ArgumentException]::new('BAMI controller and Bicep execution client IDs must be separate identities.')
    }
    return $result
}

function Resolve-AvmSubscriptionVendingIdentity {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [AllowNull()] [System.Collections.IDictionary] $ExistingIdentity,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values
    )

    if ($null -eq $ExistingIdentity) { return $null }
    $settings = Get-AvmBamiSettings -Values $Values
    $identity = ConvertTo-AvmExistingIdentitySetting -Value $ExistingIdentity
    if ($identity['name'] -cne 'id-avm-subscription-vending' -or
        $identity['resourceGroupName'] -cne 'rg-avm-managed-identities') {
        throw [System.ArgumentException]::new(
            'Only the bootstrap-owned id-avm-subscription-vending identity in rg-avm-managed-identities may be selected.'
        )
    }

    $resourceIdName = 'TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_RESOURCE_ID'
    $clientIdName = 'TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_CLIENT_ID'
    $principalIdName = 'TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_PRINCIPAL_ID'
    $managementGroupName = 'TEST_BAMI_SUBSCRIPTION_VENDING_MANAGEMENT_GROUP_ID'
    $billingScopeName = 'TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE'
    $expectedResourceId = "/subscriptions/$($settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/resourceGroups/$($identity['resourceGroupName'])/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($identity['name'])"
    $resourceId = $Values[$resourceIdName]
    if ($resourceId -isnot [string] -or $resourceId -ine $expectedResourceId) {
        $binding = [regex]::Match(
            [string]$resourceId,
            '^/subscriptions/(?<subscription>[0-9A-Fa-f-]{36})/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/(?<name>[^/]+)$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $resourceIdPresent = -not [string]::IsNullOrWhiteSpace([string]$resourceId)
        $subscriptionMatches = $binding.Success -and $binding.Groups['subscription'].Value -ceq $settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID']
        $resourceGroupMatches = $binding.Success -and $binding.Groups['resourceGroup'].Value -ceq $identity['resourceGroupName']
        $nameMatches = $binding.Success -and $binding.Groups['name'].Value -ceq $identity['name']
        throw [System.ArgumentException]::new(
            ('{0} must exactly bind the configured bootstrap identity ' +
                '(resource ID present={1}; resource ID format valid={2}; subscription matches={3}; ' +
                'resource group matches={4}; name matches={5}).') -f
            @($resourceIdName, $resourceIdPresent, $binding.Success, $subscriptionMatches, $resourceGroupMatches, $nameMatches)
        )
    }

    $result = [ordered]@{
        name                       = $identity['name']
        resource_group_name        = $identity['resourceGroupName']
        resource_id                = $expectedResourceId
        manage_entra_groups        = $identity['manageEntraGroups']
        management_group_id        = $Values[$managementGroupName]
        billing_scope              = $Values[$billingScopeName]
    }
    foreach ($entry in @(
            @{ Name = $clientIdName; Target = 'client_id' },
            @{ Name = $principalIdName; Target = 'principal_id' }
        )) {
        $id = [guid]::Empty
        $value = $Values[$entry.Name]
        if ($value -isnot [string] -or -not [guid]::TryParseExact($value, 'D', [ref]$id) -or
            $id -eq [guid]::Empty -or $id.ToString() -in @(
                $settings['TEST_BAMI_CONTROLLER_CLIENT_ID'], $settings['TEST_BAMI_BICEP_CLIENT_ID']
            )) {
            throw [System.ArgumentException]::new("$($entry.Name) must be a nonempty identity GUID distinct from the controller and Bicep identities.")
        }
        $result[$entry.Target] = $id.ToString()
    }
    if ($result['management_group_id'] -isnot [string] -or
        $result['management_group_id'] -cnotmatch '^[a-zA-Z0-9_().-]{1,90}$' -or
        $result['management_group_id'].EndsWith('.') -or
        $result['management_group_id'] -ceq $settings['TEST_BAMI_MANAGEMENT_GROUP_ID']) {
        throw [System.ArgumentException]::new(
            "$managementGroupName must be a distinct valid management-group name for subscription vending."
        )
    }
    if ($result['billing_scope'] -isnot [string] -or
        $result['billing_scope'] -cnotmatch '^/providers/Microsoft\.Billing/billingAccounts/[A-Za-z0-9:_-]+/billingProfiles/[A-Za-z0-9_-]+/invoiceSections/[A-Za-z0-9_-]+$') {
        throw [System.ArgumentException]::new(
            "$billingScopeName must be an invoice-section resource ID for subscription vending."
        )
    }
    return $result
}

function Get-AvmGeneralTestSubscription {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Settings)

    $settings = Get-AvmBamiSettings -Values $Settings
    $subscriptions = ConvertFrom-AvmTestTenantJson -Json $settings['TEST_BAMI_SUBSCRIPTION_IDS']
    $general = @(
        foreach ($subscription in $subscriptions) {
            if (-not $subscription.Contains('tag') -or $subscription['tag'] -ceq 'General') {
                [ordered]@{ name = $subscription['name']; id = $subscription['id'] }
            }
        }
    )
    if ($general.Count -eq 0) {
        throw [System.ArgumentException]::new('The BAMI test pool must contain at least one General subscription for ordinary Terraform tests.')
    }
    return $general
}
