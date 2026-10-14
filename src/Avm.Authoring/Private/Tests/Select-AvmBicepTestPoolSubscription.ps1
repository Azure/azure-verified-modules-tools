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
        [string] $PersistentSubscriptionId,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $RunSeed,

        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $CaseIndex
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($RunSeed -cnotmatch '^[0-9a-fA-F]{32}$') {
        throw [AvmConfigurationException]::new(
            'BAMI test-pool run seed must be 32 hexadecimal characters shared across the run.')
    }
    $seedBytes = [Convert]::FromHexString($RunSeed)
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

    $subscriptions = @(ConvertFrom-AvmBicepTestSubscriptionPool -PoolJson $PoolJson)
    if ($subscriptions.Count -ne 28) {
        throw [AvmConfigurationException]::new('BAMI test subscription pool must be a JSON array of exactly 28 entries.')
    }
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($subscription in $subscriptions) {
        if ($subscription.Name -cne $subscription.Name.Trim() -or -not $names.Add($subscription.Name)) {
            throw [AvmConfigurationException]::new('BAMI test subscription names must be unique and trimmed.')
        }
        if ($distinctIdentifiers.Contains($subscription.SubscriptionId)) {
            throw [AvmConfigurationException]::new('BAMI test subscription IDs must exclude the tenant, Admin and Persistent IDs.')
        }
    }
    $general = @($subscriptions | Where-Object { $_.Tag -ceq 'General' })
    if ($general.Count -eq 0) {
        throw [AvmConfigurationException]::new('The BAMI test subscription pool must contain at least one General subscription.')
    }
    $ordered = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($subscription in $general) {
        $normalizedId = ([guid]$subscription.SubscriptionId).ToString('D')
        $digest = [System.Security.Cryptography.HMACSHA256]::HashData(
            $seedBytes, [System.Text.Encoding]::UTF8.GetBytes($normalizedId))
        $rank = '{0}:{1}' -f [Convert]::ToHexString($digest), $normalizedId
        $ordered.Add($rank, $subscription)
    }
    $position = $CaseIndex % $general.Count
    foreach ($subscription in $ordered.Values) {
        if ($position -eq 0) {
            return [pscustomobject]@{
                Name           = $subscription.Name
                SubscriptionId = ([guid]$subscription.SubscriptionId).ToString('D')
                TenantId       = $identifiers.TenantId
            }
        }
        $position--
    }
    throw [System.InvalidOperationException]::new('BAMI test-pool permutation did not contain the selected case position.')
}
