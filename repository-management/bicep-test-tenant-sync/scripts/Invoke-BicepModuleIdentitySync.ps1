#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Plan')]
param(
    [Parameter(Mandatory)] [string] $BicepRoot,
    [Parameter(Mandatory)] [string] $MappingPath,
    [Parameter(ParameterSetName = 'Plan')] [switch] $PlanOnly = $true,
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [switch] $Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
Import-Module (Join-Path $repositoryRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -ErrorAction Stop
$shared = Join-Path $repositoryRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
. (Join-Path $shared 'Logging.ps1')
. (Join-Path $shared 'TestTenant.ps1')
. (Join-Path $PSScriptRoot 'lib' 'ModuleConfig.ps1')
. (Join-Path $PSScriptRoot 'lib' 'ModuleIdentitySync.ps1')

$values = [ordered]@{
    TEST_BAMI_TENANT_ID = $env:TEST_BAMI_TENANT_ID
    TEST_BAMI_CONTROLLER_CLIENT_ID = $env:TEST_BAMI_CONTROLLER_CLIENT_ID
    TEST_BAMI_ADMIN_SUBSCRIPTION_ID = $env:TEST_BAMI_ADMIN_SUBSCRIPTION_ID
    TEST_BAMI_SUBSCRIPTION_IDS = $env:TEST_BAMI_SUBSCRIPTION_IDS
    TEST_BAMI_MANAGEMENT_GROUP_ID = $env:TEST_BAMI_MANAGEMENT_GROUP_ID
    TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME = $env:TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME
    TEST_BAMI_BICEP_CLIENT_ID = $env:TEST_BAMI_BICEP_CLIENT_ID
    TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID = $env:TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID
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
$options = if ($PSCmdlet.ParameterSetName -ceq 'Apply') { @{ Apply = $Apply } } else { @{ PlanOnly = $PlanOnly } }
Invoke-AvmBicepModuleIdentitySync -BicepRoot $BicepRoot -MappingPath $MappingPath `
    -TerraformRoot (Join-Path $PSScriptRoot '..' 'terraform') `
    -Values $values -Backend $backend -Configuration $configuration @options | ConvertTo-Json -Depth 5
$global:LASTEXITCODE = 0
