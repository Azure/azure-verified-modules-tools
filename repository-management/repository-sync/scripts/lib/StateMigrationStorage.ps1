function Invoke-RepositoryMigrationAzure {
    param([string[]] $Arguments, [hashtable] $Backend, [switch] $AllowBlobNotFound)

    $null = Resolve-RepositorySyncStateConfiguration -Backend $Backend
    $environment = @{}
    foreach ($name in [Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -clike 'AZURE_STORAGE_*' }) {
        $environment[$name] = $null
    }
    $result = Invoke-RepositorySyncProcess -Command az -Arguments ($Arguments + @(
        '--only-show-errors', '--output', 'json'
    )) -EnvVars $environment -TimeoutSec 300
    if ($result.ExitCode -ne 0) {
        if ($AllowBlobNotFound -and ($Arguments[0..2] -join ' ') -ceq 'storage blob show' -and
            $result.StdErr -cmatch '(?m)^ErrorCode:BlobNotFound\r?$') {
            return $null
        }
        $diagnostic = [regex]::Match($result.StdErr, '(?m)^ErrorCode:(?<code>[A-Za-z][A-Za-z0-9]{0,79})\r?$')
        $code = $diagnostic.Groups['code'].Value
        if ($code -cnotin @(
            'AuthenticationFailed', 'AuthorizationFailure', 'AuthorizationPermissionMismatch', 'InvalidAuthenticationInfo',
            'BlobNotFound', 'ContainerNotFound', 'BlobAlreadyExists', 'ConditionNotMet',
            'LeaseAlreadyPresent', 'LeaseIdMissing', 'LeaseIdMismatchWithBlobOperation'
        )) {
            $code = [regex]::Match($result.StdErr, '\bAADSTS[0-9]{3,12}\b').Value
        }
        $status = "exit $($result.ExitCode)"
        if ($code) { $status += ", $code" }
        $exception = [InvalidOperationException]::new(
            "Migration storage operation '$(($Arguments | Select-Object -First 3) -join ' ')' failed ($status); no retry or credential fallback was attempted."
        )
        $exception.Data['ExitCode'] = $result.ExitCode
        throw $exception
    }
    try { $document = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -Depth 100 -NoEnumerate -ErrorAction Stop }
    catch { throw 'Migration storage returned invalid private JSON; contents are not logged.' }
    if ($null -eq $document) { throw 'Migration storage returned no usable response; publication is blocked.' }
    return $document
}

function Get-RepositoryMigrationBlobArguments {
    param([hashtable] $Backend)
    return @('--account-name', $Backend.StorageAccountName, '--container-name', $Backend.ContainerName, '--auth-mode', 'login')
}

function Assert-RepositoryMigrationStorage {
    param([hashtable] $Backend)

    $null = Resolve-RepositorySyncStateConfiguration -Backend $Backend
    $account = Invoke-RepositoryMigrationAzure -Backend $Backend -Arguments @('account', 'show')
    if ($account -isnot [System.Collections.IDictionary] -or $account['user'] -isnot [System.Collections.IDictionary] -or
        $account['environmentName'] -cne 'AzureCloud' -or
        $account['tenantId'] -ine $Backend.TenantId -or
        $account['user']['name'] -ine $Backend.ClientId -or $account['user']['type'] -cne 'servicePrincipal') {
        throw 'Migration requires the exact TME backend service principal and tenant, without subscription Reader access.'
    }
    $container = Invoke-RepositoryMigrationAzure -Backend $Backend -Arguments (
        @('storage', 'container', 'show', '--name', $Backend.ContainerName,
            '--account-name', $Backend.StorageAccountName, '--auth-mode', 'login')
    )
    if ($container -isnot [System.Collections.IDictionary] -or $container['properties'] -isnot [System.Collections.IDictionary] -or
        -not $container['properties'].Contains('publicAccess') -or $container['name'] -cne $Backend.ContainerName -or
        $container['properties']['publicAccess'] -notin @($null, 'None', 'none')) {
        throw 'Migration backups require the configured private state container.'
    }
}

function Get-RepositoryMigrationBlobList {
    param([hashtable] $Backend, [string] $Prefix)

    return Invoke-RepositoryMigrationAzure -Backend $Backend -Arguments (
        @('storage', 'blob', 'list', '--num-results', '*', '--prefix', $Prefix) + (Get-RepositoryMigrationBlobArguments $Backend)
    )
}

