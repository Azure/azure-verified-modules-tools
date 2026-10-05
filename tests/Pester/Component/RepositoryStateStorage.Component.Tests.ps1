BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $lib = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $lib 'Logging.ps1')
    . (Join-Path $lib 'TestTenant.ps1')
    . (Join-Path $lib 'StateMigration.ps1')
    . (Join-Path $lib 'StateMigrationStorage.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'RepositoryState.ps1')
}

Describe 'Repository migration storage transport' -Tag Component {
    BeforeEach {
        $script:pair = New-AvmTestMigrationStatePair
        $script:backend = $script:pair.Backend
        $script:response = @{ ExitCode = 0; StdOut = '{"name":"synthetic"}'; StdErr = '' }
        $script:calls = [Collections.Generic.List[object]]::new()
        Mock Invoke-RepositorySyncProcess {
            param($Command, $Arguments, $EnvVars, $TimeoutSec)
            $script:calls.Add(@{ Command = $Command; Arguments = @($Arguments); EnvVars = $EnvVars; Timeout = $TimeoutSec })
            return $script:response
        }
    }

    It 'uses the verified tenant session without subscription discovery and removes storage credentials' {
        $previous = [Environment]::GetEnvironmentVariable('AZURE_STORAGE_SAS_TOKEN')
        try {
            $env:AZURE_STORAGE_SAS_TOKEN = 'synthetic-private-sas'
            $result = Invoke-RepositoryMigrationAzure -Backend $script:backend -Arguments @('storage', 'blob', 'list')
            $result.name | Should -Be 'synthetic'
            $script:calls[0].Command | Should -Be 'az'
            $script:calls[0].Arguments | Should -Not -Contain '--subscription'
            $script:calls[0].Arguments | Should -Contain '--only-show-errors'
            $script:calls[0].EnvVars.ContainsKey('AZURE_STORAGE_SAS_TOKEN') | Should -BeTrue
            $script:calls[0].EnvVars.AZURE_STORAGE_SAS_TOKEN | Should -BeNullOrEmpty
        }
        finally {
            [Environment]::SetEnvironmentVariable('AZURE_STORAGE_SAS_TOKEN', ($null -eq $previous ? [NullString]::Value : $previous), 'Process')
        }
    }

    It 'accepts only a specific blob-show not-found response as absence' {
        $script:response = @{ ExitCode = 3; StdOut = ''; StdErr = "The specified blob does not exist.`nErrorCode:BlobNotFound`n" }
        Invoke-RepositoryMigrationAzure -Backend $script:backend -Arguments @('storage', 'blob', 'show') -AllowBlobNotFound | Should -BeNullOrEmpty
        { Invoke-RepositoryMigrationAzure -Backend $script:backend -Arguments @('storage', 'blob', 'upload') -AllowBlobNotFound } |
            Should -Throw '*exit 3*'
    }

    It 'preserves a real storage failure without echoing private JSON or treating it as absence' {
        $script:response = @{ ExitCode = 7; StdOut = '{"private":"synthetic-secret"}'; StdErr = "ErrorCode:AuthorizationPermissionMismatch`nsynthetic-secret" }
        $failure = $null
        try { Invoke-RepositoryMigrationAzure -Backend $script:backend -Arguments @('storage', 'blob', 'show') -AllowBlobNotFound }
        catch { $failure = $_.Exception }
        $failure.Data['ExitCode'] | Should -Be 7
        $failure.Message | Should -Match 'AuthorizationPermissionMismatch'
        $failure.Message | Should -Not -Match 'synthetic-secret|private'
        $script:calls | Should -HaveCount 1
    }

    It 'rejects incomplete or malformed successful JSON: <Response>' -ForEach @(
        @{ Response = '' }, @{ Response = 'null' }, @{ Response = '{private:synthetic-secret}' }
    ) {
        $script:response.StdOut = $Response
        { Invoke-RepositoryMigrationAzure -Backend $script:backend -Arguments @('storage', 'blob', 'show') } | Should -Throw
    }
}

