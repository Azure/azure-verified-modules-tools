function Test-AvmAzureCredentialAvailable {
    <#
    .SYNOPSIS
        Report whether the environment already carries a real Azure credential.

    .DESCRIPTION
        The policy stage plans every example. When a real credential is
        present the plan uses it, because that is the only way examples whose
        data sources read existing Azure resources can plan at all. When one
        is absent the caller falls back to a synthetic token, which covers
        every example that only creates resources.

        Detection is deliberately conservative: it looks for the environment
        variables the Azure providers themselves consult, so a trusted CI job
        that exports OIDC or client-secret settings keeps its current
        behaviour, and a contributor or fork with nothing configured gets the
        credential-free path.

        An Azure CLI session is not probed. Doing so would shell out to 'az'
        on every policy run, and a signed-in maintainer would silently get
        different policy results from CI.

    .PARAMETER EnvVars
        Environment overrides layered over the current process environment,
        so an example's .env is considered exactly as the subprocess sees it.

    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [hashtable] $EnvVars
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $read = {
        param([string] $Name)
        if ($null -ne $EnvVars -and $EnvVars.ContainsKey($Name)) {
            return [string]$EnvVars[$Name]
        }
        return [string][System.Environment]::GetEnvironmentVariable($Name)
    }

    $isTrue = {
        param([string] $Value)
        $Value -and $Value.Trim() -in @('1', 'true', 'True', 'TRUE', 'yes', 'on')
    }

    # A client secret or certificate is a complete credential on its own.
    foreach ($name in @('ARM_CLIENT_SECRET', 'ARM_CLIENT_CERTIFICATE_PATH')) {
        if (-not [string]::IsNullOrWhiteSpace((& $read $name))) {
            return $true
        }
    }

    # OIDC needs both the switch and something to exchange.
    if (& $isTrue (& $read 'ARM_USE_OIDC')) {
        foreach ($name in @(
                'ARM_OIDC_TOKEN'
                'ARM_OIDC_TOKEN_FILE_PATH'
                'ARM_OIDC_REQUEST_TOKEN'
                'ACTIONS_ID_TOKEN_REQUEST_TOKEN'
                'AZURE_FEDERATED_TOKEN_FILE'
            )) {
            if (-not [string]::IsNullOrWhiteSpace((& $read $name))) {
                return $true
            }
        }
    }

    # A managed identity or workload identity the caller configured itself.
    if (& $isTrue (& $read 'ARM_USE_MSI')) {
        return $true
    }
    if (& $isTrue (& $read 'ARM_USE_AKS_WORKLOAD_IDENTITY')) {
        return $true
    }

    return $false
}