function Get-RepositoryMigrationBlob {
    param([hashtable] $Backend, [string] $Name, [string] $Path)

    $arguments = Get-RepositoryMigrationBlobArguments $Backend
    $metadata = Invoke-RepositoryMigrationAzure -Backend $Backend -AllowBlobNotFound -Arguments (
        @('storage', 'blob', 'show', '--name', $Name) + $arguments
    )
    if ($null -eq $metadata) { return $false }
    if ($metadata -isnot [System.Collections.IDictionary] -or $metadata['properties'] -isnot [System.Collections.IDictionary] -or
        $metadata['properties']['lease'] -isnot [System.Collections.IDictionary] -or
        $metadata['name'] -cne $Name -or $metadata['properties']['lease']['status'] -cne 'unlocked' -or
        [string]::IsNullOrWhiteSpace([string]$metadata['properties']['etag']) -or
        $metadata['properties']['contentLength'] -le 0) {
        throw "Blob '$Name' is locked, empty, or has incomplete metadata; no lock will be broken."
    }
    $null = Invoke-RepositoryMigrationAzure -Backend $Backend -Arguments (
        @('storage', 'blob', 'download', '--name', $Name, '--file', $Path, '--overwrite', 'true',
            '--if-match', $metadata['properties']['etag'], '--no-progress') + $arguments
    )
    return $true
}

function Save-RepositoryMigrationBlob {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable] $Backend, [string] $Name, [string] $Path)

    if ($Name -cnotmatch '^bami-consolidation/[0-9a-f-]{36}/avm-(res|ptn|utl)-[a-z0-9-]+/(backup\.zip|complete\.json)$') {
        throw 'Migration may upload only create-only backup or completion files, never a state blob.'
    }
    $check = "$Path.readback"
    if (Get-RepositoryMigrationBlob -Backend $Backend -Name $Name -Path $check) {
        if ((Get-FileHash -LiteralPath $Path).Hash -cne (Get-FileHash -LiteralPath $check).Hash) {
            throw "Existing migration file '$Name' differs; it will not be overwritten."
        }
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Create private migration checkpoint without overwriting')) { return }
    $null = Invoke-RepositoryMigrationAzure -Backend $Backend -Arguments (
        @('storage', 'blob', 'upload', '--name', $Name, '--file', $Path, '--type', 'block',
            '--overwrite', 'false', '--if-none-match', '*', '--no-progress') +
        (Get-RepositoryMigrationBlobArguments $Backend)
    )
    if (-not (Get-RepositoryMigrationBlob -Backend $Backend -Name $Name -Path $check) -or
        (Get-FileHash -LiteralPath $Path).Hash -cne (Get-FileHash -LiteralPath $check).Hash) {
        throw "Migration checkpoint '$Name' did not pass readback; no state push is permitted."
    }
}

function Initialize-RepositoryMigrationBackend {
    param([hashtable] $Backend, [string] $Key, [string] $Root, [string] $Terraform)

    $null = [IO.Directory]::CreateDirectory($Root)
    $rootDefinition = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'terraform' 'terraform.tf') -Raw
    $backendDefinition = ($rootDefinition -split '(?m)^provider "', 2)[0]
    if ($backendDefinition -cnotmatch 'backend "azurerm" \{\}') { throw 'The ordinary root backend definition changed; review migration initialization.' }
    [IO.File]::WriteAllText((Join-Path $Root 'main.tf'), $backendDefinition, [Text.UTF8Encoding]::new($false))
    $arguments = @(
        'init', '-input=false', '-no-color', '-reconfigure', '-upgrade',
        "-backend-config=storage_account_name=$($Backend.StorageAccountName)",
        "-backend-config=container_name=$($Backend.ContainerName)", "-backend-config=key=$Key",
        "-backend-config=tenant_id=$($Backend.TenantId)", "-backend-config=subscription_id=$($Backend.SubscriptionId)",
        "-backend-config=client_id=$($Backend.ClientId)", '-backend-config=use_azuread_auth=true',
        '-backend-config=use_oidc=true', '-backend-config=use_cli=false', '-backend-config=use_msi=false',
        '-backend-config=lookup_blob_endpoint=false', '-backend-config=environment=public'
    )
    Invoke-RepositoryMigrationTerraform -Terraform $Terraform -Root $Root -Arguments $arguments
    $metadata = Read-RepositoryMigrationRecord -Path (Join-Path $Root '.terraform' 'terraform.tfstate')
    $config = $metadata['backend']['config']
    if ($metadata['backend']['type'] -cne 'azurerm' -or $config['key'] -cne $Key -or
        $config['storage_account_name'] -cne $Backend.StorageAccountName -or $config['container_name'] -cne $Backend.ContainerName -or
        $config['tenant_id'] -ine $Backend.TenantId -or $config['subscription_id'] -ine $Backend.SubscriptionId -or
        $config['client_id'] -ine $Backend.ClientId -or $config['use_azuread_auth'] -ne $true -or
        $config['use_oidc'] -ne $true -or $config['use_cli'] -ne $false -or $config['use_msi'] -ne $false -or
        $config['lookup_blob_endpoint'] -ne $false -or $config['environment'] -cne 'public') {
        throw 'Initialized backend does not match the exact migration scope.'
    }
}
