#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Plan')]
param(
    [Parameter(ParameterSetName = 'Plan')] [switch] $PlanOnly = $true,
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [switch] $Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
Import-Module (Join-Path $repositoryRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -ErrorAction Stop
. (Join-Path $repositoryRoot 'repository-management' 'shared' 'TestTenant.ps1')
. (Join-Path $repositoryRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'RetryHelpers.ps1')
. (Join-Path $PSScriptRoot 'lib' 'GitHubVariables.ps1')
. (Join-Path $PSScriptRoot 'lib' 'TestTenantSync.ps1')

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
$configurationPath = Join-Path $repositoryRoot 'repository-management' 'bicep-test-tenant-config' 'config.json'
$configuration = Get-Content -LiteralPath $configurationPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
$options = if ($PSCmdlet.ParameterSetName -ceq 'Apply') { @{ Apply = $Apply } } else { @{ PlanOnly = $PlanOnly } }
Invoke-AvmBicepTestTenantSync -Values $values -Configuration $configuration @options | ConvertTo-Json -Depth 5
