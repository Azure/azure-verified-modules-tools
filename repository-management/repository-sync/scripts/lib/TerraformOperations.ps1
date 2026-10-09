# Terraform lifecycle operations for the single repository state.

# Removes per-run artifacts from the Terraform module directory so each repo
# starts from a known-clean state. Skipped when the caller passes
# `-skipCleanup` to the sync script (useful for local debugging).
function Clear-TerraformWorkspace {
    param([string]$terraformModulePath)

    if (Test-Path -LiteralPath (Join-Path $terraformModulePath 'terraform.tfstate')) {
        throw [System.InvalidOperationException]::new('Local Terraform state exists. Preserve and inspect it; workspace cleanup must not delete state.')
    }
    if (Test-Path "$terraformModulePath/.terraform") {
        Remove-Item "$terraformModulePath/.terraform" -Recurse -Force
    }
    if (Test-Path "$terraformModulePath/terraform.tfvars.json") {
        Remove-Item "$terraformModulePath/terraform.tfvars.json" -Force
    }
    if (Test-Path "$terraformModulePath/.terraform.lock.hcl") {
        Remove-Item "$terraformModulePath/.terraform.lock.hcl" -Force
    }
    if (Test-Path "$terraformModulePath/imports.tf") {
        Remove-Item "$terraformModulePath/imports.tf" -Force
    }
}

function Resolve-RepositorySyncStateIdentity {
    param(
        [string]$TenantId,
        [string]$SubscriptionId,
        [string]$ClientId
    )

    $values = @($TenantId, $SubscriptionId, $ClientId)
    $configured = @($values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($configured.Count -eq 0) {
        return $null
    }
    if ($configured.Count -ne 3) {
        throw [System.ArgumentException]::new(
            'Set all three state identity values (tenant, subscription, client), or leave all three unset.'
        )
    }
    foreach ($value in $values) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($value, [ref]$id) -or $id -eq [guid]::Empty) {
            throw [System.ArgumentException]::new('State identity values must be non-empty GUIDs.')
        }
    }

    return [pscustomobject]@{
        TenantId = ([guid]$TenantId).ToString()
        SubscriptionId = ([guid]$SubscriptionId).ToString()
        ClientId = ([guid]$ClientId).ToString()
    }
}

