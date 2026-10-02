function Get-AvmBicepWorkflowEnvironment {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch] $Enabled)

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $result = @{
        Variables = @{}; Secrets = @{}; Tokens = @{}
        PoolJson = ''; SubscriptionId = ''; TenantId = ''; KeyVaultName = ''
    }
    if (-not $Enabled) { return $result }
    foreach ($entry in @(
            @{ Name = 'Variables'; Environment = 'AVM_CI_VARIABLES' }
            @{ Name = 'Secrets'; Environment = 'AVM_CI_SECRETS' }
        )) {
        $value = [System.Environment]::GetEnvironmentVariable($entry.Environment, 'Process')
        if ([string]::IsNullOrEmpty($value)) { continue }
        try {
            $parsed = ConvertFrom-Json -InputObject $value -AsHashtable -NoEnumerate -ErrorAction Stop
        }
        catch [System.ArgumentException] {
            throw [AvmConfigurationException]::new("$($entry.Environment) must contain a JSON object.")
        }
        if ($parsed -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new("$($entry.Environment) must contain a JSON object.")
        }
        $result[$entry.Name] = $parsed
    }
    $environment = [System.Environment]::GetEnvironmentVariables('Process')
    foreach ($name in $environment.psbase.Keys) {
        if ($name.StartsWith('localToken_', [System.StringComparison]::OrdinalIgnoreCase)) {
            $tokenName = $name.Substring('localToken_'.Length)
            if ($result.Tokens.ContainsKey($tokenName)) {
                throw [AvmConfigurationException]::new("Duplicate local Bicep token '$tokenName'.")
            }
            $result.Tokens[$tokenName] = $environment[$name]
        }
    }
    if ([string]::IsNullOrEmpty($result.Tokens['namePrefix']) -and
        -not [string]::IsNullOrEmpty($environment['TOKEN_NAMEPREFIX'])) {
        $result.Tokens['namePrefix'] = $environment['TOKEN_NAMEPREFIX']
    }
    foreach ($entry in @(
            @{ Name = 'PoolJson'; Environment = 'TEST_SUBSCRIPTION_IDS' }
            @{ Name = 'SubscriptionId'; Environment = 'VALIDATE_SUBSCRIPTION_ID' }
            @{ Name = 'TenantId'; Environment = 'VALIDATE_TENANT_ID' }
            @{ Name = 'KeyVaultName'; Environment = 'CI_KEY_VAULT_NAME' }
        )) {
        $result[$entry.Name] = [string]$environment[$entry.Environment]
    }
    return $result
}
