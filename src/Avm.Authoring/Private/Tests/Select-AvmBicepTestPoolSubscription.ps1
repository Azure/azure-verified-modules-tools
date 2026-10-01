function Select-AvmBicepTestPoolSubscription {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $PoolJson,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $AdminSubscriptionId,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $PersistentSubscriptionId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $identifiers = [ordered]@{
        TenantId                 = $TenantId
        AdminSubscriptionId      = $AdminSubscriptionId
        PersistentSubscriptionId = $PersistentSubscriptionId
    }
    $distinctIdentifiers = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($field in @($identifiers.Keys)) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParseExact($identifiers[$field], 'D', [ref]$parsed) -or
            $parsed -eq [guid]::Empty) {
            throw [AvmConfigurationException]::new("BAMI $field must be a nonempty GUID in D format.")
        }
        $identifiers[$field] = $parsed.ToString('D')
        if (-not $distinctIdentifiers.Add($identifiers[$field])) {
            throw [AvmConfigurationException]::new(
                'BAMI tenant, Admin subscription and Persistent subscription IDs must be distinct.')
        }
    }

    $document = $null
    try {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 3
        $document = [System.Text.Json.JsonDocument]::Parse($PoolJson, $options)
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or
            $document.RootElement.GetArrayLength() -ne 28) {
            throw [AvmConfigurationException]::new(
                'BAMI test subscription pool must be a JSON array of exactly 28 entries.')
        }

        $names = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $ids = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $subscriptions = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $document.RootElement.EnumerateArray()) {
            if ($entry.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                throw [AvmConfigurationException]::new(
                    'Every BAMI test subscription entry must be an object with name and id.')
            }
            $nameValue = $null
            $idValue = $null
            $propertyCount = 0
            foreach ($property in $entry.EnumerateObject()) {
                $propertyCount++
                switch -CaseSensitive ($property.Name) {
                    'name' {
                        if ($null -ne $nameValue) {
                            throw [AvmConfigurationException]::new(
                                'Duplicate BAMI test subscription name property.')
                        }
                        $nameValue = $property.Value
                    }
                    'id' {
                        if ($null -ne $idValue) {
                            throw [AvmConfigurationException]::new(
                                'Duplicate BAMI test subscription id property.')
                        }
                        $idValue = $property.Value
                    }
                    default {
                        throw [AvmConfigurationException]::new(
                            "Unexpected BAMI test subscription property '$($property.Name)'.")
                    }
                }
            }
            if ($propertyCount -ne 2 -or $null -eq $nameValue -or $null -eq $idValue -or
                $nameValue.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                $idValue.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                throw [AvmConfigurationException]::new(
                    'Every BAMI test subscription entry must contain exactly string name and id properties.')
            }

            $name = $nameValue.GetString()
            $id = $idValue.GetString()
            $parsed = [guid]::Empty
            if ([string]::IsNullOrWhiteSpace($name) -or $name -cne $name.Trim() -or
                $name -match '[\x00-\x1f\x7f]' -or -not $names.Add($name)) {
                throw [AvmConfigurationException]::new(
                    'BAMI test subscription names must be unique, nonempty, trimmed and free of control characters.')
            }
            if (-not [guid]::TryParseExact($id, 'D', [ref]$parsed) -or
                $parsed -eq [guid]::Empty) {
                throw [AvmConfigurationException]::new(
                    'BAMI test subscription IDs must be nonempty GUIDs in D format.')
            }
            $normalizedId = $parsed.ToString('D')
            if (-not $ids.Add($normalizedId) -or $distinctIdentifiers.Contains($normalizedId)) {
                throw [AvmConfigurationException]::new(
                    'BAMI test subscription IDs must be unique and exclude the tenant, Admin and Persistent IDs.')
            }
            $subscriptions.Add([pscustomobject]@{
                    Name           = $name
                    SubscriptionId = $normalizedId
                })
        }

        $index = Get-AvmBicepTestPoolIndex -Count $subscriptions.Count
        if ($index -lt 0 -or $index -ge $subscriptions.Count) {
            throw [System.InvalidOperationException]::new('BAMI pool selection returned an invalid index.')
        }
        return [pscustomobject]@{
            Name           = $subscriptions[$index].Name
            SubscriptionId = $subscriptions[$index].SubscriptionId
            TenantId       = $identifiers.TenantId
        }
    }
    catch [System.Text.Json.JsonException] {
        throw [AvmConfigurationException]::new(
            "BAMI test subscription pool must be strict JSON: $($_.Exception.Message)")
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
}