function Resolve-RepositorySyncStateConfiguration {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Backend
    )

    $names = @('TenantId', 'SubscriptionId', 'ClientId', 'StorageAccountName', 'ContainerName')
    $configured = @($names | Where-Object { -not [string]::IsNullOrWhiteSpace($Backend[$_]) })
    if ($configured.Count -ne $names.Count) {
        throw [System.ArgumentException]::new(
            'Set all five backend identity and storage values (tenant, subscription, client, storage account, container).'
        )
    }
    $identity = Resolve-RepositorySyncStateIdentity `
        -TenantId $Backend.TenantId -SubscriptionId $Backend.SubscriptionId -ClientId $Backend.ClientId
    if ($Backend.StorageAccountName -cnotmatch '^[a-z0-9]{3,24}$') {
        throw [System.ArgumentException]::new('The state storage account must have 3-24 lowercase letters or digits.')
    }
    if ($Backend.ContainerName -cnotmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' -or
        $Backend.ContainerName.Contains('--')) {
        throw [System.ArgumentException]::new('The state container must have 3-63 lowercase letters, digits, or single hyphens, with no leading or trailing hyphen.')
    }
    return [pscustomobject]@{
        TenantId = $identity.TenantId
        SubscriptionId = $identity.SubscriptionId
        ClientId = $identity.ClientId
        StorageAccountName = $Backend.StorageAccountName
        ContainerName = $Backend.ContainerName
    }
}

function Get-RepositorySyncTerraformEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [AllowNull()] [System.Collections.IDictionary] $Settings
    )

    $environment = @{
        TF_DATA_DIR = Join-Path $Root '.terraform'
        TF_IN_AUTOMATION = 'true'
        TF_INPUT = 'false'
        TF_WORKSPACE = 'default'
        TF_LOG = $null
        TF_LOG_CORE = $null
        TF_LOG_PROVIDER = $null
        TF_LOG_PATH = $null
        ARM_CLIENT_SECRET = $null
        ARM_CLIENT_CERTIFICATE_PATH = $null
        ARM_CLIENT_CERTIFICATE = $null
        ARM_CLIENT_CERTIFICATE_PASSWORD = $null
        ARM_ACCESS_KEY = $null
        ARM_SAS_TOKEN = $null
        ARM_OIDC_TOKEN = $null
        ARM_OIDC_TOKEN_FILE_PATH = $null
        ARM_USE_OIDC = 'true'
        ARM_USE_CLI = 'false'
        ARM_USE_MSI = 'false'
    }
    foreach ($name in @('TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_plan', 'TF_CLI_ARGS_apply', 'TF_CLI_ARGS_show') +
        @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -clike 'TF_CLI_ARGS*' })) {
        $environment[$name] = $null
    }
    if ($null -ne $Settings) {
        $settings = Get-AvmBamiSettings -Values $Settings
        $environment.ARM_TENANT_ID = $settings['TEST_BAMI_TENANT_ID']
        $environment.ARM_SUBSCRIPTION_ID = $settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID']
        $environment.ARM_CLIENT_ID = $settings['TEST_BAMI_CONTROLLER_CLIENT_ID']
    }
    return $environment
}

function Invoke-RepositorySyncTerraform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $Root,
        [hashtable] $Environment = @{},
        [switch] $Json,
        [switch] $Quiet
    )

    if (-not $Json -and -not $Quiet) {
        Write-Information "Running Terraform $($Arguments[0])..." -InformationAction Continue
    }
    try {
        $result = Invoke-RepositorySyncProcess -Command terraform -Arguments $Arguments `
            -WorkingDirectory $Root -EnvVars $Environment -TimeoutSec 1800
    }
    catch [System.TimeoutException] {
        $message = "Terraform $($Arguments[0]) timed out; the child process was stopped. Inspect state ownership before retrying an interrupted apply."
        if (-not $Json -and -not $Quiet) {
            $message += "`n" + (Protect-RepositorySyncLogText -Text (@(
                $_.Exception.Data['StdOut'], $_.Exception.Data['StdErr']
            ) -join "`n"))
        }
        throw [System.TimeoutException]::new($message)
    }
    if ($result.ExitCode -ne 0) {
        $message = "Terraform $($Arguments[0]) failed (exit code $($result.ExitCode)); no automatic apply retry or state repair was attempted."
        if (-not $Json) {
            $message += "`n" + (Protect-RepositorySyncLogText -Text (@($result.StdOut, $result.StdErr) -join "`n"))
        }
        $exception = [System.InvalidOperationException]::new($message)
        $exception.Data['ExitCode'] = $result.ExitCode
        throw $exception
    }
    if ($Json) {
        try {
            $document = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -Depth 100 -ErrorAction Stop
        }
        catch {
            throw [System.IO.InvalidDataException]::new('Terraform returned invalid plan JSON; raw plan data is not logged.')
        }
        if ($document -isnot [System.Collections.IDictionary]) {
            throw [System.IO.InvalidDataException]::new('Terraform must return one plan JSON object.')
        }
        return $document
    }
    if ($Quiet) { return }
    foreach ($text in @($result.StdOut, $result.StdErr)) {
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-Information (Protect-RepositorySyncLogText -Text $text) -InformationAction Continue
        }
    }
}

