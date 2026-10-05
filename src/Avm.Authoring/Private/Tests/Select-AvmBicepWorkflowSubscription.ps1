function Select-AvmBicepWorkflowSubscription {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $PoolJson,

        [string] $FallbackSubscriptionId,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $RandomSeed = 0,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $CaseIndex = 0
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not [string]::IsNullOrEmpty($PoolJson) -and [string]::IsNullOrWhiteSpace($PoolJson)) {
        throw [AvmConfigurationException]::new('The test subscription pool must not contain only whitespace.')
    }
    if ([string]::IsNullOrEmpty($PoolJson)) {
        $subscriptions = @(@{ id = $FallbackSubscriptionId; name = $FallbackSubscriptionId })
    }
    else {
        try {
            $subscriptions = ConvertFrom-Json -InputObject $PoolJson -AsHashtable -NoEnumerate -ErrorAction Stop
        }
        catch [System.ArgumentException] {
            throw [AvmConfigurationException]::new('The test subscription pool must be a JSON array of id and name objects.')
        }
    }
    if ($subscriptions -isnot [array] -or $subscriptions.Count -eq 0) {
        throw [AvmConfigurationException]::new('The test subscription pool must be a nonempty JSON array.')
    }
    $identifiers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ordered = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $seed = [System.Text.Encoding]::UTF8.GetBytes($RandomSeed.ToString([cultureinfo]::InvariantCulture))
    foreach ($entry in $subscriptions) {
        $identifier = [guid]::Empty
        if ($entry -isnot [System.Collections.IDictionary] -or
            $entry['id'] -isnot [string] -or
            -not [guid]::TryParseExact($entry['id'], 'D', [ref]$identifier) -or
            $identifier -eq [guid]::Empty -or -not $identifiers.Add($identifier.ToString('D'))) {
            throw [AvmConfigurationException]::new('Test subscriptions must contain distinct, nonempty subscription GUIDs.')
        }
        if ($entry['name'] -isnot [string] -or [string]::IsNullOrWhiteSpace($entry['name']) -or
            $entry['name'] -match '[\x00-\x1f\x7f]') {
            throw [AvmConfigurationException]::new('Test subscription names must be nonempty and free of control characters.')
        }
        $id = $identifier.ToString('D')
        $digest = [System.Security.Cryptography.HMACSHA256]::HashData($seed, [System.Text.Encoding]::UTF8.GetBytes($id))
        $ordered.Add(('{0}:{1}' -f [Convert]::ToHexString($digest), $id), [pscustomobject]@{
                SubscriptionId = $id
                Name           = $entry['name']
            })
    }
    $position = $CaseIndex % $subscriptions.Count
    foreach ($entry in $ordered.Values) {
        if ($position -eq 0) { return $entry }
        $position--
    }
    throw [System.InvalidOperationException]::new('The test subscription pool did not contain the selected position.')
}
