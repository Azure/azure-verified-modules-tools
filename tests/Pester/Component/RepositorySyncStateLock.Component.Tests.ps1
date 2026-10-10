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

    function ConvertTo-TestLockMetadata {
        param([hashtable] $Info)
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Info -Compress)))
    }
}

Describe 'Repository state-lock recovery' -Tag Component {
    BeforeEach {
        $script:previousEnvironment = @{}
        $values = [ordered]@{
            GITHUB_ACTIONS = 'true'
            GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
            GITHUB_REF = 'refs/heads/main'
            GITHUB_WORKFLOW_REF = 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-sync.yml@refs/heads/main'
            GITHUB_RUN_ID = '900'
            GITHUB_RUN_ATTEMPT = '1'
            RUNNER_NAME = 'current-worker'
            ACTIONS_STATE_LOCK_TOKEN = 'synthetic-actions-read-token'
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
            errorOutput = @(
                'Error: Error acquiring the state lock'
                'Error message: state blob is already locked'
                'Lock Info:'
                '  ID: 11111111-1111-4111-8111-111111111111'
                '  Path: tfstate/avm-ptn-example-repo.tfstate'
            )
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
        $script:lockInfo = @{
            ID = '11111111-1111-4111-8111-111111111111'
            Path = 'tfstate/avm-ptn-example-repo.tfstate'
            Who = 'runner@unverified-owner'
            Created = '2026-10-08T16:39:14Z'
            Operation = 'OperationTypePlan'
        }
        $held = @{
            etag = '"0xAABBCC"'
            leaseState = 'leased'
            leaseStatus = 'locked'
            lockInfo = ConvertTo-TestLockMetadata -Info $script:lockInfo
        }
        $script:fixture = @{
            Calls = [System.Collections.Generic.List[object]]::new()
            BlobReads = 0
            Blobs = @(
                $held.Clone()
                $held.Clone()
                @{ etag = '"0xAABBCE"'; leaseState = 'available'; leaseStatus = 'unlocked'; lockInfo = $null }
            )
            Account = @{
                id = $script:parameters.subscriptionId
                tenantId = $script:parameters.tenantId
                user = @{ type = 'servicePrincipal'; name = $script:parameters.clientId }
            }
            Run = @{
                id = 900; run_attempt = 1; workflow_id = 50; status = 'in_progress'; head_branch = 'main'
                path = '.github/workflows/repository-management-sync.yml'
                head_repository = @{ full_name = 'Azure/azure-verified-modules-tools' }
            }
            Active = @{ total_count = 1; workflow_runs = @(@{ id = 900; status = 'in_progress' }) }
            JobPages = @(@{
                total_count = 2
                jobs = @(
                    @{ id = 1; name = 'Generate matrix'; status = 'completed'; runner_name = 'matrix-worker' }
                    @{ id = 2; name = 'Sync terraform-azurerm-avm-ptn-example-repo'; status = 'in_progress'; runner_name = 'current-worker' }
                )
            })
        }
        $fixture = $script:fixture
        Mock Invoke-RepositorySyncProcess ({
            param($Command, $Arguments, $WorkingDirectory, $EnvVars, $TimeoutSec)
            $fixture.Calls.Add(@{
                Command = $Command; Arguments = @($Arguments); Root = $WorkingDirectory
                Environment = $EnvVars; Timeout = $TimeoutSec
            })
            $data = $null
            if ($Command -ceq 'gh') {
                if ($EnvVars.GH_TOKEN -cne 'synthetic-actions-read-token') { throw 'Wrong token for Actions inspection.' }
                $endpoint = $Arguments[-1]
                if ($endpoint -ceq 'repos/Azure/azure-verified-modules-tools/actions/runs/900') {
                    $data = $fixture.Run
                }
                elseif ($endpoint -ceq 'repos/Azure/azure-verified-modules-tools/actions/workflows/50/runs?status=in_progress&per_page=100') {
                    $data = $fixture.Active
                }
                elseif ($endpoint -cmatch '^repos/Azure/azure-verified-modules-tools/actions/runs/900/attempts/1/jobs\?per_page=100&page=([0-9]+)$') {
                    $data = $fixture.JobPages[[int]$Matches[1] - 1]
                }
                else { throw "Unexpected isolated GitHub endpoint: $endpoint" }
            }
            elseif ($Command -ceq 'az' -and $Arguments[0] -ceq 'account') {
                $data = $fixture.Account
            }
            elseif ($Command -ceq 'az' -and $Arguments[2] -ceq 'show') {
                $data = $fixture.Blobs[$fixture.BlobReads++]
            }
            elseif (($Command -ceq 'az' -and $Arguments[2] -ceq 'lease') -or
                ($Command -ceq 'terraform' -and $Arguments[0] -ceq 'force-unlock')) {
                return @{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            else { throw 'Unexpected isolated state-lock command.' }
            return @{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject $data -Depth 15 -Compress); StdErr = '' }
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
    }

    It 'rechecks only the matching initialized backend for the <Layout> worker, without claiming abandonment' -ForEach @(
        @{ Layout = 'original'; Worker = 'Sync terraform-azurerm-avm-ptn-example-repo' }
        @{ Layout = 'reusable'; Worker = 'Sync terraform-azurerm-avm-ptn-example-repo / Prepare terraform-azurerm-avm-ptn-example-repo' }
    ) {
        $script:fixture.JobPages[0].jobs[1].name = $Worker
        Clear-TerraformStateLock @script:parameters | Should -BeTrue
        Should -Invoke Write-Warning -Exactly 1 -ParameterFilter {
            $Message -match 'unverified lock' -and $Message -notmatch 'stale|abandoned'
        }
        $script:fixture.BlobReads | Should -Be 3
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
            $Command -ceq 'terraform' -and
            ($Arguments -join ' ') -ceq 'force-unlock -force 11111111-1111-4111-8111-111111111111' -and
            $WorkingDirectory -ceq $TestDrive -and $EnvVars.TF_WORKSPACE -ceq 'default' -and
            $EnvVars.ARM_CLIENT_ID -ceq '10000000-0000-4000-8000-000000000002' -and $TimeoutSec -eq 60
        }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter {
            $Command -ceq 'az' -and $Arguments -contains 'break'
        }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 2 -ParameterFilter {
            $Command -ceq 'gh' -and $Arguments[-1] -ceq 'repos/Azure/azure-verified-modules-tools/actions/runs/900'
        }
        foreach ($call in $script:fixture.Calls) {
            $call.Timeout | Should -Be 60
            ($call.Arguments -join ' ') | Should -Not -Match 'synthetic-.*token|state (pull|push|rm|mv)|download|--account-key'
        }
    }

    It 'uses an ETag-conditional lease break for missing metadata, never a fabricated ID: <Metadata>' -ForEach @(
        @{ Metadata = $null }
        @{ Metadata = '' }
    ) {
        $script:parameters.errorOutput = @('Error: Error acquiring the state lock', 'Error message: terraformlockid metadata was empty')
        $script:fixture.Blobs[0].lockInfo = $Metadata
        $script:fixture.Blobs[1].lockInfo = $Metadata
        $script:fixture.Blobs[2].leaseState = 'broken'
        Clear-TerraformStateLock @script:parameters | Should -BeTrue
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter {
            $Command -ceq 'az' -and ($Arguments -join ' ') -ceq (
                'storage blob lease break --account-name stateaccount --container-name tfstate ' +
                '--blob-name avm-ptn-example-repo.tfstate --lease-break-period 0 --if-match "0xAABBCC" ' +
                '--auth-mode login --subscription 55555555-5555-4555-8555-555555555555 --only-show-errors --output none'
            )
        }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Command -ceq 'terraform' }
    }

    It 'permits one new acquisition without unlocking when the lease has already gone' {
        $script:fixture.Blobs[0] = $script:fixture.Blobs[2]
        Clear-TerraformStateLock @script:parameters | Should -BeTrue
        $script:fixture.BlobReads | Should -Be 1
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter {
            $Command -ceq 'terraform' -or $Arguments -contains 'break'
        }
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

    It 'rejects an untrusted or incomplete Actions context: <Name>' -ForEach @(
        @{ Name = 'GITHUB_ACTIONS'; Value = '' }
        @{ Name = 'GITHUB_REPOSITORY'; Value = 'fork/azure-verified-modules-tools' }
        @{ Name = 'GITHUB_REF'; Value = 'refs/pull/246/merge' }
        @{ Name = 'GITHUB_REF'; Value = 'refs/heads/telemetry-rehearsal' }
        @{ Name = 'GITHUB_WORKFLOW_REF'; Value = 'Azure/azure-verified-modules-tools/.github/workflows/other.yml@refs/heads/main' }
        @{ Name = 'GITHUB_RUN_ID'; Value = '' }
        @{ Name = 'GITHUB_RUN_ATTEMPT'; Value = '0' }
        @{ Name = 'RUNNER_NAME'; Value = '' }
        @{ Name = 'ACTIONS_STATE_LOCK_TOKEN'; Value = '' }
    ) {
        [Environment]::SetEnvironmentVariable($Name, $Value)
        $expectedMessage = $Name -ceq 'ACTIONS_STATE_LOCK_TOKEN' ?
            '*Automatic lock recovery requires the repository-scoped Actions read token*' :
            '*Automatic lock recovery requires the trusted Terraform Sync workflow on Tools main*'
        { Clear-TerraformStateLock @script:parameters } | Should -Throw $expectedMessage
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0
    }

    It 'rejects a <TokenState> Actions read token before any external operation' -ForEach @(
        @{ TokenState = 'missing'; TokenValue = $null }
        @{ TokenState = 'whitespace-only'; TokenValue = " `t " }
    ) {
        [Environment]::SetEnvironmentVariable('ACTIONS_STATE_LOCK_TOKEN', ($null -eq $TokenValue ? [NullString]::Value : $TokenValue))
        { Clear-TerraformStateLock @script:parameters } |
            Should -Throw '*Automatic lock recovery requires the repository-scoped Actions read token*'
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

    It 'does not recover a local backend or unreadable metadata' -ForEach @(
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
        @{ Key = 'errorOutput'; Value = @('Error: Error releasing the state lock'); Message = '*acquisition failure*' }
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

    It 'refuses a positively identified competing run' {
        $script:fixture.Active.total_count = 2
        $script:fixture.Active.workflow_runs += @{ id = 901; status = 'in_progress' }
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*Another active sync run*'
        $script:fixture.BlobReads | Should -Be 0
    }

    It 'refuses another active <Layout> worker for the same state across provider prefixes' -ForEach @(
        @{ Layout = 'original'; Worker = 'Sync terraform-azapi-avm-ptn-example-repo' }
        @{ Layout = 'reusable'; Worker = 'Sync terraform-azapi-avm-ptn-example-repo / Prepare terraform-azapi-avm-ptn-example-repo' }
        @{ Layout = 'same-repository reusable'; Worker = 'Sync terraform-azurerm-avm-ptn-example-repo / Prepare terraform-azurerm-avm-ptn-example-repo' }
    ) {
        $script:fixture.JobPages[0].total_count++
        $script:fixture.JobPages[0].jobs += @{
            id = 3; name = $Worker; status = 'in_progress'; runner_name = 'other-worker'
        }
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*active competing state writer*'
        $script:fixture.BlobReads | Should -Be 0
    }

    It 'refuses an observed lock owner that identifies an active worker even under a different job name' {
        $script:lockInfo.Who = 'runner@known-active-worker'
        $script:fixture.Blobs[0].lockInfo = ConvertTo-TestLockMetadata -Info $script:lockInfo
        $script:fixture.JobPages[0].total_count++
        $script:fixture.JobPages[0].jobs += @{
            id = 3; name = 'Sync terraform-azurerm-avm-ptn-other'; status = 'in_progress'; runner_name = 'known-active-worker'
        }
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*lock owner matches an active Actions worker*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter {
            $Command -ceq 'terraform' -or $Arguments -contains 'break'
        }
    }

    It 'allows active workers for other state keys and inspects every jobs page' {
        $currentJob = $script:fixture.JobPages[0].jobs[1]
        $jobs = @(1..100 | ForEach-Object {
            @{ id = $_ + 10; name = "Sync terraform-azurerm-avm-ptn-other-$_"; status = 'in_progress'; runner_name = "worker-$_" }
        })
        $script:fixture.JobPages = @(
            @{ total_count = 101; jobs = $jobs }
            @{ total_count = 101; jobs = @($currentJob) }
        )
        Clear-TerraformStateLock @script:parameters | Should -BeTrue
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 2 -ParameterFilter {
            $Command -ceq 'gh' -and $Arguments[-1] -clike '*/jobs?per_page=100&page=2'
        }
    }

    It 'fails closed for incomplete, changed, or unverified GitHub evidence: <Case>' -ForEach @(
        @{ Case = 'old attempt'; Change = { param($f) $f.Run.run_attempt = 2 }; Message = '*current trusted sync run*' }
        @{ Case = 'completed run'; Change = { param($f) $f.Run.status = 'completed' }; Message = '*current trusted sync run*' }
        @{ Case = 'other workflow'; Change = { param($f) $f.Run.path = 'other.yml' }; Message = '*current trusted sync run*' }
        @{ Case = 'other repository'; Change = { param($f) $f.Run.head_repository.full_name = 'fork/tools' }; Message = '*current trusted sync run*' }
        @{ Case = 'wrong runner'; Change = { param($f) $f.JobPages[0].jobs[1].runner_name = 'someone-else' }; Message = '*unverified current worker*' }
        @{ Case = 'missing current job'; Change = { param($f) $f.JobPages[0].jobs[1].status = 'queued' }; Message = '*unverified current worker*' }
        @{ Case = 'validation job'; Change = { param($f) $f.JobPages[0].jobs[1].name = 'Sync terraform-azurerm-avm-ptn-example-repo / Validate terraform-azurerm-avm-ptn-example-repo' }; Message = '*unverified current worker*' }
        @{ Case = 'mismatched child repository'; Change = { param($f) $f.JobPages[0].jobs[1].name = 'Sync terraform-azurerm-avm-ptn-example-repo / Prepare terraform-azapi-avm-ptn-example-repo' }; Message = '*unverified current worker*' }
        @{ Case = 'partial child name'; Change = { param($f) $f.JobPages[0].jobs[1].name = 'Sync terraform-azurerm-avm-ptn-example-repo / Prepare' }; Message = '*unverified current worker*' }
        @{ Case = 'duplicate jobs'; Change = { param($f) $f.JobPages[0].jobs[1].id = 1 }; Message = '*job inventory is ambiguous*' }
        @{ Case = 'empty jobs'; Change = { param($f) $f.JobPages[0].jobs = @() }; Message = '*job inventory is incomplete*' }
        @{ Case = 'overfull page'; Change = { param($f) $f.JobPages[0].total_count = 1 }; Message = '*unverified current worker*' }
    ) {
        & $Change $script:fixture
        { Clear-TerraformStateLock @script:parameters } | Should -Throw $Message
        $script:fixture.BlobReads | Should -Be 0
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

    It 'refuses a changed lock or lease on the immediate recheck: <Key>' -ForEach @(
        @{ Key = 'etag'; Value = '"0xAABBCD"' }
        @{ Key = 'leaseState'; Value = 'breaking' }
        @{ Key = 'leaseStatus'; Value = 'unlocked' }
        @{ Key = 'lockInfo'; Value = '' }
    ) {
        $script:fixture.Blobs[1][$Key] = $Value
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*changed before release*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter {
            $Command -ceq 'terraform' -or $Arguments -contains 'break'
        }
    }

    It 'does not treat malformed nonempty lock metadata as a missing ID' -ForEach @(
        @{ Metadata = 'not base64' }
        @{ Metadata = 'bm90IGpzb24=' }
    ) {
        $script:fixture.Blobs[0].lockInfo = $Metadata
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*lock metadata is malformed*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter {
            $Command -ceq 'terraform' -or $Arguments -contains 'break'
        }
    }

    It 'refuses a malformed ID or foreign lock path: <Key>' -ForEach @(
        @{ Key = 'ID'; Value = 'not-an-id' }
        @{ Key = 'ID'; Value = '00000000-0000-0000-0000-000000000000' }
        @{ Key = 'Path'; Value = 'tfstate/avm-ptn-other.tfstate' }
    ) {
        $script:lockInfo[$Key] = $Value
        $script:fixture.Blobs[0].lockInfo = ConvertTo-TestLockMetadata -Info $script:lockInfo
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*exact selected state blob*'
    }

    It 'refuses replacement of the error-observed lock before inspection' {
        $script:parameters.errorOutput[3] = 'ID: 22222222-2222-4222-8222-222222222222'
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*reported lock ID no longer matches*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Command -ceq 'terraform' }
    }

    It 'refuses an error-reported foreign state path even with a matching lock ID' {
        $script:parameters.errorOutput[4] = 'Path: tfstate/avm-ptn-other.tfstate'
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*reported lock path does not match*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Command -ceq 'terraform' }
    }

    It 'does not release a transitioning lease or metadata without an ETag' -ForEach @(
        @{ Key = 'leaseState'; Value = 'breaking'; Message = '*lease is transitioning*' }
        @{ Key = 'etag'; Value = $null; Message = '*incomplete lease metadata*' }
        @{ Key = 'etag'; Value = '*'; Message = '*incomplete lease metadata*' }
    ) {
        $script:fixture.Blobs[0][$Key] = $Value
        { Clear-TerraformStateLock @script:parameters } | Should -Throw $Message
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter {
            $Command -ceq 'terraform' -or $Arguments -contains 'break'
        }
    }

    It 'fails explicitly on inspection errors without exposing token values' {
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 8; StdOut = ''; StdErr = 'HTTP denied synthetic-actions-read-token' }
        } -ParameterFilter { $Command -ceq 'gh' }
        $errorRecord = { Clear-TerraformStateLock @script:parameters } | Should -Throw '*inspection failed*HTTP denied ***' -PassThru
        $errorRecord.Exception.Message | Should -Not -Match 'synthetic-actions-read-token'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Command -ceq 'az' -or $Command -ceq 'terraform' }
    }

    It 'keeps invalid inspection JSON private' {
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 0; StdOut = 'invalid JSON with private metadata'; StdErr = '' }
        } -ParameterFilter { $Command -ceq 'gh' }
        $errorRecord = { Clear-TerraformStateLock @script:parameters } | Should -Throw '*invalid JSON*' -PassThru
        $errorRecord.Exception.Message | Should -Not -Match 'with private metadata'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Command -ceq 'az' -or $Command -ceq 'terraform' }
    }

    It 'stops on an inspection timeout without releasing anything' {
        Mock Invoke-RepositorySyncProcess { throw [System.TimeoutException]::new('timed out') } -ParameterFilter { $Command -ceq 'gh' }
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*inspection timed out*no release*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Command -ceq 'az' -or $Command -ceq 'terraform' }
    }

    It 'does not escalate a failed force-unlock into a lease break' {
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 9; StdOut = ''; StdErr = 'lock changed synthetic-app-token' }
        } -ParameterFilter { $Command -ceq 'terraform' }
        $errorRecord = { Clear-TerraformStateLock @script:parameters } | Should -Throw '*force-unlock failed*no lease-break fallback*' -PassThru
        $errorRecord.Exception.Message | Should -Not -Match 'synthetic-app-token'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $Command -ceq 'terraform' }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'break' }
    }

    It 'does not retry or break a lease after an uncertain force-unlock timeout' {
        Mock Invoke-RepositorySyncProcess { throw [System.TimeoutException]::new('force-unlock timed out') } `
            -ParameterFilter { $Command -ceq 'terraform' }
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*force-unlock timed out*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $Command -ceq 'terraform' }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'break' }
    }

    It 'reports a failed conditional missing-metadata lease break without retry or invented IDs' {
        $script:parameters.errorOutput = @('Error: Error acquiring the state lock')
        $script:fixture.Blobs[0].lockInfo = ''
        $script:fixture.Blobs[1].lockInfo = ''
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 12; StdOut = ''; StdErr = 'ConditionNotMet' }
        } -ParameterFilter { $Command -ceq 'az' -and $Arguments -contains 'break' }
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*conditional state lease break failed*ConditionNotMet*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $Arguments -contains 'break' }
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 0 -ParameterFilter { $Command -ceq 'terraform' }
    }

    It 'requires observable release before permitting another acquisition' {
        $script:fixture.Blobs[2] = $script:fixture.Blobs[0].Clone()
        { Clear-TerraformStateLock @script:parameters } | Should -Throw '*lease is still held*Terraform will not be retried*'
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1 -ParameterFilter { $Command -ceq 'terraform' }
    }
}
