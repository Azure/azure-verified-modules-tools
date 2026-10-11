function Get-AvmBicepPolicyToken {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    Set-StrictMode -Version 3.0
    $subscriptionId = $env:VALIDATE_SUBSCRIPTION_ID
    if (-not [string]::IsNullOrEmpty($env:TEST_SUBSCRIPTION_IDS)) {
        # Validate with the shared pool rules, then use the first authored entry rather than the e2e seeded order.
        $null = Select-AvmBicepWorkflowSubscription -PoolJson $env:TEST_SUBSCRIPTION_IDS
        $pool = ConvertFrom-Json -InputObject $env:TEST_SUBSCRIPTION_IDS -AsHashtable -NoEnumerate -ErrorAction Stop
        $subscriptionId = ([guid]$pool[0]['id']).ToString('D')
    }
    $tokens = @{
        subscriptionId    = $subscriptionId
        tenantId          = $env:VALIDATE_TENANT_ID
        managementGroupId = if ($env:VALIDATE_MANAGEMENT_GROUP_ID) {
            $env:VALIDATE_MANAGEMENT_GROUP_ID
        }
        else { $env:ARM_MGMTGROUP_ID }
        namePrefix        = $env:TOKEN_NAMEPREFIX
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
