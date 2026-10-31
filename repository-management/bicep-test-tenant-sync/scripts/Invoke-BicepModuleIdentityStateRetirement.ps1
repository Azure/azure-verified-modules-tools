#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $TerraformRoot,
    [Parameter(Mandatory)] [string] $RecoveryReceiptPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
Import-Module (Join-Path $repositoryRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -ErrorAction Stop
$shared = Join-Path $repositoryRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
. (Join-Path $shared 'Logging.ps1')
. (Join-Path $shared 'RetryHelpers.ps1')
. (Join-Path $shared 'TerraformOperations.ps1')
. (Join-Path $shared 'TestTenant.ps1')
. (Join-Path $PSScriptRoot 'lib' 'ModuleConfig.ps1')
. (Join-Path $PSScriptRoot 'lib' 'ModuleIdentitySync.ps1')

$null = Resolve-AvmBicepSyncRunContext
if (-not $PSCmdlet.ShouldProcess(
        'Bicep subscription-vending identity Terraform ownership',
        'Read state and dry-run the exact state retirement'
    )) {
    [pscustomobject]@{ Status = 'Preview' } | ConvertTo-Json -Compress
    $global:LASTEXITCODE = 0
    return
}

$values = [ordered]@{
    TEST_BAMI_TENANT_ID = $env:TEST_BAMI_TENANT_ID
    TEST_BAMI_CONTROLLER_CLIENT_ID = $env:TEST_BAMI_CONTROLLER_CLIENT_ID
    TEST_BAMI_ADMIN_SUBSCRIPTION_ID = $env:TEST_BAMI_ADMIN_SUBSCRIPTION_ID
    TEST_BAMI_SUBSCRIPTION_IDS = $env:TEST_BAMI_SUBSCRIPTION_IDS
    TEST_BAMI_MANAGEMENT_GROUP_ID = $env:TEST_BAMI_MANAGEMENT_GROUP_ID
    TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME = $env:TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME
    TEST_BAMI_BICEP_CLIENT_ID = $env:TEST_BAMI_BICEP_CLIENT_ID
    TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID = $env:TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
    TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_RESOURCE_ID = $env:TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_RESOURCE_ID
    TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_CLIENT_ID = $env:TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_CLIENT_ID
    TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_PRINCIPAL_ID = $env:TEST_BAMI_SUBSCRIPTION_VENDING_IDENTITY_PRINCIPAL_ID
    TEST_BAMI_SUBSCRIPTION_VENDING_MANAGEMENT_GROUP_ID = $env:TEST_BAMI_SUBSCRIPTION_VENDING_MANAGEMENT_GROUP_ID
    TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE = $env:TEST_BAMI_SUBSCRIPTION_VENDING_BILLING_SCOPE
}
$backend = @{
    TenantId = $env:ARM_BACKEND_TENANT_ID
    SubscriptionId = $env:ARM_BACKEND_SUBSCRIPTION_ID
    ClientId = $env:ARM_BACKEND_CLIENT_ID
    StorageAccountName = $env:ARM_BACKEND_STORAGE_ACCOUNT_NAME
    ContainerName = $env:ARM_BACKEND_STORAGE_CONTAINER_NAME
}
$configuration = ConvertFrom-AvmTestTenantJson -Json (
    Get-Content -LiteralPath (Join-Path $repositoryRoot 'repository-management' 'bicep-config' 'config.json') -Raw -ErrorAction Stop
)
Invoke-AvmBicepSubscriptionVendingStateRetirementPreparation -TerraformRoot $TerraformRoot `
    -Values $values -Backend $backend -Configuration $configuration -RecoveryReceiptPath $RecoveryReceiptPath |
    ConvertTo-Json -Compress
$global:LASTEXITCODE = 0
