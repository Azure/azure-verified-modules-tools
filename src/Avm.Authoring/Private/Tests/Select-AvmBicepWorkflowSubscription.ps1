function Select-AvmBicepWorkflowSubscription {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $PoolJson,

        [string] $FallbackSubscriptionId,

        [string] $RepositoryRoot,

        [string] $ModulePath,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $RandomSeed = 0,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $CaseIndex = 0
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $tag = 'General'
    if ($RepositoryRoot -or $ModulePath) {
        if (-not $RepositoryRoot -or -not $ModulePath) {
            throw [AvmConfigurationException]::new('Reservation selection requires both RepositoryRoot and ModulePath.')
        }
        $tag = Get-AvmBicepTestSubscriptionTag -RepositoryRoot $RepositoryRoot -ModulePath $ModulePath
    }
    if ([string]::IsNullOrEmpty($PoolJson)) {
        if ($tag -cne 'General') {
            throw [AvmConfigurationException]::new("Reserved subscription tag '$tag' requires a tagged pool; singleton fallback is not permitted.")
        }
        $PoolJson = ConvertTo-Json -InputObject @(@{ id = $FallbackSubscriptionId; name = $FallbackSubscriptionId }) -Compress
    }
    $subscriptions = @(ConvertFrom-AvmBicepTestSubscriptionPool -PoolJson $PoolJson |
            Where-Object { $_.Tag -ceq $tag })
    if ($subscriptions.Count -eq 0) {
        throw [AvmConfigurationException]::new("The test subscription pool has no '$tag' subscriptions; a configured pool never uses another tag or singleton fallback.")
    }
    $ordered = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $seed = [System.Text.Encoding]::UTF8.GetBytes($RandomSeed.ToString([cultureinfo]::InvariantCulture))
    foreach ($entry in $subscriptions) {
        $id = ([guid]$entry.SubscriptionId).ToString('D')
        $digest = [System.Security.Cryptography.HMACSHA256]::HashData($seed, [System.Text.Encoding]::UTF8.GetBytes($id))
        $ordered.Add(('{0}:{1}' -f [Convert]::ToHexString($digest), $id), $entry)
    }
    $position = $CaseIndex % $subscriptions.Count
    foreach ($entry in $ordered.Values) {
        if ($position -eq 0) { return $entry }
        $position--
    }
    throw [System.InvalidOperationException]::new('The test subscription pool did not contain the selected position.')
}