Describe 'Repository migration storage ownership and conditional writes' -Tag Component {
    BeforeEach {
        $script:pair = New-AvmTestMigrationStatePair
        $script:backend = $script:pair.Backend
        $script:account = @{
            id = $script:backend.SubscriptionId; tenantId = $script:backend.TenantId; environmentName = 'AzureCloud'
            user = @{ name = $script:backend.ClientId; type = 'servicePrincipal' }
        }
        $script:container = @{ name = $script:backend.ContainerName; properties = @{ publicAccess = $null } }
        $script:blob = @{
            name = 'avm-ptn-example-repo.tfstate'
            properties = @{ etag = '"synthetic-etag"'; contentLength = 128; lease = @{ status = 'unlocked' } }
        }
        Mock Invoke-RepositorySyncProcess { throw 'External process forbidden in component storage tests.' }
        Mock Invoke-RepositoryMigrationAzure {
            param($Arguments, $Backend, $AllowBlobNotFound)
            if ($Arguments[0] -ceq 'account') { return $script:account }
            if ($Arguments[1] -ceq 'container') { return $script:container }
            if ($Arguments[2] -ceq 'show') { return $script:blob }
            if ($Arguments[2] -ceq 'list') { return @($script:blob) }
            return @{ name = $script:blob.name }
        }
    }

    It 'requires exact existing state identity and a private configured container' {
        { Assert-RepositoryMigrationStorage -Backend $script:backend } | Should -Not -Throw
        Should -Invoke Invoke-RepositoryMigrationAzure -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains '--auth-mode' -and $Arguments -contains 'login' -and
            $Arguments -contains $script:backend.StorageAccountName -and $Arguments -contains $script:backend.ContainerName
        }
    }

    It 'accepts a tenant-level CLI account with only container-scoped data permissions' {
        $script:account.id = $script:backend.TenantId
        $script:account.name = 'N/A(tenant level account)'
        { Assert-RepositoryMigrationStorage -Backend $script:backend } | Should -Not -Throw
        Should -Invoke Invoke-RepositoryMigrationAzure -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains '--subscription' -or $Arguments -contains 'listKeys'
        }
    }

    It 'rejects mismatched or incomplete storage identity: <Field>' -ForEach @(
        @{ Field = 'tenant' }, @{ Field = 'subscription' }, @{ Field = 'client' }, @{ Field = 'cloud' }
        @{ Field = 'interactive user' }, @{ Field = 'public container' }, @{ Field = 'container alias' }, @{ Field = 'missing privacy evidence' }
    ) {
        switch ($Field) {
            'tenant' { $script:account.tenantId = [guid]::NewGuid().ToString() }
            'subscription' { $script:backend.SubscriptionId = 'invalid-subscription' }
            'client' { $script:account.user.name = [guid]::NewGuid().ToString() }
            'cloud' { $script:account.environmentName = 'AzureChinaCloud' }
            'interactive user' { $script:account.user.type = 'user' }
            'public container' { $script:container.properties.publicAccess = 'blob' }
            'container alias' { $script:container.name = 'other-container' }
            'missing privacy evidence' { $script:container.properties = @{} }
        }
        { Assert-RepositoryMigrationStorage -Backend $script:backend } | Should -Throw
    }

    It 'inventories every matching blob, not only the first page' {
        $prefix = 'bami-identities/10000000-0000-4000-8000-000000000001/'
        $null = Get-RepositoryMigrationBlobList -Backend $script:backend -Prefix $prefix
        Should -Invoke Invoke-RepositoryMigrationAzure -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains $prefix -and $Arguments -contains '--num-results' -and $Arguments -contains '*' -and
            $Arguments -contains 'login' -and $Arguments -contains $script:backend.ContainerName
        }
    }

    It 'downloads against the observed ETag and permits only local file overwrite' {
        Get-RepositoryMigrationBlob -Backend $script:backend -Name $script:blob.name -Path (Join-Path $TestDrive 'read.tfstate') | Should -BeTrue
        Should -Invoke Invoke-RepositoryMigrationAzure -Times 1 -Exactly -ParameterFilter {
            $Arguments[2] -ceq 'download' -and $Arguments -contains '--if-match' -and $Arguments -contains '"synthetic-etag"' -and
            $Arguments -contains '--overwrite' -and $Arguments -contains 'true' -and $Arguments -contains 'login'
        }
    }

    It 'rejects unsafe read metadata without downloading or breaking leases: <Field>' -ForEach @(
        @{ Field = 'lease' }, @{ Field = 'length' }, @{ Field = 'etag' }, @{ Field = 'name' }
    ) {
        switch ($Field) {
            'lease' { $script:blob.properties.lease.status = 'locked' }
            'length' { $script:blob.properties.contentLength = 0 }
            'etag' { $script:blob.properties.etag = '' }
            'name' { $script:blob.name = 'unexpected.tfstate' }
        }
        { Get-RepositoryMigrationBlob -Backend $script:backend -Name 'avm-ptn-example-repo.tfstate' -Path (Join-Path $TestDrive 'read.tfstate') } |
            Should -Throw '*no lock will be broken*'
        Should -Invoke Invoke-RepositoryMigrationAzure -Times 0 -Exactly -ParameterFilter { $Arguments[2] -ceq 'download' }
    }

    It 'never uploads a state blob through the storage adapter' {
        { Save-RepositoryMigrationBlob -Backend $script:backend -Name 'avm-ptn-example-repo.tfstate' -Path 'unused' -Confirm:$false } |
            Should -Throw '*never a state blob*'
        Should -Invoke Invoke-RepositoryMigrationAzure -Times 0 -Exactly
    }

    It 'uses create-only preconditions and verifies the uploaded backup hash' {
        $source = Join-Path $TestDrive 'backup.zip'
        [IO.File]::WriteAllText($source, 'synthetic-private-backup')
        $script:readCount = 0
        Mock Get-RepositoryMigrationBlob {
            param($Backend, $Name, $Path)
            $script:readCount++
            if ($script:readCount -eq 1) { return $false }
            [IO.File]::WriteAllText($Path, 'synthetic-private-backup')
            return $true
        }
        Save-RepositoryMigrationBlob -Backend $script:backend `
            -Name 'bami-consolidation/10000000-0000-4000-8000-000000000001/avm-ptn-example-repo/backup.zip' -Path $source -Confirm:$false
        Should -Invoke Invoke-RepositoryMigrationAzure -Times 1 -Exactly -ParameterFilter {
            $Arguments[2] -ceq 'upload' -and $Arguments -contains '--if-none-match' -and $Arguments -contains '*' -and
            $Arguments -contains '--overwrite' -and $Arguments -contains 'false' -and $Arguments -contains 'block'
        }
        $script:readCount | Should -Be 2
    }

    It 'refuses to overwrite a different checkpoint or accept a corrupted readback: <Existing>' -ForEach @(
        @{ Existing = $true }, @{ Existing = $false }
    ) {
        $source = Join-Path $TestDrive 'backup.zip'
        [IO.File]::WriteAllText($source, 'synthetic-private-backup')
        $script:readCount = 0
        $script:exists = $Existing
        Mock Get-RepositoryMigrationBlob {
            param($Backend, $Name, $Path)
            $script:readCount++
            if (-not $script:exists -and $script:readCount -eq 1) { return $false }
            [IO.File]::WriteAllText($Path, 'different-private-backup')
            return $true
        }
        { Save-RepositoryMigrationBlob -Backend $script:backend `
                -Name 'bami-consolidation/10000000-0000-4000-8000-000000000001/avm-ptn-example-repo/backup.zip' -Path $source -Confirm:$false } |
            Should -Throw
        $expectedWrites = $Existing ? 0 : 1
        Should -Invoke Invoke-RepositoryMigrationAzure -Times $expectedWrites -Exactly -ParameterFilter { $Arguments[2] -ceq 'upload' }
    }

    It 'verifies exact OIDC backend bindings against returned field <Field> without provider configuration' -ForEach @(
        @{ Field = '' }, @{ Field = 'key' }, @{ Field = 'tenant_id' }, @{ Field = 'client_id' }
        @{ Field = 'container_name' }, @{ Field = 'subscription_id' }, @{ Field = 'use_cli' }
    ) {
        $directory = Join-Path $TestDrive 'backend'
        $script:capturedInit = @()
        $script:wrongBackendField = $Field
        Mock Invoke-RepositoryMigrationTerraform {
            param($Terraform, $Root, $Arguments)
            $script:capturedInit = @($Arguments)
            $configuration = @{}
            foreach ($arg in $Arguments | Where-Object { $_.StartsWith('-backend-config=') }) {
                $parts = $arg.Substring(16).Split('=', 2)
                $configuration[$parts[0]] = $parts[1] -cin @('true', 'false') ? [bool]::Parse($parts[1]) : $parts[1]
            }
            if ($script:wrongBackendField) { $configuration[$script:wrongBackendField] = 'incorrect' }
            $null = [IO.Directory]::CreateDirectory((Join-Path $Root '.terraform'))
            [IO.File]::WriteAllText((Join-Path $Root '.terraform' 'terraform.tfstate'),
                (ConvertTo-Json @{ backend = @{ type = 'azurerm'; config = $configuration } } -Depth 10))
        }
        if ($Field) {
            { Initialize-RepositoryMigrationBackend -Backend $script:backend -Key 'avm-ptn-example-repo.tfstate' -Root $directory -Terraform 'synthetic' } |
                Should -Throw '*does not match the exact migration scope*'
            return
        }
        Initialize-RepositoryMigrationBackend -Backend $script:backend -Key 'avm-ptn-example-repo.tfstate' -Root $directory -Terraform 'synthetic'
        $script:capturedInit | Should -Contain '-backend-config=use_azuread_auth=true'
        $script:capturedInit | Should -Contain '-backend-config=use_oidc=true'
        $script:capturedInit | Should -Contain '-backend-config=use_cli=false'
        $script:capturedInit | Should -Contain '-backend-config=use_msi=false'
        $script:capturedInit | Should -Contain '-backend-config=environment=public'
        $script:capturedInit | Should -Contain '-reconfigure'
        $script:capturedInit | Should -Contain '-upgrade'
        $definition = Get-Content -LiteralPath (Join-Path $directory 'main.tf') -Raw
        $definition | Should -Match 'required_providers'
        $definition | Should -Not -Match '(?m)^provider "|var\.|client_secret'
    }

    It 'does not expose malformed private backend metadata' {
        Mock Invoke-RepositoryMigrationTerraform {
            param($Terraform, $Root, $Arguments)
            $null = [IO.Directory]::CreateDirectory((Join-Path $Root '.terraform'))
            [IO.File]::WriteAllText((Join-Path $Root '.terraform' 'terraform.tfstate'), '{"private":"synthetic-secret"')
        }
        $failure = $null
        try {
            Initialize-RepositoryMigrationBackend -Backend $script:backend -Key 'avm-ptn-example-repo.tfstate' `
                -Root (Join-Path $TestDrive 'backend') -Terraform 'synthetic'
        }
        catch { $failure = $_.Exception }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Message | Should -Match 'Invalid private migration record'
        $failure.Message | Should -Not -Match 'synthetic-secret'
    }
}

Describe 'Repository migration native diagnostics' -Tag Component {
    BeforeEach {
        $script:previous = @{}
        foreach ($name in @('GITHUB_ACTIONS', 'GH_TOKEN')) {
            $script:previous[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:GH_TOKEN = 'synthetic-token-do-not-print'
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 0; StdOut = 'Move module.azure to module.bami[0]'; StdErr = 'native diagnostic' }
        }
    }

    AfterEach {
        foreach ($name in $script:previous.Keys) {
            $value = $script:previous[$name]
            [Environment]::SetEnvironmentVariable($name, ($null -eq $value ? [NullString]::Value : $value), 'Process')
        }
    }

    It 'folds native migration detail without contaminating the returned checkpoint' {
        $records = @()
        $result = Invoke-RepositorySyncLogGroup -Name 'State migration' -Action {
            Invoke-RepositoryMigrationTerraform -Terraform 'synthetic' -Root $TestDrive -Arguments @('state', 'mv')
            'Complete'
        } -InformationVariable records
        @($result) | Should -Be @('Complete')
        @($records)[0].MessageData | Should -Be '::group::State migration'
        @($records)[-1].MessageData | Should -Be '::endgroup::'
        ($records | Out-String) | Should -Match 'Move module.azure'
        ($records | Out-String) | Should -Match 'native diagnostic'
    }

    It 'closes a failed group and exposes the original redacted error without retrying' {
        Mock Invoke-RepositorySyncProcess {
            @{ ExitCode = 17; StdOut = "checkpoint detail $env:GH_TOKEN"; StdErr = 'state lease unavailable' }
        }
        $records = @()
        $failure = $null
        try {
            Invoke-RepositorySyncLogGroup -Name 'State migration' -Action {
                Invoke-RepositoryMigrationTerraform -Terraform 'synthetic' -Root $TestDrive -Arguments @('state', 'push')
            } -InformationVariable records
        }
        catch { $failure = $_.Exception }
        @($records)[-1].MessageData | Should -Be '::endgroup::'
        $failure.Data['ExitCode'] | Should -Be 17
        $failure.Message | Should -Match 'state lease unavailable'
        $failure.Message | Should -Match 'checkpoint detail \*\*\*'
        $failure.Message | Should -Not -Match 'synthetic-token-do-not-print'
        Should -Invoke Invoke-RepositorySyncProcess -Times 1 -Exactly
    }

    It 'closes a timeout group with useful redacted human diagnostics' {
        Mock Invoke-RepositorySyncProcess {
            $failure = [TimeoutException]::new('synthetic timeout')
            $failure.Data['StdOut'] = "partial human output $env:GH_TOKEN"
            throw $failure
        }
        $records = @()
        $failure = $null
        try {
            Invoke-RepositorySyncLogGroup -Name 'State migration' -Action {
                Invoke-RepositoryMigrationTerraform -Terraform 'synthetic' -Root $TestDrive -Arguments @('state', 'push')
            } -InformationVariable records
        }
        catch { $failure = $_.Exception }
        @($records)[-1].MessageData | Should -Be '::endgroup::'
        $failure | Should -BeOfType ([TimeoutException])
        $failure.Message | Should -Match 'partial human output \*\*\*'
        $failure.Message | Should -Not -Match 'synthetic-token-do-not-print'
        Should -Invoke Invoke-RepositorySyncProcess -Times 1 -Exactly
    }

    It 'does not expose private JSON on <Mode>' -ForEach @(
        @{ Mode = 'success' }, @{ Mode = 'failure' }, @{ Mode = 'timeout' }
    ) {
        $script:mode = $Mode
        Mock Invoke-RepositorySyncProcess {
            if ($script:mode -ceq 'timeout') {
                $failure = [TimeoutException]::new('synthetic timeout')
                $failure.Data['StdOut'] = '{"private":"synthetic-secret"}'
                throw $failure
            }
            @{ ExitCode = ($script:mode -ceq 'failure' ? 7 : 0); StdOut = '{"private":"synthetic-secret"}'; StdErr = 'synthetic-secret' }
        }
        $records = @()
        $failure = $null
        $result = $null
        try {
            $result = Invoke-RepositoryMigrationTerraform -Terraform 'synthetic' -Root $TestDrive `
                -Arguments @('show', '-json') -PrivateOutput -InformationVariable records
        }
        catch { $failure = $_.Exception }
        ($records | Out-String) | Should -Not -Match 'synthetic-secret'
        if ($Mode -ceq 'success') { $result | Should -Be '{"private":"synthetic-secret"}' }
        else {
            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Not -Match 'synthetic-secret'
            $failure.Data.Contains('StdOut') | Should -BeFalse
        }
    }
}