function Invoke-TerraformInit {
    param(
        [string]$terraformModulePath,
        [bool]$repositoryCreationModeEnabled,
        [string]$repoId,
        [string]$orgAndRepoName,
        [string]$stateStorageAccountName,
        [string]$stateContainerName,
        [string]$stateTenantId,
        [string]$stateSubscriptionId,
        [string]$stateClientId,
        [array]$issueLog,
        [hashtable]$environment = @{}
    )

    if ($repositoryCreationModeEnabled) {
        Set-Content -LiteralPath (Join-Path $terraformModulePath 'backend_override.tf') -Encoding utf8NoBOM -Value @"
terraform {
    backend "local" {}
}
"@

        $initArguments = @('init', '-upgrade', '-input=false', '-no-color')
    } else {
        foreach ($name in @('backend_override.tf', 'terraform.tfstate')) {
            if (Test-Path -LiteralPath (Join-Path $terraformModulePath $name)) {
                throw [System.InvalidOperationException]::new("Normal sync cannot use a workspace containing '$name'. Preserve and inspect the local bootstrap before continuing.")
            }
        }
        $state = Resolve-RepositorySyncStateConfiguration -Backend @{
            TenantId = $stateTenantId
            SubscriptionId = $stateSubscriptionId
            ClientId = $stateClientId
            StorageAccountName = $stateStorageAccountName
            ContainerName = $stateContainerName
        }
        $initArguments = @(
            'init', '-upgrade', '-input=false', '-no-color', '-reconfigure',
            "-backend-config=storage_account_name=$($state.StorageAccountName)",
            "-backend-config=container_name=$($state.ContainerName)",
            "-backend-config=key=$repoId.tfstate",
            "-backend-config=tenant_id=$($state.TenantId)",
            "-backend-config=subscription_id=$($state.SubscriptionId)",
            "-backend-config=client_id=$($state.ClientId)",
            "-backend-config=use_azuread_auth=true",
            "-backend-config=use_oidc=true",
            "-backend-config=use_cli=false",
            "-backend-config=use_msi=false",
            "-backend-config=lookup_blob_endpoint=false"
        )
    }
    Invoke-RepositorySyncTerraform -Arguments $initArguments -Root $terraformModulePath -Environment $environment
    return $issueLog
}

function Invoke-TerraformPlanAndApply {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$terraformModulePath,
        [string]$repoId,
        [string]$orgAndRepoName,
        [bool]$planOnly,
        [string[]]$resourceTypesThatCannotBeDestroyed,
        [string]$stateStorageAccountName,
        [string]$stateContainerName,
        [string]$stateSubscriptionId,
        [array]$issueLog,
        [hashtable]$environment = @{},
        [AllowNull()] [System.Collections.IDictionary] $bamiSettings,
        [AllowNull()] [object] $repository,
        [string] $repositorySyncRepositoryId,
        [string[]] $entraGroupNames = @(),
        [string] $jobWorkflowRef = 'Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@refs/heads/main'
    )

    if (-not $PSCmdlet.ShouldProcess($orgAndRepoName, 'Plan repository configuration and test identity')) {
        return $issueLog
    }
    $planPath = Join-Path $terraformModulePath "$repoId.tfplan"
    Invoke-RepositorySyncTerraform -Root $terraformModulePath -Environment $environment -Arguments @(
        'plan', '-input=false', '-no-color', '-lock-timeout=5m', "-out=$planPath"
    )
    $plan = Invoke-RepositorySyncTerraform -Root $terraformModulePath -Environment $environment `
        -Arguments @('show', '-json', $planPath) -Json
    Assert-AvmRepositorySyncPlan -Plan $plan -Settings $bamiSettings -Repository $repository `
        -RepositorySyncRepositoryId $repositorySyncRepositoryId -EntraGroupNames $entraGroupNames `
        -JobWorkflowRef $jobWorkflowRef -ResourceTypesThatCannotBeDestroyed $resourceTypesThatCannotBeDestroyed
    if (-not $planOnly -and $PSCmdlet.ShouldProcess($orgAndRepoName, 'Apply the verified saved repository plan')) {
        Invoke-RepositorySyncTerraform -Root $terraformModulePath -Environment $environment -Arguments @(
            'apply', '-input=false', '-no-color', '-lock-timeout=5m', $planPath
        )
    }
    return $issueLog
}
