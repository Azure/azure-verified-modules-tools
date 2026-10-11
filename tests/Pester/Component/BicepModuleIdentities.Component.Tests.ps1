BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
    . (Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'ModuleConfig.ps1')
    . (Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'ModuleIdentitySync.ps1')
    . (Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'GitHubVariables.ps1')
    . (Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'lib' 'TestTenantSync.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'TestTenant.ps1')
    . (Join-Path $script:root 'tests' 'fixtures' 'BicepIdentities.ps1')
    $script:originalEnvironment = @{}
    $script:values = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
    $script:backendValues = @{
        ARM_BACKEND_TENANT_ID = '20000000-0000-4000-8000-000000000001'
        ARM_BACKEND_SUBSCRIPTION_ID = '20000000-0000-4000-8000-000000000002'
        ARM_BACKEND_CLIENT_ID = '20000000-0000-4000-8000-000000000003'
        ARM_BACKEND_STORAGE_ACCOUNT_NAME = 'fixturestatestore'
        ARM_BACKEND_STORAGE_CONTAINER_NAME = 'tfstate'
    }
    foreach ($name in @($script:values.Keys) + @($script:backendValues.Keys) + @(
        'GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID', 'GITHUB_REF',
        'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_SHA', 'GITHUB_WORKFLOW_REF',
        'GH_TOKEN', 'AVM_OFFLINE', 'TF_CLI_ARGS', 'ARM_CLIENT_SECRET'
    )) {
        $script:originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

Describe 'Bicep module identity entry points with real files and mocked services' -Tag Component {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:toolsRoot = Join-Path $caseRoot 'tools'
        $script:sourceRoot = Join-Path $caseRoot 'bicep-source'
        $script:mappingPath = Join-Path $caseRoot 'client-ids.json'
        $script:migrationPath = Join-Path $caseRoot 'identity-renames.json'
        $script:terraformRoot = Join-Path $script:toolsRoot 'repository-management' 'bicep-test-tenant-sync' 'terraform'
        $script:entryPath = Join-Path $script:toolsRoot 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'Invoke-BicepModuleIdentitySync.ps1'
        $script:publisherPath = Join-Path $script:toolsRoot 'repository-management' 'bicep-test-tenant-sync' 'scripts' 'Invoke-BicepTestTenantSync.ps1'
        foreach ($path in @(
            'repository-management\bicep-test-tenant-sync\scripts',
            'repository-management\bicep-config',
            'repository-management\shared',
            'repository-management\repository-sync\scripts\lib',
            'src\Avm.Authoring\Private\Output'
        )) {
            $relative = $path.Replace('\', [IO.Path]::DirectorySeparatorChar)
            $destination = Join-Path $script:toolsRoot $relative
            $null = New-Item -ItemType Directory -Path (Split-Path $destination) -Force
            Copy-Item -LiteralPath (Join-Path $script:root $relative) -Destination $destination -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Path $script:terraformRoot -Force
        foreach ($name in @('main.tf', 'locals.tf', 'outputs.tf', 'variables.tf', 'terraform.tf')) {
            Copy-Item -LiteralPath (Join-Path $script:root 'repository-management' 'bicep-test-tenant-sync' 'terraform' $name) -Destination $script:terraformRoot
        }
        foreach ($kind in @('res', 'ptn', 'utl')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $script:sourceRoot 'avm' $kind) -Force
        }
        foreach ($path in (New-AvmTestBicepIdentityModules).Keys) {
            $directory = Join-Path $script:sourceRoot ($path.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $null = New-Item -ItemType Directory -Path $directory -Force
            [IO.File]::WriteAllText((Join-Path $directory 'main.bicep'), "targetScope = 'resourceGroup'`n")
        }
        foreach ($name in $script:values.Keys) { [Environment]::SetEnvironmentVariable($name, $script:values[$name]) }
        foreach ($name in $script:backendValues.Keys) { [Environment]::SetEnvironmentVariable($name, $script:backendValues[$name]) }
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
        $env:GITHUB_REPOSITORY_ID = '1239632211'
        $env:GITHUB_REF = 'refs/heads/main'
        $env:GITHUB_RUN_ID = '123456789'
        $env:GITHUB_RUN_ATTEMPT = '1'
        $env:GITHUB_SHA = '0123456789012345678901234567890123456789'
        $env:GITHUB_WORKFLOW_REF = 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-bicep-sync.yml@refs/heads/main'
        $env:GH_TOKEN = 'fixture-token'
        $env:AVM_OFFLINE = '0'
        $env:TF_CLI_ARGS = '-destroy'
        $env:ARM_CLIENT_SECRET = 'unused-secret-sentinel'
        $script:state = @{
            Plan = New-AvmTestBicepIdentityPlan
            Outputs = New-AvmTestBicepIdentityOutputs
            Calls = [System.Collections.Generic.List[object]]::new()
            Writes = [System.Collections.Generic.List[string]]::new()
            Variables = [ordered]@{}
            RequestPaths = [System.Collections.Generic.List[string]]::new()
            FailOperation = ''
            BadRepository = $false
            PlanPath = ''
            Parameters = $null
        }
        $sources = [ordered]@{
            VALIDATE_TENANT_ID = 'TEST_BAMI_TENANT_ID'
            VALIDATE_CLIENT_ID = 'TEST_BAMI_BICEP_CLIENT_ID'
            VALIDATE_SUBSCRIPTION_IDS = 'TEST_BAMI_SUBSCRIPTION_IDS'
            VALIDATE_MANAGEMENT_GROUP_ID = 'TEST_BAMI_MANAGEMENT_GROUP_ID'
            VALIDATE_PERSISTENT_SUBSCRIPTION_ID = 'TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID'
        }
        foreach ($name in $sources.Keys) {
            $script:state.Variables[$name] = @{
                name = $name; value = $script:values[$sources[$name]]
                created_at = '2026-10-01T00:00:00Z'; updated_at = '2026-10-01T00:00:00Z'
            }
        }
        $script:beforeVariables = ConvertTo-Json -InputObject $script:state.Variables -Depth 5 -Compress
        $state = $script:state
        $testDirectory = $TestDrive
        Mock Import-Module {}
        Mock Get-Command ({
            param($Name)
            if ($Name -cnotin @('gh', 'terraform')) { throw 'Unexpected executable lookup.' }
            [pscustomobject]@{ Source = Join-Path $testDirectory "$Name.blocked" }
        }.GetNewClosure()) -ParameterFilter { $CommandType -eq 'Application' }
        Mock New-TemporaryFile ({
            $path = Join-Path $testDirectory ([guid]::NewGuid().ToString('N') + '.request.json')
            New-Item -ItemType File -Path $path
        }.GetNewClosure())
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith ({
            param($FilePath, $ArgumentList, $EnvVars, $WorkingDirectory, $StreamOutput, $OnStdOutLine, $OnStdErrLine)
            $command = [IO.Path]::GetFileNameWithoutExtension($FilePath)
            $state.Calls.Add(@{ Command = $command; Arguments = $ArgumentList; Environment = $EnvVars; Directory = $WorkingDirectory })
            if ($command -ceq 'gh') {
                $ArgumentList[0] | Should -BeExactly 'api'
                $ArgumentList[4] | Should -BeIn @('GET', 'POST', 'PATCH')
                if ($ArgumentList[-1] -ceq 'repos/Azure/azure-verified-modules-tools') {
                    $body = @{ full_name = 'Azure/azure-verified-modules-tools'; fork = $false; id = 1239632211; owner = @{ login = 'Azure'; id = 6844498 } }
                }
                elseif ($ArgumentList[-1] -ceq 'repos/Azure/bicep-registry-modules') {
                    $body = @{ full_name = 'Azure/bicep-registry-modules'; fork = $state.BadRepository; id = 447791597; owner = @{ login = 'Azure'; id = 6844498 } }
                }
                elseif ($ArgumentList[4] -ceq 'GET') {
                    $ArgumentList[11] | Should -BeLike 'repos/Azure/bicep-registry-modules/actions/variables?*'
                    $body = @{ total_count = $state.Variables.Count; variables = @($state.Variables.Values) }
                }
                else {
                    $ArgumentList[-2] | Should -BeExactly '--input'
                    $state.RequestPaths.Add($ArgumentList[-1])
                    $request = Get-Content -LiteralPath $ArgumentList[-1] -Raw | ConvertFrom-Json -AsHashtable
                    $request.name | Should -BeExactly 'VALIDATE_MODULE_CLIENT_IDS'
                    $state.Writes.Add($request.name)
                    $state.Variables[$request.name] = @{
                        name = $request.name; value = $request.value
                        created_at = '2026-10-01T00:00:00Z'; updated_at = '2026-10-09T00:00:00Z'
                    }
                    $body = @{}
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = ConvertTo-Json -InputObject $body -Depth 10 -Compress; StdErr = '' }
            }
            if ($command -cne 'terraform') { throw 'Only blocked Terraform and GitHub executables may be invoked.' }
            $EnvVars.ARM_TENANT_ID | Should -BeExactly '10000000-0000-4000-8000-000000000001'
            $EnvVars.ARM_CLIENT_ID | Should -BeExactly '10000000-0000-4000-8000-000000000002'
            $EnvVars.ARM_CLIENT_SECRET | Should -BeNullOrEmpty
            $EnvVars.TF_CLI_ARGS | Should -BeNullOrEmpty
            $displayingPlan = $ArgumentList[0] -ceq 'show' -and $ArgumentList -contains '-no-color'
            ([bool]$StreamOutput) | Should -Be ($displayingPlan -or $ArgumentList[0] -ceq 'apply')
            if ($StreamOutput) {
                $OnStdOutLine | Should -Not -BeNullOrEmpty
                $OnStdErrLine | Should -Not -BeNullOrEmpty
            }
            if ($ArgumentList[0] -ceq $state.FailOperation -or ($displayingPlan -and $state.FailOperation -ceq 'display')) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = 'raw-plan-sentinel'; StdErr = 'private-diagnostic-sentinel' }
            }
            switch ($ArgumentList[0]) {
                'init' {
                    $ArgumentList | Should -Contain '-backend-config=key=bicep-module-identities.tfstate'
                    $ArgumentList | Should -Contain '-backend-config=client_id=20000000-0000-4000-8000-000000000003'
                    $ArgumentList | Should -Contain '-backend-config=use_cli=false'
                    $ArgumentList | Should -Not -Contain '-force-copy'
                    $body = ''
                }
                'plan' {
                    $inputPath = @($ArgumentList | Where-Object { $_.StartsWith('-var-file=') })[0].Substring(10)
                    $state.Parameters = Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json -AsHashtable
                    $state.PlanPath = @($ArgumentList | Where-Object { $_.StartsWith('-out=') })[0].Substring(5)
                    [IO.File]::WriteAllText($state.PlanPath, 'opaque-saved-plan')
                    $body = 'raw-plan-sentinel'
                }
                'show' {
                    if ($displayingPlan) {
                        $ArgumentList | Should -Be @('show', '-no-color', $state.PlanPath)
                        $body = @(
                            '# azapi_resource.identity["avm/res/storage/storage-account"] will be created'
                            '  + name = "id-test-bicep-avm-res-storage-storage-account"'
                            '  ~ display_name = "old-name" -> "new-name"'
                            '    sensitive_attribute = (sensitive value)'
                        ) -join "`n"
                    }
                    else {
                        $ArgumentList | Should -Be @('show', '-json', $state.PlanPath)
                        $body = ConvertTo-Json -InputObject $state.Plan -Depth 100 -Compress
                    }
                }
                'apply' {
                    $ArgumentList[-1] | Should -BeExactly $state.PlanPath
                    [IO.File]::ReadAllText($ArgumentList[-1]) | Should -BeExactly 'opaque-saved-plan'
                    $body = @(
                        'azapi_resource.identity["avm/res/storage/storage-account"]: Creating...'
                        'azapi_resource.identity["avm/res/storage/storage-account"]: Creation complete after 1s'
                    ) -join "`n"
                }
                'output' {
                    $ArgumentList | Should -Be @('output', '-json', 'test_identities')
                    $body = ConvertTo-Json -InputObject $state.Outputs -Depth 10 -Compress
                }
                default { throw 'Unexpected Terraform operation; state repair and retries are forbidden.' }
            }
            if ($StreamOutput) {
                foreach ($line in ($body -split "`n")) { & $OnStdOutLine $line }
                & $OnStdErrLine "provider warning $env:GH_TOKEN $env:ARM_CLIENT_SECRET"
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $body; StdErr = '' }
        }.GetNewClosure())
    }

    AfterEach {
        foreach ($name in $script:originalEnvironment.Keys) {
            $value = if ($null -eq $script:originalEnvironment[$name]) { [NullString]::Value } else { $script:originalEnvironment[$name] }
            [Environment]::SetEnvironmentVariable($name, $value)
        }
        foreach ($path in $script:state.RequestPaths) { Test-Path -LiteralPath $path | Should -BeFalse }
        @(Get-ChildItem -LiteralPath $script:terraformRoot -File | Where-Object { $_.Name -match '^[0-9a-f]{32}\.(tfvars\.json|tfplan)$' }) |
            Should -HaveCount 0
    }

    It 'discovers source-backed roots without including child modules, test templates or generated-only folders' {
        foreach ($path in @(
            'avm/res/storage/storage-account/blob-service',
            'avm/res/storage/storage-account/tests/e2e/defaults',
            'avm/res/storage/storage-account/modules/helper'
        )) {
            $directory = Join-Path $script:sourceRoot ($path.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $null = New-Item -ItemType Directory -Path $directory -Force
            [IO.File]::WriteAllText((Join-Path $directory 'main.bicep'), 'throw "source must never execute"')
        }
        $paths = Get-AvmBicepModulePath -BicepRoot $script:sourceRoot
        $paths | Should -Be @('avm/res/fabric/capacity', 'avm/res/storage/storage-account')
        $script:state.Calls | Should -HaveCount 0
    }

    It 'plans from the real entry point without applying or producing a consumable mapping' {
        $script:state.Plan = New-AvmTestBicepIdentityPlan -NamingMigration
        $information = [System.Collections.Generic.List[string]]::new()
        $result = & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath `
            -IdentityMigrationPath $script:migrationPath 6>&1 |
            ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { $information.Add([string]$_.MessageData) }
                else { $_ }
            } |
            ConvertFrom-Json -AsHashtable
        $result.Status | Should -BeExactly 'Planned'
        $result.ModuleCount | Should -Be 2
        $result.PlanOnly | Should -BeTrue
        Test-Path -LiteralPath $script:mappingPath | Should -BeFalse
        Test-Path -LiteralPath $script:migrationPath | Should -BeFalse
        ($information | Out-String) | Should -Match 'will be created'
        ($information | Out-String) | Should -Match 'id-test-bicep-avm-res-storage-storage-account'
        ($information | Out-String) | Should -Match '"old-name" -> "new-name"'
        ($information | Out-String) | Should -Match '\(sensitive value\)'
        ($information | Out-String) | Should -Not -Match 'raw-plan-sentinel|fixture-token|unused-secret-sentinel'
        @($script:state.Calls | Where-Object Command -CEQ 'terraform' | ForEach-Object { $_.Arguments[0] }) |
            Should -Be @('init', 'plan', 'show', 'show')
    }

    It 'applies one verified saved plan and publishes only its mapping while retaining the shared identity' {
        $information = [System.Collections.Generic.List[string]]::new()
        $result = & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -Apply `
            6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { $information.Add([string]$_.MessageData) }
                else { $_ }
            } | ConvertFrom-Json -AsHashtable
        $result.Status | Should -BeExactly 'Applied'
        ($information | Out-String) | Should -Not -Match 'raw-plan-sentinel|raw-output-sentinel'
        ($information | Out-String) | Should -Match 'Creating\.\.\.'
        ($information | Out-String) | Should -Match 'Creation complete after 1s'
        ($information | Out-String) | Should -Not -Match 'fixture-token|unused-secret-sentinel'
        $script:state.Parameters.modules['avm/res/storage/storage-account'] |
            Should -Contain 'avm-test-management-group-iam-admins'
        $script:state.Parameters.modules['avm/res/fabric/capacity'] | Should -HaveCount 2
        $bytes = [IO.File]::ReadAllBytes($script:mappingPath)
        ($bytes[0..2] -join ',') | Should -Not -Be '239,187,191'
        [Text.Encoding]::UTF8.GetString($bytes) | Should -Not -Match '\r|\n'
        $publication = & $script:publisherPath -ModuleClientIdPath $script:mappingPath -Apply | ConvertFrom-Json -AsHashtable
        $publication.Status | Should -BeExactly 'Published'
        $script:state.Writes | Should -Be @('VALIDATE_MODULE_CLIENT_IDS')
        $remaining = [ordered]@{}
        foreach ($name in $script:state.Variables.Keys) {
            if ($name -cne 'VALIDATE_MODULE_CLIENT_IDS') { $remaining[$name] = $script:state.Variables[$name] }
        }
        ConvertTo-Json -InputObject $remaining -Depth 5 -Compress | Should -BeExactly $script:beforeVariables
        @($script:state.Calls | Where-Object Command -CEQ 'terraform' | ForEach-Object { $_.Arguments[0] }) |
            Should -Be @('init', 'plan', 'show', 'show', 'apply', 'output')
    }

    It 'replaces legacy module identities and updates only exactly matching old client bindings from the same run' {
        $script:state.Plan = New-AvmTestBicepIdentityPlan -NamingMigration
        $previous = (New-AvmTestBicepIdentityMigration).before
        $oldMapping = ConvertTo-AvmBicepIdentityMapping -Identities $previous -ModulePaths @($previous.Keys) -Settings $script:values -Legacy
        $script:state.Variables.VALIDATE_MODULE_CLIENT_IDS = @{
            name = 'VALIDATE_MODULE_CLIENT_IDS'; value = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $oldMapping
            created_at = '2026-10-01T00:00:00Z'; updated_at = '2026-10-01T00:00:00Z'
        }
        $result = & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath `
            -IdentityMigrationPath $script:migrationPath -Apply | ConvertFrom-Json -AsHashtable
        $result.Status | Should -BeExactly 'Applied'
        $evidence = Get-Content -LiteralPath $script:migrationPath -Raw | ConvertFrom-Json -AsHashtable
        $evidence.before['avm/res/fabric/capacity'].client_id | Should -BeExactly $oldMapping['avm/res/fabric/capacity']
        $evidence.after['avm/res/fabric/capacity'].client_id | Should -BeExactly '10000000-0000-4000-8000-000000000006'
        $evidence.context.runId | Should -BeExactly $env:GITHUB_RUN_ID
        $publication = & $script:publisherPath -ModuleClientIdPath $script:mappingPath `
            -IdentityMigrationPath $script:migrationPath -Apply | ConvertFrom-Json -AsHashtable
        $publication.Status | Should -BeExactly 'Published'
        $script:state.Writes | Should -Be @('VALIDATE_MODULE_CLIENT_IDS')
        $remaining = [ordered]@{}
        foreach ($name in $script:state.Variables.Keys) {
            if ($name -cne 'VALIDATE_MODULE_CLIENT_IDS') { $remaining[$name] = $script:state.Variables[$name] }
        }
        ConvertTo-Json -InputObject $remaining -Depth 5 -Compress | Should -BeExactly $script:beforeVariables
        (& $script:publisherPath -ModuleClientIdPath $script:mappingPath -IdentityMigrationPath $script:migrationPath -Apply |
            ConvertFrom-Json -AsHashtable).Status | Should -BeExactly 'NoChange'
        $script:state.Writes | Should -HaveCount 1
    }

    It 'refuses a naming apply without a path for its verified publication evidence' {
        $script:state.Plan = New-AvmTestBicepIdentityPlan -NamingMigration
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -Apply } |
            Should -Throw '*IdentityMigrationPath*before applying*'
        @($script:state.Calls | Where-Object { $_.Command -ceq 'terraform' -and $_.Arguments[0] -ceq 'apply' }) |
            Should -HaveCount 0
    }

    It 'rejects stale, foreign or malformed rename evidence before publication: <Case>' -ForEach @(
        @{ Case = 'run'; Edit = { param($m) $m.context.runId = '987654321' } }
        @{ Case = 'attempt'; Edit = { param($m) $m.context.runAttempt = '2' } }
        @{ Case = 'commit'; Edit = { param($m) $m.context.commit = 'ffffffffffffffffffffffffffffffffffffffff' } }
        @{ Case = 'workflow'; Edit = { param($m) $m.context.workflowRef = 'untrusted' } }
        @{ Case = 'repository'; Edit = { param($m) $m.context.repositoryId = '9999' } }
        @{ Case = 'old resource'; Edit = { param($m) $m.before['avm/res/fabric/capacity'].identity_resource_id = '/foreign/identity' } }
        @{ Case = 'old tenant'; Edit = { param($m) $m.before['avm/res/fabric/capacity'].tenant_id = '90000000-0000-4000-8000-000000000001' } }
        @{ Case = 'old client differs from published value'; Edit = { param($m) $m.before['avm/res/fabric/capacity'].client_id = '90000000-0000-4000-8000-000000000001' } }
        @{ Case = 'new client differs from mapping'; Edit = { param($m) $m.after['avm/res/fabric/capacity'].client_id = '90000000-0000-4000-8000-000000000001' } }
        @{ Case = 'new resource'; Edit = { param($m) $m.after['avm/res/fabric/capacity'].identity_resource_id = $m.before['avm/res/fabric/capacity'].identity_resource_id } }
        @{ Case = 'old controller'; Edit = { param($m) $m.before['avm/res/fabric/capacity'].client_id = '10000000-0000-4000-8000-000000000002' } }
        @{ Case = 'old shared identity'; Edit = { param($m) $m.before['avm/res/fabric/capacity'].client_id = '10000000-0000-4000-8000-000000000004' } }
        @{ Case = 'missing entry'; Edit = { param($m) $m.after.Remove('avm/res/fabric/capacity') } }
        @{ Case = 'empty exception'; Edit = { param($m) $m.before = @{}; $m.after = @{} } }
        @{ Case = 'invalid version'; Edit = { param($m) $m.schemaVersion = $true } }
    ) {
        $migration = New-AvmTestBicepIdentityMigration
        $previous = ConvertTo-AvmBicepIdentityMapping -Identities $migration.before -ModulePaths @($migration.before.Keys) -Settings $script:values -Legacy
        $script:state.Variables.VALIDATE_MODULE_CLIENT_IDS = @{
            name = 'VALIDATE_MODULE_CLIENT_IDS'; value = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $previous
            created_at = '2026-10-01T00:00:00Z'; updated_at = '2026-10-01T00:00:00Z'
        }
        $mapping = ConvertTo-AvmBicepIdentityMapping -Identities $migration.after -ModulePaths @($migration.after.Keys) -Settings $script:values
        [IO.File]::WriteAllText($script:mappingPath, (ConvertTo-AvmBicepModuleClientIdJson -ClientIds $mapping))
        & $Edit $migration
        [IO.File]::WriteAllText($script:migrationPath, (ConvertTo-Json -InputObject $migration -Depth 10 -Compress))
        { & $script:publisherPath -ModuleClientIdPath $script:mappingPath -IdentityMigrationPath $script:migrationPath -Apply } |
            Should -Throw
        $script:state.Writes | Should -HaveCount 0
    }

    It 'refuses naming receipts outside the trusted workflow run before invoking Terraform' {
        $env:GITHUB_RUN_ID = ''
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -IdentityMigrationPath $script:migrationPath -Apply } |
            Should -Throw '*current trusted Bicep Sync run*'
        $script:state.Calls | Should -HaveCount 0
    }

    It 'stops on <Operation> failure without retrying apply, repairing state or publishing' -ForEach @(
        @{ Operation = 'init' }, @{ Operation = 'plan' }, @{ Operation = 'show' }, @{ Operation = 'apply' }, @{ Operation = 'output' }
    ) {
        $script:state.Plan = New-AvmTestBicepIdentityPlan -NamingMigration
        $script:state.FailOperation = $Operation
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -IdentityMigrationPath $script:migrationPath -Apply } |
            Should -Throw "*Terraform $Operation failed*"
        @($script:state.Calls | Where-Object { $_.Command -ceq 'terraform' -and $_.Arguments[0] -ceq $Operation }) |
            Should -HaveCount 1
        Test-Path -LiteralPath $script:mappingPath | Should -BeFalse
        Test-Path -LiteralPath $script:migrationPath | Should -BeFalse
        $script:state.Writes | Should -HaveCount 0
    }

    It 'rejects an unsafe plan before apply' {
        $script:state.Plan.resource_changes[0].change.actions = @('delete', 'create')
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -Apply } | Should -Throw
        @($script:state.Calls | Where-Object { $_.Command -ceq 'terraform' -and $_.Arguments[0] -ceq 'apply' }) |
            Should -HaveCount 0
        @($script:state.Calls | Where-Object { $_.Command -ceq 'terraform' -and $_.Arguments -contains '-no-color' -and $_.Arguments[0] -ceq 'show' }) |
            Should -HaveCount 0
        Test-Path -LiteralPath $script:mappingPath | Should -BeFalse
    }

    It 'does not apply when the verified human-readable plan cannot be displayed' {
        $script:state.FailOperation = 'display'
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -Apply } |
            Should -Throw '*Terraform show failed*'
        @($script:state.Calls | Where-Object { $_.Command -ceq 'terraform' -and $_.Arguments[0] -ceq 'apply' }) |
            Should -HaveCount 0
        Test-Path -LiteralPath $script:mappingPath | Should -BeFalse
    }

    It 'does not export a partial, shared or wrong-tenant post-apply mapping' -ForEach @('partial', 'shared', 'tenant') {
        $script:state.Plan = New-AvmTestBicepIdentityPlan -NamingMigration
        switch ($_) {
            'partial' { $script:state.Outputs.Remove('avm/res/fabric/capacity') }
            'shared' { $script:state.Outputs['avm/res/fabric/capacity'].client_id = $script:values.TEST_BAMI_BICEP_CLIENT_ID }
            'tenant' { $script:state.Outputs['avm/res/fabric/capacity'].tenant_id = $script:backendValues.ARM_BACKEND_TENANT_ID }
        }
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -IdentityMigrationPath $script:migrationPath -Apply } | Should -Throw
        Test-Path -LiteralPath $script:mappingPath | Should -BeFalse
        Test-Path -LiteralPath $script:migrationPath | Should -BeFalse
        $script:state.Writes | Should -HaveCount 0
    }

    It 'rejects invalid source, backend or execution context before Terraform' -ForEach @(
        'foreign-registry', 'untrusted-ref', 'invalid-source', 'offline', 'controller-backend', 'execution-backend'
    ) {
        switch ($_) {
            'foreign-registry' { $script:state.BadRepository = $true }
            'untrusted-ref' { $env:GITHUB_REF = 'refs/heads/untrusted' }
            'invalid-source' { $env:TEST_BAMI_TENANT_ID = 'invalid' }
            'offline' { $env:AVM_OFFLINE = '1' }
            'controller-backend' { $env:ARM_BACKEND_CLIENT_ID = $script:values.TEST_BAMI_CONTROLLER_CLIENT_ID }
            'execution-backend' { $env:ARM_BACKEND_CLIENT_ID = $script:values.TEST_BAMI_BICEP_CLIENT_ID }
        }
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -Apply } | Should -Throw
        @($script:state.Calls | Where-Object Command -CEQ 'terraform') | Should -HaveCount 0
    }

    It 'rejects a linked module inventory before invoking a service' {
        $inventory = Join-Path $script:sourceRoot 'avm'
        $target = Join-Path (Split-Path $script:sourceRoot) 'linked-inventory'
        Move-Item -LiteralPath $inventory -Destination $target
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path $inventory -Target $target
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -Apply } |
            Should -Throw '*directory link*'
        $script:state.Calls | Should -HaveCount 0
    }

    It 'rejects ambiguous or overlong discovered identity names before any service call' -ForEach @(
        @{ Paths = @('avm/res/a-b/c', 'avm/res/a/b-c'); ExpectedError = '*unique*' }
        @{ Paths = @('avm/res/a/' + ('b' * 59)); ExpectedError = '*68 characters*' }
    ) {
        foreach ($path in $Paths) {
            $directory = Join-Path $script:sourceRoot ($path.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $null = New-Item -ItemType Directory -Path $directory -Force
            [IO.File]::WriteAllText((Join-Path $directory 'main.bicep'), "targetScope = 'resourceGroup'`n")
        }
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -Apply } | Should -Throw $ExpectedError
        $script:state.Calls | Should -HaveCount 0
    }

    It 'rejects an oversized discovered mapping before invoking a service' {
        foreach ($path in (New-AvmTestSizedBicepClientIds -ByteCount 49153).Keys) {
            $directory = Join-Path $script:sourceRoot ($path.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $null = New-Item -ItemType Directory -Path $directory -Force
            [IO.File]::WriteAllText((Join-Path $directory 'main.bicep'), "targetScope = 'resourceGroup'`n")
        }
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -Apply } |
            Should -Throw '*48 KB*'
        $script:state.Calls | Should -HaveCount 0
    }

    It 'keeps WhatIf entirely process-free and refuses PlanOnly false' {
        $result = & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -Apply -WhatIf |
            ConvertFrom-Json -AsHashtable
        $result.Status | Should -BeExactly 'Preview'
        { & $script:entryPath -BicepRoot $script:sourceRoot -MappingPath $script:mappingPath -PlanOnly:$false } |
            Should -Throw '*Use -Apply explicitly*'
        $script:state.Calls | Should -HaveCount 0
    }

    It 'transports a full 48 KiB mapping through a short request-file command and cleans it up' {
        $json = ConvertTo-AvmBicepModuleClientIdJson -ClientIds (New-AvmTestSizedBicepClientIds)
        [Text.Encoding]::UTF8.GetByteCount($json) | Should -Be 49152
        $null = Invoke-AvmBicepTestTenantVariableApi -Method 'POST' -Name 'VALIDATE_MODULE_CLIENT_IDS' -Value $json
        $script:state.Variables.VALIDATE_MODULE_CLIENT_IDS.value | Should -BeExactly $json
        ($script:state.Calls[-1].Arguments -join ' ').Length | Should -BeLessThan 1000
        $script:state.RequestPaths | Should -HaveCount 1
    }
}
