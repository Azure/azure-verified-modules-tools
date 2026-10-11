BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $lib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    foreach ($libraryName in @('Logging', 'RetryHelpers', 'TerraformOperations')) {
        . (Join-Path $lib "$libraryName.ps1")
    }

    function Set-TestBackendMetadata {
        $script:backendMetadata | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $script:metadataPath -Encoding utf8NoBOM
    }
}

Describe 'Repository state-lock preflight' -Tag Component {
    BeforeEach {
        $script:previousEnvironment = @{}
        $values = [ordered]@{
            GITHUB_ACTIONS = 'true'
            GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
            GITHUB_REF = 'refs/heads/main'
            GITHUB_WORKFLOW_REF = 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-sync.yml@refs/heads/main'
            REPO_ID = 'avm-ptn-example-repo'
        }
        foreach ($environmentName in $values.Keys) {
            $script:previousEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName)
            [Environment]::SetEnvironmentVariable($environmentName, $values[$environmentName])
        }
        $script:parameters = @{
            workingDirectory = $TestDrive
            storageAccountName = 'stateaccount'
            containerName = 'tfstate'
            blobName = 'avm-ptn-example-repo.tfstate'
            repository = 'Azure/terraform-azurerm-avm-ptn-example-repo'
            tenantId = '44444444-4444-4444-8444-444444444444'
            subscriptionId = '55555555-5555-4555-8555-555555555555'
            clientId = '66666666-6666-4666-8666-666666666666'
            environment = Get-RepositorySyncTerraformEnvironment -Root $TestDrive -Settings $null
        }
        $script:parameters.environment.ARM_CLIENT_ID = '10000000-0000-4000-8000-000000000002'
        $script:parameters.environment.GH_TOKEN = 'synthetic-app-token'
        $script:backendMetadata = @{
            backend = @{
                type = 'azurerm'
                config = @{
                    tenant_id = $script:parameters.tenantId
                    subscription_id = $script:parameters.subscriptionId
                    client_id = $script:parameters.clientId
                    storage_account_name = 'stateaccount'
                    container_name = 'tfstate'
                    key = 'avm-ptn-example-repo.tfstate'
                    use_azuread_auth = $true
                    use_oidc = $true
                    use_cli = $false
                    use_msi = $false
                    lookup_blob_endpoint = $false
                }
            }
        }
        $null = New-Item -ItemType Directory -Path $script:parameters.environment.TF_DATA_DIR -Force
        $script:metadataPath = Join-Path $script:parameters.environment.TF_DATA_DIR 'terraform.tfstate'
        Set-TestBackendMetadata
        $script:fixture = @{
            Calls = [System.Collections.Generic.List[object]]::new()
            Exists = $true
            BlobReads = 0
            Blobs = @(
                @{ etag = '"0xAABBCC"'; leaseState = 'leased'; leaseStatus = 'locked' }
                @{ etag = '"0xAABBCE"'; leaseState = 'available'; leaseStatus = 'unlocked' }
            )
            Account = @{
                id = $script:parameters.subscriptionId
                tenantId = $script:parameters.tenantId
                user = @{ type = 'servicePrincipal'; name = $script:parameters.clientId }
            }
        }
        $fixture = $script:fixture
        Mock Invoke-RepositorySyncProcess ({
            param($Command, $Arguments, $WorkingDirectory, $EnvVars, $TimeoutSec)
            if ($Command -cne 'az') { throw 'Only Azure CLI blob inspection and release are permitted.' }
            $fixture.Calls.Add(@{
                Command = $Command; Arguments = @($Arguments); Root = $WorkingDirectory
                Environment = $EnvVars; Timeout = $TimeoutSec
            })
            $data = if ($Arguments[0] -ceq 'account') {
                $fixture.Account
            }
            elseif ($Arguments[2] -ceq 'exists') {
                @{ exists = $fixture.Exists }
            }
            elseif ($Arguments[2] -ceq 'show') {
                $fixture.Blobs[$fixture.BlobReads++]
            }
            elseif ($Arguments[2] -ceq 'lease') {
                return @{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            else { throw 'Unexpected isolated state-lock command.' }
            return @{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject $data -Depth 10 -Compress); StdErr = '' }
        }.GetNewClosure())
        Mock Start-Process { throw 'Legacy process execution is forbidden.' }
        Mock Write-Warning {}
    }

    AfterEach {
        foreach ($environmentName in $script:previousEnvironment.Keys) {
            $previousValue = $script:previousEnvironment[$environmentName]
            [Environment]::SetEnvironmentVariable($environmentName, ($null -eq $previousValue ? [NullString]::Value : $previousValue))
        }
        Should -Invoke Start-Process -Exactly 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Command -cne 'az' }
    }

    It 'clears a held lease once from branch <Branch> without GitHub polling or Terraform error text' -ForEach @(
        @{ Branch = 'main' }
        @{ Branch = 'telemetry-rehearsal' }
        @{ Branch = 'feature/telemetry-alignment' }
    ) {
        $env:GITHUB_REF = "refs/heads/$Branch"
        $env:GITHUB_WORKFLOW_REF = "Azure/azure-verified-modules-tools/.github/workflows/repository-management-sync.yml@$env:GITHUB_REF"
        Clear-TerraformStateLock @script:parameters | Should -BeTrue
        $script:fixture.BlobReads | Should -Be 2
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
            ($Arguments -join ' ') -ceq (
                'storage blob lease break --account-name stateaccount --container-name tfstate ' +
                '--blob-name avm-ptn-example-repo.tfstate --lease-break-period 0 --if-match "0xAABBCC" ' +
                '--auth-mode login --subscription 55555555-5555-4555-8555-555555555555 --only-show-errors --output none'
            ) -and $EnvVars.ARM_CLIENT_ID -ceq '10000000-0000-4000-8000-000000000002'
        }
        @($script:fixture.Calls | ForEach-Object {
                $_.Arguments[0] -ceq 'account' ? 'account' : $_.Arguments[2]
            }) | Should -Be @('account', 'exists', 'show', 'lease', 'show')
        foreach ($call in $script:fixture.Calls) {
            $call.Timeout | Should -Be 60
            ($call.Arguments -join ' ') | Should -Not -Match 'synthetic-.*token|force-unlock|state (pull|push|rm|mv)|download|--account-key|terraformlockid'
        }
    }

    It 'does not depend on Terraform lock metadata being present or readable' -ForEach @(
        @{ Metadata = $null }
        @{ Metadata = '' }
        @{ Metadata = 'not base64 or JSON' }
    ) {
        $script:fixture.Blobs[0].lockInfo = $Metadata
        Clear-TerraformStateLock @script:parameters | Should -BeTrue
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $Arguments -contains 'break' }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 2 -ParameterFilter {
            $Arguments[2] -ceq 'show' -and $Arguments[-1] -ceq '{etag:properties.etag,leaseState:properties.lease.state,leaseStatus:properties.lease.status}'
        }
    }

    It 'does not release an already unlocked <State> blob' -ForEach @(
        @{ State = 'available' }
        @{ State = 'expired' }
        @{ State = 'broken' }
    ) {
        $script:fixture.Blobs[0] = $script:fixture.Blobs[1].Clone()
        $script:fixture.Blobs[0].leaseState = $State
        Clear-TerraformStateLock @script:parameters | Should -BeTrue
        $script:fixture.BlobReads | Should -Be 1
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'break' }
    }

    It 'allows a new repository whose state blob has not been created' {
        $script:fixture.Exists = $false
        Clear-TerraformStateLock @script:parameters | Should -BeTrue
        $script:fixture.BlobReads | Should -Be 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'break' }
    }

    It 'rejects an unverified existence response' -ForEach @(
        @{ Value = $null }
        @{ Value = 'false' }
    ) {
        $script:fixture.Exists = $Value
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*existence check did not return a boolean*'
        $script:fixture.BlobReads | Should -Be 0
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'break' }
    }

    It 'performs no inspection or mutation for WhatIf' {
        Clear-TerraformStateLock @script:parameters -WhatIf | Should -BeFalse
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'clears inherited storage overrides without changing the caller environment' {
        $previous = [Environment]::GetEnvironmentVariable('AZURE_STORAGE_CONNECTION_STRING')
        $env:AZURE_STORAGE_CONNECTION_STRING = 'synthetic-foreign-endpoint'
        $script:parameters.environment.AZURE_STORAGE_SAS_TOKEN = 'synthetic-storage-token'
        try {
            Clear-TerraformStateLock @script:parameters | Should -BeTrue
            foreach ($call in $script:fixture.Calls) {
                $call.Environment.AZURE_STORAGE_CONNECTION_STRING | Should -BeNullOrEmpty
                $call.Environment.AZURE_STORAGE_SAS_TOKEN | Should -BeNullOrEmpty
            }
            $script:parameters.environment.AZURE_STORAGE_SAS_TOKEN | Should -BeExactly 'synthetic-storage-token'
        }
        finally {
            [Environment]::SetEnvironmentVariable('AZURE_STORAGE_CONNECTION_STRING', ($null -eq $previous ? [NullString]::Value : $previous))
        }
    }

    It 'requires the selected serialized Tools branch job: <Name>' -ForEach @(
        @{ Name = 'GITHUB_ACTIONS'; Value = '' }
        @{ Name = 'GITHUB_REPOSITORY'; Value = 'fork/azure-verified-modules-tools' }
        @{ Name = 'GITHUB_REF'; Value = 'refs/pull/246/merge' }
        @{ Name = 'GITHUB_REF'; Value = 'refs/tags/v1' }
        @{ Name = 'GITHUB_REF'; Value = 'refs/heads/' }
        @{ Name = 'GITHUB_REF'; Value = 'refs/heads/different-workflow-ref' }
        @{ Name = 'GITHUB_WORKFLOW_REF'; Value = 'Azure/azure-verified-modules-tools/.github/workflows/other.yml@refs/heads/main' }
        @{ Name = 'REPO_ID'; Value = 'avm-ptn-other' }
    ) {
        [Environment]::SetEnvironmentVariable($Name, $Value)
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*serialized Terraform Sync job*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'rejects a different backend, key, or authentication mode: <Key>' -ForEach @(
        @{ Key = 'tenant_id'; Value = '10000000-0000-4000-8000-000000000001' }
        @{ Key = 'subscription_id'; Value = '10000000-0000-4000-8000-000000000003' }
        @{ Key = 'client_id'; Value = '10000000-0000-4000-8000-000000000002' }
        @{ Key = 'storage_account_name'; Value = 'differentaccount' }
        @{ Key = 'container_name'; Value = 'otherstate' }
        @{ Key = 'key'; Value = 'Avm-ptn-example-repo.tfstate' }
        @{ Key = 'use_azuread_auth'; Value = $false }
        @{ Key = 'use_oidc'; Value = $false }
        @{ Key = 'use_cli'; Value = $true }
        @{ Key = 'use_msi'; Value = $true }
        @{ Key = 'lookup_blob_endpoint'; Value = $true }
    ) {
        $script:backendMetadata.backend.config[$Key] = $Value
        Set-TestBackendMetadata
        { Clear-TerraformStateLock @script:parameters } | Should -Throw "*Initialized backend '$Key'*"
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'does not inspect a local backend or unreadable metadata' -ForEach @(
        @{ Value = '{"backend":{"type":"local","config":{}}}'; Message = '*explicitly initialized Azure backend*' }
        @{ Value = '{"backend":'; Message = '*Cannot verify initialized backend metadata*' }
        @{ Value = 'null'; Message = '*explicitly initialized Azure backend*' }
    ) {
        Set-Content -LiteralPath $script:metadataPath -Value $Value
        { Clear-TerraformStateLock @script:parameters } | Should -Throw $Message
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'rejects an inexact target or missing backend field: <Key>' -ForEach @(
        @{ Key = 'blobName'; Value = '../another.tfstate'; Message = '*canonical repository state blob*' }
        @{ Key = 'repository'; Value = 'Azure/terraform-azurerm-avm-ptn-other'; Message = '*same module*' }
        @{ Key = 'clientId'; Value = ''; Message = '*all five*' }
    ) {
        $script:parameters[$Key] = $Value
        { Clear-TerraformStateLock @script:parameters } | Should -Throw $Message
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'rejects a nondefault workspace or another data directory: <Key>' -ForEach @(
        @{ Key = 'TF_WORKSPACE'; Value = 'other' }
        @{ Key = 'TF_DATA_DIR'; Value = 'elsewhere' }
    ) {
        $script:parameters.environment[$Key] = $Value
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*initialized default workspace*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'refuses a CLI account that differs from the backend: <Case>' -ForEach @(
        @{ Case = 'subscription'; Change = { param($a) $a.id = '10000000-0000-4000-8000-000000000003' } }
        @{ Case = 'tenant'; Change = { param($a) $a.tenantId = '10000000-0000-4000-8000-000000000001' } }
        @{ Case = 'provider'; Change = { param($a) $a.user.name = '10000000-0000-4000-8000-000000000002' } }
        @{ Case = 'human'; Change = { param($a) $a.user.type = 'user' } }
    ) {
        & $Change $script:fixture.Account
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*authenticated as the selected state backend identity*'
        $script:fixture.BlobReads | Should -Be 0
    }

    It 'rejects incomplete or inconsistent lease properties: <Key>' -ForEach @(
        @{ Key = 'etag'; Value = $null; Message = '*incomplete lease metadata*' }
        @{ Key = 'etag'; Value = '*'; Message = '*incomplete lease metadata*' }
        @{ Key = 'leaseState'; Value = 'unknown'; Message = '*incomplete lease metadata*' }
        @{ Key = 'leaseStatus'; Value = 'unknown'; Message = '*incomplete lease metadata*' }
        @{ Key = 'leaseState'; Value = 'available'; Message = '*inconsistent properties*' }
    ) {
        $script:fixture.Blobs[0][$Key] = $Value
        { Clear-TerraformStateLock @script:parameters } | Should -Throw $Message
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'break' }
    }

    It 'requests an immediate conditional break for an already breaking lease' {
        $script:fixture.Blobs[0].leaseState = 'breaking'
        Clear-TerraformStateLock @script:parameters | Should -BeTrue
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
            $Arguments -contains 'break' -and $Arguments -contains '--lease-break-period' -and $Arguments -contains '0'
        }
    }

    It 'fails explicitly on inspection errors without exposing token values' {
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 8; StdOut = ''; StdErr = 'HTTP denied synthetic-app-token' }
        }
        $errorRecord = { Clear-TerraformStateLock @script:parameters } | Should -Throw '*inspection failed*HTTP denied ***' -PassThru
        $errorRecord.Exception.Message | Should -Not -Match 'synthetic-app-token'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'break' }
    }

    It 'keeps invalid inspection JSON private' {
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 0; StdOut = 'invalid JSON with private metadata'; StdErr = '' }
        }
        $errorRecord = { Clear-TerraformStateLock @script:parameters } | Should -Throw '*invalid JSON*' -PassThru
        $errorRecord.Exception.Message | Should -Not -Match 'with private metadata'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'break' }
    }

    It 'stops on an inspection timeout without releasing anything' {
        Mock Invoke-RepositorySyncProcess { throw [System.TimeoutException]::new('timed out') }
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*inspection timed out*no release*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'break' }
    }

    It 'does not repeat a failed conditional lease break or start Terraform' {
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 12; StdOut = ''; StdErr = 'ConditionNotMet synthetic-app-token' }
        } -ParameterFilter { $Arguments -contains 'break' }
        $errorRecord = { Clear-TerraformStateLock @script:parameters } |
            Should -Throw '*conditional state lease break failed*ConditionNotMet ***' -PassThru
        $errorRecord.Exception.Message | Should -Not -Match 'synthetic-app-token'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $Arguments -contains 'break' }
        $script:fixture.BlobReads | Should -Be 1
    }

    It 'does not repeat an uncertain lease-break timeout' {
        Mock Invoke-RepositorySyncProcess { throw [System.TimeoutException]::new('lease break timed out') } `
            -ParameterFilter { $Arguments -contains 'break' }
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*lease break timed out*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $Arguments -contains 'break' }
        $script:fixture.BlobReads | Should -Be 1
    }

    It 'requires observable release before permitting Terraform to start' {
        $script:fixture.Blobs[1] = $script:fixture.Blobs[0].Clone()
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*lease is still held*Terraform will not be started*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $Arguments -contains 'break' }
    }
}
