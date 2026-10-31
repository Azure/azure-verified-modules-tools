#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $StorageAccountName,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $ContainerName,
    [Parameter(Mandatory)] [string] $ReceiptPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
Import-Module (Join-Path $repositoryRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -ErrorAction Stop
$shared = Join-Path $repositoryRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
. (Join-Path $shared 'Logging.ps1')
. (Join-Path $shared 'RetryHelpers.ps1')

foreach ($identifier in @($TenantId, $SubscriptionId)) {
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact($identifier, 'D', [ref]$guid) -or $guid -eq [guid]::Empty) {
        throw [System.ArgumentException]::new('The receipt target contains an invalid Azure identifier.')
    }
}
if ($StorageAccountName -cnotmatch '^[a-z0-9]{3,24}$' -or
    $ResourceGroupName -cnotmatch '^[a-zA-Z0-9_().-]{1,90}$' -or
    $ResourceGroupName.EndsWith('.') -or
    $ContainerName -cnotmatch '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$') {
    throw [System.ArgumentException]::new('The receipt target contains an invalid storage identifier.')
}

$token = Invoke-RepositorySyncProcess -Command az -Arguments @(
    'account', 'get-access-token', '--tenant', $TenantId, '--resource', 'https://management.azure.com/',
    '--only-show-errors', '--output', 'tsv', '--query', 'expiresOn'
) -TimeoutSec 60
if ($token.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($token.StdOut)) {
    throw [System.InvalidOperationException]::new('State recovery receipt requires an active exact-tenant Azure CLI session.')
}

$properties = Invoke-RepositorySyncProcess -Command az -Arguments @(
    'storage', 'account', 'blob-service-properties', 'show',
    '--account-name', $StorageAccountName,
    '--resource-group', $ResourceGroupName,
    '--subscription', $SubscriptionId,
    '--only-show-errors', '--output', 'json',
    '--query', '{versioningEnabled:isVersioningEnabled,deleteRetentionEnabled:deleteRetentionPolicy.enabled,deleteRetentionDays:deleteRetentionPolicy.days,allowPermanentDelete:deleteRetentionPolicy.allowPermanentDelete}'
) -TimeoutSec 60
if ($properties.ExitCode -ne 0) {
    throw [System.InvalidOperationException]::new('State recovery receipt could not verify blob versioning and deletion retention.')
}
try {
    $policy = ConvertFrom-Json -InputObject $properties.StdOut -AsHashtable -Depth 10 -ErrorAction Stop
}
catch {
    throw [System.IO.InvalidDataException]::new('State recovery receipt received invalid blob-service properties evidence.')
}
if ($policy -isnot [System.Collections.IDictionary] -or
    $policy['versioningEnabled'] -ne $true -or
    $policy['deleteRetentionEnabled'] -ne $true -or
    $policy['deleteRetentionDays'] -isnot [long] -or
    $policy['deleteRetentionDays'] -lt 7 -or
    $policy['allowPermanentDelete'] -ne $false) {
    throw [System.InvalidOperationException]::new('State recovery receipt requires enabled versioning and protected deletion retention of at least seven days.')
}

$policyUri = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Storage/storageAccounts/{2}/managementPolicies/default?api-version=2023-05-01' -f `
    $SubscriptionId, $ResourceGroupName, $StorageAccountName
$lifecycle = Invoke-RepositorySyncProcess -Command az -Arguments @(
    'rest', '--method', 'get', '--url', $policyUri, '--only-show-errors', '--output', 'json'
) -TimeoutSec 60
$lifecycleText = @($lifecycle.StdOut, $lifecycle.StdErr) -join "`n"
if ($lifecycle.ExitCode -eq 0 -or -not [regex]::IsMatch($lifecycleText, '(?i)\bManagementPolicyNotFound\b')) {
    throw [System.InvalidOperationException]::new('State recovery receipt requires ManagementPolicyNotFound lifecycle-policy evidence.')
}

$observedAt = [datetime]::UtcNow
$receipt = [ordered]@{
    schemaVersion = 1
    observedAtUtc = $observedAt.ToString('O', [cultureinfo]::InvariantCulture)
    expiresAtUtc = $observedAt.AddMinutes(15).ToString('O', [cultureinfo]::InvariantCulture)
    tenantId = $TenantId
    subscriptionId = $SubscriptionId
    storageAccountName = $StorageAccountName
    resourceGroupName = $ResourceGroupName
    containerName = $ContainerName
    stateKey = 'bicep-module-identities.tfstate'
    versioningEnabled = $true
    deleteRetentionEnabled = $true
    deleteRetentionDays = $policy['deleteRetentionDays']
    allowPermanentDelete = $false
    lifecycleManagementPolicyErrorCode = 'ManagementPolicyNotFound'
}
if ($PSCmdlet.ShouldProcess($ReceiptPath, 'Write temporary state recovery-policy receipt')) {
    $directory = Split-Path -Parent $ReceiptPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($ReceiptPath),
        (ConvertTo-Json -InputObject $receipt -Depth 5) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}
[pscustomobject]@{
    ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    ExpiresAtUtc = $receipt.expiresAtUtc
} | ConvertTo-Json -Compress
