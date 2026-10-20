function Get-AvmTerraformAuthenticationEnvironment {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable] $Environment = @{}
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $result = @{} + $Environment
    $authentication = @{}
    foreach ($name in @(
            'ARM_SUBSCRIPTION_ID', 'ARM_TENANT_ID', 'ARM_CLIENT_ID', 'ARM_CLIENT_SECRET',
            'ARM_CLIENT_SECRET_FILE_PATH', 'ARM_CLIENT_CERTIFICATE', 'ARM_CLIENT_CERTIFICATE_PATH',
            'ARM_USE_CLI', 'ARM_USE_OIDC', 'ARM_USE_MSI', 'ARM_USE_AKS_WORKLOAD_IDENTITY',
            'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_FEDERATED_TOKEN_FILE'
        )) {
        $authentication[$name] = if ($Environment.ContainsKey($name)) {
            [string]$Environment[$name]
        }
        else {
            [Environment]::GetEnvironmentVariable($name)
        }
    }

    $enabled = @{}
    foreach ($name in @('ARM_USE_CLI', 'ARM_USE_OIDC', 'ARM_USE_MSI', 'ARM_USE_AKS_WORKLOAD_IDENTITY')) {
        $value = $authentication[$name]
        if ([string]::IsNullOrWhiteSpace($value)) {
            $enabled[$name] = $name -eq 'ARM_USE_CLI'
        }
        elseif ($value -cmatch '^(1|[tT]|TRUE|true|True)$') {
            $enabled[$name] = $true
        }
        elseif ($value -cmatch '^(0|[fF]|FALSE|false|False)$') {
            $enabled[$name] = $false
        }
        else {
            throw [AvmConfigurationException]::new(
                "Terraform Azure authentication: '$name' must be a boolean. Correct the environment or .env file before retrying.")
        }
    }

    $subscription = $authentication.ARM_SUBSCRIPTION_ID
    $subscriptionGuid = [guid]::Empty
    if (-not [string]::IsNullOrWhiteSpace($subscription) -and
        (-not [guid]::TryParse($subscription, [ref]$subscriptionGuid) -or $subscriptionGuid -eq [guid]::Empty)) {
        throw [AvmConfigurationException]::new(
            'Terraform Azure authentication: ARM_SUBSCRIPTION_ID must be a nonempty subscription GUID. Correct the environment or .env file before retrying.')
    }

    $servicePrincipal = @(
        'ARM_CLIENT_SECRET', 'ARM_CLIENT_SECRET_FILE_PATH', 'ARM_CLIENT_CERTIFICATE', 'ARM_CLIENT_CERTIFICATE_PATH'
    ).Where({ -not [string]::IsNullOrWhiteSpace($authentication[$_]) }).Count -gt 0
    if ($servicePrincipal -or $enabled.ARM_USE_OIDC -or $enabled.ARM_USE_MSI -or $enabled.ARM_USE_AKS_WORKLOAD_IDENTITY) {
        $missing = [System.Collections.Generic.List[string]]::new()
        if ([string]::IsNullOrWhiteSpace($subscription)) { $missing.Add('ARM_SUBSCRIPTION_ID') }
        if ($enabled.ARM_USE_AKS_WORKLOAD_IDENTITY) {
            foreach ($name in @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_FEDERATED_TOKEN_FILE')) {
                if ([string]::IsNullOrWhiteSpace($authentication[$name])) { $missing.Add($name) }
            }
        }
        elseif (-not $enabled.ARM_USE_MSI) {
            foreach ($name in @('ARM_TENANT_ID', 'ARM_CLIENT_ID')) {
                if ([string]::IsNullOrWhiteSpace($authentication[$name])) { $missing.Add($name) }
            }
        }
        if ($missing.Count -gt 0) {
            throw [AvmConfigurationException]::new(
                ("Terraform Azure authentication is incomplete: set {0} in the environment or .env file for the selected authentication method. Azure CLI is not used to fill incomplete non-CLI credentials." -f ($missing -join ', ')))
        }
        return $result
    }

    if (-not $enabled.ARM_USE_CLI) {
        throw [AvmConfigurationException]::new(
            'Terraform Azure authentication is not configured and ARM_USE_CLI disables Azure CLI. Set ARM_SUBSCRIPTION_ID, ARM_TENANT_ID, ARM_CLIENT_ID and ARM_CLIENT_SECRET, or configure certificate, OIDC or managed-identity authentication.')
    }

    try {
        $cli = Resolve-AvmAzureCli
    }
    catch [AvmToolException] {
        throw [AvmConfigurationException]::new(
            "Terraform Azure authentication requires Azure CLI on PATH with an authenticated subscription, or ARM_* credentials. Make 'az' available on this terminal's PATH, then run 'az login' and 'az account set --subscription <subscription-id>' yourself. Alternatively set ARM_SUBSCRIPTION_ID, ARM_TENANT_ID, ARM_CLIENT_ID and ARM_CLIENT_SECRET, or configure certificate, OIDC or managed-identity authentication.",
            $_.Exception)
    }

    $arguments = @('account', 'show', '--only-show-errors', '--output', 'json',
        '--query', '{subscriptionId:id,tenantId:tenantId,state:state}')
    if (-not [string]::IsNullOrWhiteSpace($subscription)) {
        $arguments += @('--subscription', $subscription)
    }
    try {
        $cliEnvironment = @{} + $result
        foreach ($name in $cli.EnvVars.Keys) {
            $cliEnvironment[$name] = $cli.EnvVars[$name]
        }
        $accountResult = Invoke-AvmProcess -FilePath $cli.Path `
            -ArgumentList ($cli.ArgumentPrefix + $arguments) `
            -EnvVars $cliEnvironment `
            -Label 'Terraform Azure authentication preflight' -TimeoutSec 30 -IgnoreExitCode
    }
    catch [AvmProcessException] {
        throw [AvmConfigurationException]::new(
            "Terraform Azure authentication: Azure CLI could not run. Repair 'az' on PATH or configure ARM_* credentials.", $_.Exception)
    }
    catch [System.TimeoutException] {
        throw [AvmConfigurationException]::new(
            'Terraform Azure authentication: Azure CLI account inspection timed out. Check the CLI session or configure ARM_* credentials.', $_.Exception)
    }
    if ($accountResult.ExitCode -ne 0) {
        throw [AvmConfigurationException]::new(
            "Terraform Azure authentication: Azure CLI has no usable selected subscription. Run 'az login' and 'az account set --subscription <subscription-id>' yourself, or configure ARM_* credentials. No Terraform operation was started.")
    }
    try {
        $account = ConvertFrom-Json -InputObject $accountResult.StdOut -AsHashtable -NoEnumerate -ErrorAction Stop
    }
    catch [System.ArgumentException] {
        throw [AvmConfigurationException]::new(
            'Terraform Azure authentication: Azure CLI returned invalid account JSON. Check the CLI session before retrying.')
    }
    $accountSubscription = [guid]::Empty
    $accountTenant = [guid]::Empty
    if ($account -isnot [System.Collections.IDictionary] -or
        -not $account.Contains('subscriptionId') -or
        -not [guid]::TryParse([string]$account.subscriptionId, [ref]$accountSubscription) -or
        $accountSubscription -eq [guid]::Empty -or
        -not $account.Contains('tenantId') -or
        -not [guid]::TryParse([string]$account.tenantId, [ref]$accountTenant) -or
        $accountTenant -eq [guid]::Empty -or
        $accountSubscription -eq $accountTenant -or
        -not $account.Contains('state') -or $account.state -ne 'Enabled' -or
        ($subscription -and $accountSubscription -ne $subscriptionGuid) -or
        ($authentication.ARM_TENANT_ID -and $authentication.ARM_TENANT_ID -ne $accountTenant.ToString())) {
        throw [AvmConfigurationException]::new(
            "Terraform Azure authentication: Azure CLI did not confirm an enabled subscription and tenant matching ARM_SUBSCRIPTION_ID/ARM_TENANT_ID. Check 'az account show', select the intended subscription, and correct the environment or .env file.")
    }

    $result.ARM_SUBSCRIPTION_ID = $accountSubscription.ToString()
    $result.ARM_TENANT_ID = $accountTenant.ToString()
    return $result
}
