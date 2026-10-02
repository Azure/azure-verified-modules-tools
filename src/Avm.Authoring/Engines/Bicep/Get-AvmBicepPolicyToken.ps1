function Get-AvmBicepPolicyToken {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    Set-StrictMode -Version 3.0
    $tokens = @{
        subscriptionId    = $env:VALIDATE_SUBSCRIPTION_ID
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
