function Get-AvmBicepPolicyToken {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $RepositoryRoot,
        [string] $ModulePath
    )

    Set-StrictMode -Version 3.0
    $ci = Get-AvmBicepWorkflowEnvironment -Enabled
    $tag = 'General'
    if ($RepositoryRoot -or $ModulePath) {
        if (-not $RepositoryRoot -or -not $ModulePath) {
            throw [AvmConfigurationException]::new('Reservation selection requires both RepositoryRoot and ModulePath.')
        }
        $tag = Get-AvmBicepTestSubscriptionTag -RepositoryRoot $RepositoryRoot -ModulePath $ModulePath
    }
    $subscriptionId = $ci.SubscriptionId
    if (-not [string]::IsNullOrEmpty($ci.PoolJson)) {
        $pool = @(ConvertFrom-AvmBicepTestSubscriptionPool -PoolJson $ci.PoolJson |
                Where-Object { $_.Tag -ceq $tag })
        if ($pool.Count -eq 0) {
            throw [AvmConfigurationException]::new("The test subscription pool has no '$tag' subscriptions; PSRule cannot use another tag or singleton fallback.")
        }
        $subscriptionId = $pool[0].SubscriptionId
    }
    elseif ($tag -cne 'General') {
        throw [AvmConfigurationException]::new("Reserved subscription tag '$tag' requires a tagged pool; singleton fallback is not permitted.")
    }
    $namePrefix = [string]$ci.Tokens['namePrefix']
    if ([string]::IsNullOrWhiteSpace($namePrefix)) {
        $namePrefix = 'gci'
    }
    $tokens = @{
        subscriptionId    = $subscriptionId
        tenantId          = $ci.TenantId
        managementGroupId = if ($ci.ManagementGroupId) {
            $ci.ManagementGroupId
        }
        else { $env:ARM_MGMTGROUP_ID }
        namePrefix        = $namePrefix
    }

    foreach ($variable in @(Get-ChildItem Env: | Where-Object {
                $_.Name.StartsWith('localToken_', [System.StringComparison]::OrdinalIgnoreCase)
            })) {
        $name = $variable.Name.Substring('localToken_'.Length)
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $tokens[$name] = $variable.Value
    }

    return $tokens
}
