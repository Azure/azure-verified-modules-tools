#Requires -Version 7.4

. (Join-Path $PSScriptRoot 'GroupSettings.ps1')

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
        throw [System.ArgumentException]::new('TEST_BAMI_SUBSCRIPTION_IDS must contain exactly 28 {name,id} objects.')
    }
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $normalized = foreach ($subscription in $subscriptions) {
        $entry = ConvertTo-AvmSettingDictionary -Value $subscription
        $id = [guid]::Empty
        if ($entry.Count -ne 2 -or $entry['name'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($entry['name']) -or $entry['name'] -match '[\x00-\x1f\x7f]' -or
            $entry['name'] -cne $entry['name'].Trim() -or $entry['id'] -isnot [string] -or
            -not [guid]::TryParseExact($entry['id'], 'D', [ref] $id) -or $id -eq [guid]::Empty -or
            -not $seenIds.Add($id.ToString()) -or -not $seenNames.Add($entry['name'])) {
            throw [System.ArgumentException]::new('BAMI subscriptions must have unique nonempty names and GUID IDs, with no additional fields.')
        }
        [ordered]@{ name = $entry['name']; id = $id.ToString() }
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
