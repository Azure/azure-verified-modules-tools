#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force

    function New-UnitMigrationFixture {
        $root = Join-Path $TestDrive 'module with spaces, and=equals'
        $child = Join-Path $root 'modules' 'child'
        $targets = @(
            [pscustomobject]@{ Path = $root; Scope = 'root'; Profiles = @('root', 'module', 'common') }
            [pscustomobject]@{ Path = $child; Scope = 'module'; Profiles = @('root', 'module', 'common') }
        )
        $before = @{
            test    = @{
                variables      = $null
                runs           = @{
                    root  = @{ mptf = @{ attributes = @{ command = 'plan' } } }
                    child = @{ mptf = @{ attributes = @{ command = 'plan' } } }
                }
                run_modules    = @{
                    root  = @{ kind = 'root'; dir = $root; source = $null }
                    child = @{ kind = 'local'; dir = $child; source = './modules/child' }
                }
                mock_providers = @{
                    azapi = New-CustomTelemetryMock -Defaults @{
                        subscription_resource_id = '/subscriptions/00000000-0000-0000-0000-000000000000'
                    }
                }
                providers      = @{}
            }
            modules = @{
                $root  = @{ variables = @{} }
                $child = @{ variables = @{} }
            }
        }
        $after = $before | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        foreach ($target in $targets) {
            $after.modules[$target.Path].variables.location = @{ required = $true }
        }
        $scope = [pscustomobject]@{
            File         = [pscustomobject]@{
                Name     = 'scopes.tftest.hcl'
                FullName = Join-Path $root 'tests' 'unit' 'scopes.tftest.hcl'
            }
            Owner        = $targets[0]
            RelativePath = 'tests/unit/scopes.tftest.hcl'
            IsUnitTest   = $true
            Inspection   = $after
        }
        [pscustomobject]@{
            Root      = $root
            Child     = $child
            Targets   = $targets
            Scope     = $scope
            Before    = $before
            After     = $after
            Snapshots = @([pscustomobject]@{ Scope = $scope; Hash = 'before'; Before = $before })
            Options   = [pscustomobject]@{
                ToolPath       = Join-Path $TestDrive 'mapotf'
                TerraformPath  = Join-Path $TestDrive 'terraform'
                ProfileDirs    = @{
                    module              = Join-Path $TestDrive 'module-profile'
                    'unit-test-inspect' = Join-Path $TestDrive 'inspection'
                    'unit-test'         = Join-Path $TestDrive 'location'
                }
                EnvVars        = @{}
                InspectionRoot = Join-Path $TestDrive ('provider-inspection-' + [guid]::NewGuid().ToString('N'))
            }
        }
    }

    function Read-UnitMigrationInspection {
        param($Fixture, [string] $Json)
        if (-not $PSBoundParameters.ContainsKey('Json')) {
            $Json = $Fixture.After | ConvertTo-Json -Depth 20 -Compress
        }
        $Fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = $Json
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $Fixture } {
            param($Fixture)
            Get-AvmTerraformUnitTestInspection -Scope $Fixture.Scope `
                -ModuleTargets $Fixture.Targets -Options $Fixture.Options
        }
    }

    function Invoke-UnitMigrationFixture {
        param($Fixture, [switch] $WhatIf, [AllowEmptyString()] [string] $TestContent)
        $directory = Split-Path -Parent $Fixture.Scope.File.FullName
        $null = New-Item -ItemType Directory -Path $directory -Force
        $conditions = @(
            foreach ($run in $Fixture.After.test.runs.Values) {
                if ($run.Contains('assert')) {
                    foreach ($assertion in $run.assert) {
                        if ($assertion -is [System.Collections.IDictionary] -and
                            $assertion['mptf'] -is [System.Collections.IDictionary] -and
                            $assertion.mptf['attributes'] -is [System.Collections.IDictionary]) {
                            [string]$assertion.mptf.attributes['condition']
                        }
                    }
                }
            }
        )
        if (-not $PSBoundParameters.ContainsKey('TestContent')) {
            $TestContent = $conditions -join "`n"
        }
        [System.IO.File]::WriteAllText($Fixture.Scope.File.FullName, $TestContent, [System.Text.UTF8Encoding]::new($false))
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $Fixture; DryRun = [bool]$WhatIf } {
            param($Fixture, $DryRun)
            Invoke-AvmTerraformUnitTestMigration -Root $Fixture.Root -ModuleTargets $Fixture.Targets `
                -Snapshots $Fixture.Snapshots -Options $Fixture.Options -WhatIf:$DryRun
        }
    }

    function New-CustomTelemetryMock {
        param([object] $Defaults = @{}, [string] $Alias)
        $attributes = @{}
        if ($Alias) { $attributes.alias = $Alias }
        @{
            mptf      = @{
                is_empty = $false
                attributes = $attributes
                block_type = 'mock_provider'
                block_labels = @('azapi')
                block_address = if ($Alias) { "mock_provider.azapi.$Alias" } else { 'mock_provider.azapi' }
            }
            mock_data = @(
                @{
                    mptf = @{
                        block_labels = @('azapi_client_config')
                        attributes   = @{ defaults = $Defaults }
                    }
                },
                @{
                    mptf = @{
                        block_labels = @('azapi_resource_list')
                        attributes   = @{ defaults = @{ output = @{ value = @() } } }
                    }
                }

            )
        }
    }

    function New-UnitProviderAlias {
        param([string] $Provider, [string] $Alias = 'unit')
        @{
            mptf = @{
                is_empty = $false
                attributes = @{ alias = $Alias }
                block_type = 'mock_provider'
                block_labels = @($Provider)
                block_address = "mock_provider.$Provider.$Alias"
            }
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Terraform unit-test migration' {
    BeforeEach {
        $script:fixture = New-UnitMigrationFixture
        Mock Get-FileHash -ModuleName Avm.Authoring { [pscustomobject]@{ Hash = 'before' } }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            [pscustomobject]@{ ExitCode = 0; StdOut = $EnvVars['AVM_TEST_INSPECTION_JSON']; StdErr = '' }
        }
        Mock Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring
    }

    Context 'native inspection' {
        It 'passes one exact test file and an escaped local allowlist as separate arguments' {
            $result = Read-UnitMigrationInspection -Fixture $script:fixture
            $result.test.run_modules.child.dir | Should -BeExactly $script:fixture.Child
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList[0] -eq 'debug' -and
                    $ArgumentList[2] -ceq $Fixture.Root -and
                    $ArgumentList[4] -ceq 'tests/unit/scopes.tftest.hcl' -and
                    $ArgumentList[6] -ceq $Fixture.Options.ProfileDirs['unit-test-inspect'] -and
                    $ArgumentList[8] -ceq ('allowed_module_directories=' +
                        (ConvertTo-Json -InputObject @($Fixture.Root, $Fixture.Child) -Compress)) -and
                    $WorkingDirectory -ceq $Fixture.Root
                }
            }
        }

        It 'reports malformed JSON rather than treating it as an empty test' {
            { Read-UnitMigrationInspection -Fixture $script:fixture -Json 'not json' } |
                Should -Throw '*invalid MaPoTF JSON*'
        }

        It 'rejects incomplete native inspection data' -TestCases @(
            @{ Field = 'test' }
            @{ Field = 'modules' }
            @{ Field = 'runs' }
            @{ Field = 'run_modules' }
            @{ Field = 'mock_providers' }
            @{ Field = 'providers' }
            @{ Field = 'variables' }
        ) {
            param($Field)
            if ($Field -in @('test', 'modules')) {
                $script:fixture.After.Remove($Field)
            }
            else {
                $script:fixture.After.test.Remove($Field)
            }
            { Read-UnitMigrationInspection -Fixture $script:fixture } |
                Should -Throw '*Cannot inspect Terraform unit test*'
        }

        It 'does not treat <Malformed> run metadata as an explicitly empty collection' -TestCases @(
            @{ Malformed = 'missing runs'; Field = 'runs'; Shape = 'missing' }
            @{ Malformed = 'null runs'; Field = 'runs'; Shape = 'null' }
            @{ Malformed = 'array runs'; Field = 'runs'; Shape = 'array' }
            @{ Malformed = 'missing run targets'; Field = 'run_modules'; Shape = 'missing' }
            @{ Malformed = 'array run targets'; Field = 'run_modules'; Shape = 'array' }
            @{ Malformed = 'unmatched run targets'; Field = 'run_modules'; Shape = 'unmatched' }
        ) {
            param($Field, $Shape)
            $script:fixture.After.test.runs.Clear()
            $script:fixture.After.test.run_modules.Clear()
            switch ($Shape) {
                missing { $script:fixture.After.test.Remove($Field) }
                null { $script:fixture.After.test[$Field] = $null }
                array { $script:fixture.After.test[$Field] = @() }
                unmatched { $script:fixture.After.test.run_modules = $script:fixture.Before.test.run_modules }
            }
            { Read-UnitMigrationInspection -Fixture $script:fixture } |
                Should -Throw '*Cannot*unit test*'
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
        }

        It 'rejects remote or unknown local targets instead of assuming the owner' -TestCases @(
            @{ Kind = 'remote'; Path = $null }
            @{ Kind = 'local'; Path = 'unknown' }
        ) {
            param($Kind, $Path)
            $script:fixture.After.test.run_modules.child = @{ kind = $Kind; dir = $Path }
            { Read-UnitMigrationInspection -Fixture $script:fixture } |
                Should -Throw '*target must be a known local module*'
        }

        It 'rejects an uninspected run' {
            $script:fixture.After.test.run_modules.Remove('child')
            { Read-UnitMigrationInspection -Fixture $script:fixture } |
                Should -Throw '*run targets are incomplete*'
        }

        It 'rejects malformed run variables or location declarations' -TestCases @(
            @{ Malformed = 'run' }
            @{ Malformed = 'variables' }
            @{ Malformed = 'location' }
        ) {
            param($Malformed)
            switch ($Malformed) {
                run { $script:fixture.After.test.runs.root = @{} }
                variables { $script:fixture.After.test.runs.root.variables = @() }
                location { $script:fixture.After.modules[$script:fixture.Root].variables.location.required = 'true' }
            }
            { Read-UnitMigrationInspection -Fixture $script:fixture } |
                Should -Throw '*invalid * inspection*'
        }

        It 'propagates a failed native inspection without attempting migration' {
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring { throw [System.InvalidOperationException]::new('native inspection failed') }
            { Read-UnitMigrationInspection -Fixture $script:fixture } | Should -Throw '*native inspection failed*'
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
        }
    }

    Context 'native provider inspection' {
        It 'inspects the selected target through the existing module profile' {
            $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] =
                '{"random":{"source":"hashicorp/random","version":"~> 3.0"}}'
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                $result = Get-AvmTerraformUnitTestRequiredProvider -Path $Fixture.Child -Options $Fixture.Options
                $result.random.source | Should -BeExactly 'hashicorp/random'
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList -join '|' -ceq
                    ('debug|--tf-dir|' + $Fixture.Child + '|--mptf-dir|' +
                        $Fixture.Options.ProfileDirs.module + '|--eval|data.terraform.this.required_providers') -and
                    $WorkingDirectory -ceq $Fixture.Child
                }
            }
        }

        It 'rejects malformed or unavailable provider metadata' -TestCases @(
            @{ Json = 'null' }
            @{ Json = '[]' }
            @{ Json = 'true' }
            @{ Json = '{"random":null}' }
            @{ Json = '{"random":{"source":42}}' }
            @{ Json = 'invalid JSON' }
        ) {
            param($Json)
            $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = $Json
            {
                InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                    param($Fixture)
                    Get-AvmTerraformUnitTestRequiredProvider -Path $Fixture.Child -Options $Fixture.Options
                }
            } | Should -Throw '*Cannot inspect provider requirements*'
        }
    }

    Context 'configuration provider trees' {
        BeforeEach {
            $script:fixture.Child = Join-Path $script:fixture.Child ([guid]::NewGuid().ToString('N'))
            $script:fixture.Targets[1].Path = $script:fixture.Child
            $null = New-Item -ItemType Directory -Path $script:fixture.Child -Force
            Mock Invoke-AvmTerraformInit -ModuleName Avm.Authoring {}
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {} -ParameterFilter { $ArgumentList[0] -ceq 'get' }
        }

        It 'keeps configuration dependencies but excludes tests and state-only providers' {
            $text = @"
Providers required by configuration:
.
`u{251c}`u{2500}`u{2500} test.tests/unit/selected
`u{2502}   `u{2514}`u{2500}`u{2500} run.clock
`u{2502}       `u{2514}`u{2500}`u{2500} provider[registry.terraform.io/hashicorp/time] 0.13.1
`u{251c}`u{2500}`u{2500} provider[registry.terraform.io/azure/azapi] ~> 2.12
`u{2514}`u{2500}`u{2500} module.dependency
    `u{2514}`u{2500}`u{2500} provider[registry.terraform.io/hashicorp/random] ~> 3.0

Providers required by state:

    provider[registry.terraform.io/azure/modtm]
"@
            $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = $text
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                $result = @(Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options)
                $result | Should -HaveCount 2
                $result | Should -Contain 'registry.terraform.io/azure/azapi'
                $result | Should -Contain 'registry.terraform.io/hashicorp/random'
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $FilePath -ceq $Fixture.Options.TerraformPath -and
                    $ArgumentList -join '|' -ceq 'providers|-no-color|-test-directory=tests' -and
                    $WorkingDirectory -ceq $Fixture.Child
                }
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $FilePath -ceq $Fixture.Options.TerraformPath -and
                    $ArgumentList -join '|' -ceq 'get|-no-color' -and [bool]$RetryNetworkFailure -and
                    $WorkingDirectory -ceq $Fixture.Child -and
                    $EnvVars.TF_DATA_DIR.StartsWith($Fixture.Options.InspectionRoot)
                }
                Should -Invoke Invoke-AvmTerraformInit -Exactly 0
            }
        }

        It 'rejects a missing inspection scope before native work: <Shape>' -TestCases @(
            @{ Shape = 'absent' }
            @{ Shape = 'null'; Value = $null }
            @{ Shape = 'blank'; Value = ' ' }
        ) {
            param($Shape, $Value)
            if ($Shape -ceq 'absent') {
                $script:fixture.Options.PSObject.Properties.Remove('InspectionRoot')
            }
            else {
                $script:fixture.Options.InspectionRoot = $Value
            }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                { Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options } |
                    Should -Throw '*requires an owned temporary InspectionRoot*'
                Should -Invoke Invoke-AvmProcess -Exactly 0
                Should -Invoke Invoke-AvmTerraformInit -Exactly 0
            }
        }

        It 'accepts CRLF and nonbreaking-space indentation' {
            $text = "Providers required by configuration:`r`n.`r`n" +
            "`u{2514}`u{2500}`u{2500} module.child`r`n" +
            "`u{00a0}`u{00a0}`u{00a0}`u{00a0}`u{2514}`u{2500}`u{2500} provider[registry.terraform.io/hashicorp/random]`r`n"
            InModuleScope Avm.Authoring -Parameters @{ Text = $text } {
                param($Text)
                @(ConvertFrom-AvmTerraformProviderTree -Text $Text -Path 'target') |
                    Should -Be @('registry.terraform.io/hashicorp/random')
            }
        }

        It 'fails before Terraform for potentially stateful or uninspectable configuration: <Shape>' -TestCases @(
            @{ Shape = 'inline backend'; File = 'main.tf'; Text = 'terraform { backend "azurerm" {} }' }
            @{ Shape = 'backend separated by comments'; File = 'backend.tf'; Text = 'terraform { backend /* preserve */ "azurerm" {} }' }
            @{ Shape = 'cloud execution'; File = 'main.tf'; Text = "terraform { cloud # authored`n { organization = `"example`" } }" }
            @{ Shape = 'state store'; File = 'main.tf'; Text = 'terraform { state_store "azure" "example" {} }' }
            @{ Shape = 'JSON configuration'; File = 'main.tf.json'; Text = '{}' }
            @{ Shape = 'JSON test'; File = 'root.tftest.json'; Text = '{}' }
        ) {
            param($File, $Text)
            Set-Content -LiteralPath (Join-Path $script:fixture.Child $File) -Value $Text -Encoding utf8NoBOM
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                { Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options } |
                    Should -Throw '*review*'
                Should -Invoke Invoke-AvmProcess -Exactly 0
                Should -Invoke Invoke-AvmTerraformInit -Exactly 0
            }
        }

        It 'does not access an initialized backend even when its declaration was removed' {
            $directory = Join-Path $script:fixture.Child '.terraform'
            $null = New-Item -ItemType Directory -Path $directory -Force
            Set-Content -LiteralPath (Join-Path $directory 'terraform.tfstate') -Value '{}' -Encoding utf8NoBOM
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                { Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options } |
                    Should -Throw '*initialized backend requires review*'
                Should -Invoke Invoke-AvmProcess -Exactly 0
                Should -Invoke Invoke-AvmTerraformInit -Exactly 0
            }
        }

        It 'validates default-directory and root test targets before installing dependencies' -TestCases @(
            @{ Directory = '' }
            @{ Directory = 'tests' }
        ) {
            param($Directory)
            $directoryPath = Join-Path $script:fixture.Child $Directory
            $null = New-Item -ItemType Directory -Path $directoryPath -Force
            Set-Content -LiteralPath (Join-Path $directoryPath 'selected.tftest.hcl') -Value '' -Encoding utf8NoBOM
            Mock Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring {
                throw [System.InvalidOperationException]::new('unknown test target')
            }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                { Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options } |
                    Should -Throw '*unknown test target*'
                Should -Invoke Get-AvmTerraformUnitTestInspection -Exactly 1 -ParameterFilter {
                    $Scope.Owner.Path -ceq $Fixture.Child -and
                    $ModuleTargets.Count -eq $Fixture.Targets.Count
                }
                Should -Invoke Invoke-AvmProcess -Exactly 0
                Should -Invoke Invoke-AvmTerraformInit -Exactly 0
            }
        }

        It 'propagates dependency installation failure without reading provider requirements' {
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                throw [System.InvalidOperationException]::new('module installation failed')
            } -ParameterFilter { $ArgumentList[0] -ceq 'get' }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                { Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options } |
                    Should -Throw '*module installation failed*'
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -ceq 'get' }
                Should -Invoke Invoke-AvmTerraformInit -Exactly 0
                Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'providers' }
            }
        }

        It 'isolates dependency inspection arguments without changing the caller environment' {
            Set-Content -LiteralPath (Join-Path $script:fixture.Child 'main.tf') -Encoding utf8NoBOM `
                -Value 'module "backend" { source = "../backend" }'
            foreach ($name in @('TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_get', 'TF_CLI_ARGS_providers')) {
                $script:fixture.Options.EnvVars[$name] = 'authored'
            }
            $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = "Providers required by configuration:`n."
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                @(Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options) | Should -HaveCount 0
                Should -Invoke Invoke-AvmProcess -Exactly 2 -ParameterFilter {
                    $EnvVars.TF_DATA_DIR.StartsWith($Fixture.Options.InspectionRoot + [IO.Path]::DirectorySeparatorChar) -and
                    $null -eq $EnvVars.TF_CLI_ARGS -and
                    $null -eq $EnvVars.TF_CLI_ARGS_init -and $null -eq $EnvVars.TF_CLI_ARGS_get -and
                    $null -eq $EnvVars.TF_CLI_ARGS_providers
                }
                $Fixture.Options.EnvVars.TF_DATA_DIR | Should -BeExactly 'authored'
                $Fixture.Options.EnvVars.TF_CLI_ARGS_init | Should -BeExactly 'authored'
                $Fixture.Options.EnvVars.TF_CLI_ARGS_get | Should -BeExactly 'authored'
            }
        }

        It 'restores the original lock or its absence after inspection: <ExistingLock>, <Failure>' -TestCases @(
            @{ ExistingLock = $true; Failure = $false }
            @{ ExistingLock = $false; Failure = $false }
            @{ ExistingLock = $true; Failure = $true }
            @{ ExistingLock = $false; Failure = $true }
            @{ ExistingLock = $true; Failure = $false; EmptyLock = $true }
        ) {
            param($ExistingLock, $Failure, $EmptyLock = $false)
            $lockPath = Join-Path $script:fixture.Child '.terraform.lock.hcl'
            [byte[]]$original = @(1, 2, 3, 13, 10)
            if ($EmptyLock) { $original = @() }
            if ($ExistingLock) {
                [System.IO.File]::WriteAllBytes($lockPath, $original)
                $null = New-Item -ItemType Directory -Path (
                    Join-Path -Path $script:fixture.Child -ChildPath '.terraform' -AdditionalChildPath 'providers') -Force
            }
            $script:fixture.Options.EnvVars['AVM_TEST_FAIL_GET'] = $Failure
            $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = "Providers required by configuration:`n."
            $manifestPath = Join-Path -Path $script:fixture.Child -ChildPath '.terraform' -AdditionalChildPath 'modules', 'modules.json'
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force
            $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes(
                "{`r`n  `"Modules`": [{`"Key`":`"`",`"Dir`":`".`"},{`"Key`":`"published`",`"Dir`":`".terraform/modules/published`",`"Source`":`"Azure/example/azurerm`",`"Version`":`"0.1.0`"}]`r`n}`r`n")
            [System.IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                Set-Content -LiteralPath (Join-Path $WorkingDirectory '.terraform.lock.hcl') -Value 'updated lock'
                $directory = Join-Path $EnvVars.TF_DATA_DIR 'modules'
                $null = New-Item -ItemType Directory -Path $directory -Force
                Set-Content -LiteralPath (Join-Path $directory 'modules.json') -Value '{"Modules":[]}'
                if ($EnvVars.AVM_TEST_FAIL_GET) {
                    throw [System.InvalidOperationException]::new('module installation failed')
                }
            } -ParameterFilter { $ArgumentList[0] -ceq 'get' }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; Failure = $Failure } {
                param($Fixture, $Failure)
                if ($Failure) {
                    { Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                            -ModuleTargets $Fixture.Targets -Options $Fixture.Options } |
                        Should -Throw '*module installation failed*'
                    Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'providers' }
                }
                else {
                    @(Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                            -ModuleTargets $Fixture.Targets -Options $Fixture.Options) | Should -HaveCount 0
                }
            }
            if ($ExistingLock) {
                Test-Path -LiteralPath $lockPath | Should -BeTrue
                [System.IO.File]::ReadAllBytes($lockPath) | Should -Be $original
            }
            else {
                Test-Path -LiteralPath $lockPath | Should -BeFalse
            }
            [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $manifestBytes
        }

        It 'initializes locked providers only when absent, preserving isolation: <Failure>' -TestCases @(
            @{ Failure = $false }
            @{ Failure = $true }
        ) {
            param($Failure)
            $lockPath = Join-Path $script:fixture.Child '.terraform.lock.hcl'
            [byte[]]$original = @(0, 13, 10, 255)
            [System.IO.File]::WriteAllBytes($lockPath, $original)
            $script:fixture.Options.EnvVars['AVM_TEST_FAIL_INIT'] = $Failure
            $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = "Providers required by configuration:`n."
            Mock Invoke-AvmTerraformInit -ModuleName Avm.Authoring {
                Set-Content -LiteralPath (Join-Path $WorkingDirectory '.terraform.lock.hcl') -Value 'updated lock'
                $null = New-Item -ItemType Directory -Path (Join-Path $EnvVars.TF_DATA_DIR 'providers') -Force
                if ($EnvVars.AVM_TEST_FAIL_INIT) {
                    throw [System.InvalidOperationException]::new('locked initialization failed')
                }
            }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; Failure = $Failure } {
                param($Fixture, $Failure)
                $inspect = {
                    Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options
                }
                if ($Failure) { $inspect | Should -Throw '*locked initialization failed*' }
                else { & $inspect }
                Should -Invoke Invoke-AvmTerraformInit -Exactly 1 -ParameterFilter {
                    $TerraformPath -ceq $Fixture.Options.TerraformPath -and
                    $WorkingDirectory -ceq $Fixture.Child -and
                    $EnvVars.TF_DATA_DIR.StartsWith($Fixture.Options.InspectionRoot + [IO.Path]::DirectorySeparatorChar) -and
                    [bool]$BackendFalse -and [bool]$NoColor -and [bool]$PreserveDependencySelections
                }
                Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'get' }
                Should -Invoke Invoke-AvmProcess -Exactly $(if ($Failure) { 0 } else { 1 }) `
                    -ParameterFilter { $ArgumentList[0] -ceq 'providers' }
            }
            [System.IO.File]::ReadAllBytes($lockPath) | Should -Be $original
            Test-Path -LiteralPath (Join-Path $script:fixture.Child '.terraform') | Should -BeFalse
        }

        It 'accepts an empty configuration tree without including state requirements' {
            InModuleScope Avm.Authoring {
                @(ConvertFrom-AvmTerraformProviderTree `
                    -Text "Providers required by configuration:`n.`n`nProviders required by state:`nprovider[registry.terraform.io/hashicorp/random]" `
                    -Path 'target') | Should -HaveCount 0
            }
        }

        It 'leaves <TargetName> initialization data unchanged: <ExistingData>, <Failure>' -TestCases @(
            foreach ($targetName in @('root', 'setup')) {
                foreach ($existingData in @($false, $true)) {
                    foreach ($failure in @('none', 'get', 'providers')) {
                        @{ TargetName = $targetName; ExistingData = $existingData; Failure = $failure }
                    }
                }
            }
        ) {
            param($TargetName, $ExistingData, $Failure)
            if ($TargetName -ceq 'setup') {
                $script:fixture.Child = Join-Path -Path $script:fixture.Child -ChildPath 'tests' -AdditionalChildPath 'unit', 'setup'
                $script:fixture.Targets[1].Path = $script:fixture.Child
                $null = New-Item -ItemType Directory -Path $script:fixture.Child -Force
            }
            $data = Join-Path $script:fixture.Child '.terraform'
            $lockPath = Join-Path $script:fixture.Child '.terraform.lock.hcl'
            [byte[]]$lockBytes = @(0, 13, 10, 255)
            $original = @{}
            if ($ExistingData) {
                [System.IO.File]::WriteAllBytes($lockPath, $lockBytes)
                foreach ($relative in @('modules/modules.json', 'providers/existing/provider.bin')) {
                    $path = Join-Path $data $relative
                    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
                    [System.IO.File]::WriteAllBytes($path, [byte[]]@(0, 13, 10, 255))
                    $original[$path] = (Get-FileHash -LiteralPath $path).Hash
                }
            }
            $script:fixture.Options.EnvVars['AVM_TEST_FAILURE'] = $Failure
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                $directory = Join-Path $EnvVars.TF_DATA_DIR 'modules'
                $null = New-Item -ItemType Directory -Path $directory -Force
                Set-Content -LiteralPath (Join-Path $directory 'modules.json') -Value '{"Modules":[{"Key":"","Dir":"."}]}'
                [System.IO.File]::WriteAllBytes((Join-Path $EnvVars.TF_DATA_DIR 'provider.bin'), [byte[]]@(1, 2, 3))
                Set-Content -LiteralPath (Join-Path $WorkingDirectory '.terraform.lock.hcl') -Value 'temporary lock'
                if ($EnvVars.AVM_TEST_FAILURE -ceq 'get') {
                    throw [System.InvalidOperationException]::new('inspection get failed')
                }
            } -ParameterFilter { $ArgumentList[0] -ceq 'get' }
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                if ($EnvVars.AVM_TEST_FAILURE -ceq 'providers') {
                    throw [System.InvalidOperationException]::new('inspection providers failed')
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = "Providers required by configuration:`n."; StdErr = '' }
            }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; Failure = $Failure } {
                param($Fixture, $Failure)
                $inspect = {
                    Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options
                }
                if ($Failure -ceq 'none') { & $inspect }
                else { $inspect | Should -Throw "*inspection $Failure failed*" }
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList -join '|' -ceq 'get|-no-color' -and
                    $WorkingDirectory -ceq $Fixture.Child -and
                    $EnvVars.TF_DATA_DIR.StartsWith($Fixture.Options.InspectionRoot + [IO.Path]::DirectorySeparatorChar)
                }
                Should -Invoke Invoke-AvmProcess -Exactly $(if ($Failure -ceq 'get') { 0 } else { 1 }) `
                    -ParameterFilter { $ArgumentList[0] -ceq 'providers' }
                Should -Invoke Invoke-AvmTerraformInit -Exactly 0
            }
            if ($ExistingData) {
                [System.IO.File]::ReadAllBytes($lockPath) | Should -Be $lockBytes
                @(Get-ChildItem -LiteralPath $data -Recurse -File).Count | Should -Be $original.Count
                foreach ($path in $original.Keys) {
                    (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $original[$path]
                }
            }
            else {
                Test-Path -LiteralPath $lockPath | Should -BeFalse
                Test-Path -LiteralPath $data | Should -BeFalse
            }
        }

        It 'carries fresh ModTM records while restoring stale manifest bytes: <Failure>' -TestCases @(
            @{ Failure = 'none' }
            @{ Failure = 'get'; ExpectedError = '*module installation failed*' }
            @{ Failure = 'providers'; ExpectedError = '*missing Terraform configuration tree*' }
            @{ Failure = 'manifest'; ExpectedError = '*not valid JSON*' }
        ) {
            param($Failure, $ExpectedError)
            $manifestPath = Join-Path -Path $script:fixture.Child -ChildPath '.terraform' -AdditionalChildPath 'modules', 'modules.json'
            $dependency = Join-Path $script:fixture.Options.InspectionRoot 'published'
            $null = New-Item -ItemType Directory -Path $dependency, (Split-Path -Parent $manifestPath) -Force
            Set-Content -LiteralPath (Join-Path $dependency 'main.tf') -Value 'terraform {}'
            Set-Content -LiteralPath (Join-Path $script:fixture.Child 'main.tf') -Encoding utf8NoBOM `
                -Value 'module "published" { source = "Azure/example/azurerm" }'
            [byte[]]$manifestBytes = [System.Text.Encoding]::UTF8.GetBytes(
                "{`r`n  `"Modules`": [{`"Key`":`"`",`"Dir`":`".`"},{`"Key`":`"existing`",`"Dir`":`".terraform/modules/existing`",`"Version`":`"0.1.0`"}]`r`n}`r`n")
            [System.IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
            $lockPath = Join-Path $script:fixture.Child '.terraform.lock.hcl'
            [byte[]]$lockBytes = @(1, 2, 3, 13, 10)
            [System.IO.File]::WriteAllBytes($lockPath, $lockBytes)
            $null = New-Item -ItemType Directory -Path (
                Join-Path -Path $script:fixture.Child -ChildPath '.terraform' -AdditionalChildPath 'providers') -Force
            $script:fixture.Options.EnvVars['AVM_TEST_FRESH_MANIFEST'] = @{
                Modules = @(
                    @{ Key = ''; Dir = '.' }
                    @{ Key = 'existing'; Dir = '.terraform/modules/existing'; Version = '0.1.0' }
                    @{ Key = 'published'; Dir = $dependency; Source = 'registry.terraform.io/Azure/example/azurerm'; Version = '0.1.0' }
                )
            } | ConvertTo-Json -Depth 5 -Compress
            $script:fixture.Options.EnvVars['AVM_TEST_FAILURE'] = $Failure
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                $payload = if ($EnvVars.AVM_TEST_FAILURE -ceq 'manifest') { 'invalid JSON' } else { $EnvVars.AVM_TEST_FRESH_MANIFEST }
                $directory = Join-Path $EnvVars.TF_DATA_DIR 'modules'
                $null = New-Item -ItemType Directory -Path $directory -Force
                Set-Content -LiteralPath (Join-Path $directory 'modules.json') -Value $payload -Encoding utf8NoBOM -NoNewline
                Set-Content -LiteralPath (Join-Path $WorkingDirectory '.terraform.lock.hcl') -Value 'updated lock'
                if ($EnvVars.AVM_TEST_FAILURE -ceq 'get') {
                    throw [System.InvalidOperationException]::new('module installation failed')
                }
            } -ParameterFilter { $ArgumentList[0] -ceq 'get' }
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                $text = if ($ArgumentList[0] -ceq 'providers') {
                    if ($EnvVars.AVM_TEST_FAILURE -ceq 'providers') { 'invalid tree' }
                    else {
                        "Providers required by configuration:`n.`n" +
                        "`u{2514}`u{2500}`u{2500} module.published`n" +
                        "    `u{2514}`u{2500}`u{2500} provider[registry.terraform.io/azure/modtm] 0.3.5`n"
                    }
                }
                else { '{"published":{"source":"Azure/example/azurerm","mptf":{}}}' }
                [pscustomobject]@{ ExitCode = 0; StdOut = $text; StdErr = '' }
            }
            Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                @{ modtm = @{ source = 'Azure/modtm'; version = '= 0.3.5' } }
            }
            InModuleScope Avm.Authoring -Parameters @{
                Fixture = $script:fixture; Failure = $Failure; ExpectedError = $ExpectedError
                ManifestPath = $manifestPath; OriginalManifest = $manifestBytes
            } {
                param($Fixture, $Failure, $ExpectedError, $ManifestPath, $OriginalManifest)
                $modules = @{ $Fixture.Child = @{} }
                $manifests = @{}
                $inspect = {
                    @(Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child -ModuleTargets $Fixture.Targets `
                            -Options $Fixture.Options -ModuleProviderSources $modules[$Fixture.Child] -ModuleManifests $manifests)
                }
                if ($Failure -cne 'none') {
                    $inspect | Should -Throw $ExpectedError
                    $manifests.Count | Should -Be 0
                }
                else {
                    $sources = & $inspect
                    $manifests[$Fixture.Child] | Should -BeOfType ([string])
                    $manifests[$Fixture.Child] | Should -BeExactly $Fixture.Options.EnvVars.AVM_TEST_FRESH_MANIFEST
                    [System.IO.File]::ReadAllBytes($ManifestPath) | Should -Be $OriginalManifest
                    (Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json).Modules.Key | Should -Not -Contain 'published'
                    $parameters = @{
                        Path                  = $Fixture.Child
                        ModuleTargets         = $Fixture.Targets
                        Options               = $Fixture.Options
                        RequiredProviders     = @{ $Fixture.Child = @{} }
                        ProviderSources       = @{ $Fixture.Child = $sources }
                        ModuleProviderSources = $modules
                        OriginalRequirements  = @{ $Fixture.Child = @{ modtm = @{ source = 'Azure/modtm'; version = '~> 0.3' } } }
                        Plans                 = @{}
                        PlanningPaths         = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                    }
                    { Get-AvmTerraformUnitTestModtmRequirementPlan @parameters -ModuleManifests @{} } |
                        Should -Throw '*freshly inspected dependency manifest is missing*'
                    $plan = Get-AvmTerraformUnitTestModtmRequirementPlan @parameters -ModuleManifests $manifests
                    $plan.Arguments | Should -Contain 'unit_test_modtm_bindings={"published":"{ modtm = modtm }"}'
                    $parameters.RequiredProviders[$Fixture.Child].modtm.source | Should -BeExactly 'Azure/modtm'
                    $parameters.RequiredProviders[$Fixture.Child].modtm.version | Should -BeExactly '~> 0.3'
                    $manifests[$Fixture.Child] | Should -BeExactly $Fixture.Options.EnvVars.AVM_TEST_FRESH_MANIFEST
                }
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList -join '|' -ceq 'get|-no-color' -and [bool]$RetryNetworkFailure -and
                    $WorkingDirectory -ceq $Fixture.Child
                }
                Should -Invoke Invoke-AvmTerraformInit -Exactly 0
            }
            [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $manifestBytes
            [System.IO.File]::ReadAllBytes($lockPath) | Should -Be $lockBytes
        }

        It 'rejects incomplete or unfamiliar tree output: <Shape>' -TestCases @(
            @{ Shape = 'no configuration header'; Text = '.' }
            @{ Shape = 'no root'; Text = 'Providers required by configuration:' }
            @{ Shape = 'unknown node'; Text = "Providers required by configuration:`n.`n    unexpected.node" }
            @{ Shape = 'incorrect depth'; Text = "Providers required by configuration:`n.`n  provider[registry.terraform.io/hashicorp/random]" }
            @{ Shape = 'invalid address'; Text = "Providers required by configuration:`n.`n    provider[random]" }
            @{ Shape = 'unexpected run'; Text = "Providers required by configuration:`n.`n    run.other" }
        ) {
            param($Text)
            InModuleScope Avm.Authoring -Parameters @{ Text = $Text } {
                param($Text)
                { ConvertFrom-AvmTerraformProviderTree -Text $Text -Path 'target' } |
                    Should -Throw '*Cannot inspect provider dependencies*'
            }
        }

        It 'synthesizes only proven ModTM version constraints: <Case>' -TestCases @(
            @{ Case = 'unchanged published dependency'; Versions = @('= 0.3.5'); Expected = '= 0.3.5' }
            @{ Case = 'known local target'; Versions = @('~> 0.3'); Expected = '~> 0.3'; LocalTarget = $true }
            @{ Case = 'already complete module binding'; Versions = @('= 0.3.5'); Expected = '= 0.3.5'; Bound = $true }
            @{ Case = 'duplicate constraints'; Versions = @('>= 0.3.5', '>= 0.3.5'); Expected = '>= 0.3.5' }
            @{ Case = 'intersected constraints'; Versions = @('>= 0.3.5', '< 0.4.0'); Expected = '< 0.4.0, >= 0.3.5' }
            @{ Case = 'original version precedence'; Versions = @('= 0.3.5'); Expected = '~> 0.3'; OriginalVersion = '~> 0.3' }
            @{ Case = 'blank original version'; Versions = @('= 0.3.5'); Expected = '= 0.3.5'; OriginalVersion = ' ' }
            @{ Case = 'unrelated provider exclusion'; Versions = @('= 0.3.5'); Expected = '= 0.3.5'; Unrelated = $true }
            @{ Case = 'authored versionless requirement'; Versions = @('= 0.3.5'); Existing = $true }
            @{ Case = 'missing version proof'; Versions = @($null); Reject = $true }
            @{ Case = 'whitespace version'; Versions = @(' '); Reject = $true }
            @{ Case = 'nonliteral version'; Versions = @(42); Reject = $true }
            @{ Case = 'computed version'; Versions = @('${var.version}'); Reject = $true }
        ) {
            param($Versions, $Expected, $LocalTarget = $false, $Bound = $false, $OriginalVersion,
                $Unrelated = $false, $Existing = $false, $Reject = $false)
            $caller = $script:fixture.Child
            $source = 'registry.terraform.io/azure/modtm'
            $required = @{ $caller = @{} }
            $modules = @{ $caller = @{} }
            $calls = @{}
            $records = [System.Collections.Generic.List[object]]::new()
            $records.Add(@{ Key = ''; Dir = '.' })
            for ($index = 0; $index -lt $Versions.Count; $index++) {
                $name = "dependency$index"
                $dependency = if ($LocalTarget) {
                    $script:fixture.Root
                }
                else {
                    Join-Path -Path $caller -ChildPath '.terraform' -AdditionalChildPath 'modules', $name
                }
                $null = New-Item -ItemType Directory -Path $dependency -Force
                $required[$dependency] = @{ modtm = @{ source = 'Azure/modtm' } }
                if ($null -ne $Versions[$index]) { $required[$dependency].modtm.version = $Versions[$index] }
                $modules[$caller][$name] = @($source)
                $calls[$name] = @{ source = 'Azure/example/azurerm'; mptf = @{} }
                if ($Bound) { $calls[$name].providers = '{ modtm = modtm }' }
                $records.Add(@{ Key = $name; Dir = $dependency; Version = '0.1.0' })
            }
            if ($Unrelated) {
                $modules[$caller].unrelated = @('registry.terraform.io/hashicorp/random')
                $calls.unrelated = @{ source = 'Azure/unrelated/azurerm'; mptf = @{} }
            }
            $original = @{}
            if ($OriginalVersion) {
                $original[$caller] = @{ modtm = @{ source = 'Azure/modtm'; version = $OriginalVersion } }
            }
            if ($Existing) {
                $required[$caller].modtm = @{ source = 'Azure/modtm' }
            }
            $parameters = @{
                Path = $caller
                ModuleTargets = $script:fixture.Targets
                Options = $script:fixture.Options
                RequiredProviders = $required
                ProviderSources = @{ $caller = @($source) }
                ModuleProviderSources = $modules
                ModuleManifests = @{ $caller = (ConvertTo-Json -InputObject @{ Modules = $records.ToArray() } -Depth 5 -Compress) }
                OriginalRequirements = $original
                Plans = @{}
                PlanningPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                BindDependencies = $true
            }
            $script:fixture.Options.EnvVars['AVM_TEST_MODTM_CALLS'] = ConvertTo-Json -InputObject $calls -Depth 5 -Compress
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                [pscustomobject]@{ ExitCode = 0; StdOut = $EnvVars.AVM_TEST_MODTM_CALLS; StdErr = '' }
            }
            InModuleScope Avm.Authoring -Parameters @{
                Parameters = $parameters; Expected = $Expected; Reject = $Reject; Caller = $caller
            } {
                param($Parameters, $Expected, $Reject, $Caller)
                if ($Reject) {
                    { Get-AvmTerraformUnitTestModtmRequirementPlan @Parameters } |
                        Should -Throw '*version constraint*requires review*'
                    $Parameters.Plans.Count | Should -Be 0
                    $Parameters.RequiredProviders[$Caller].Contains('modtm') | Should -BeFalse
                }
                else {
                    $plan = Get-AvmTerraformUnitTestModtmRequirementPlan @Parameters
                    $encoded = @($plan.Arguments | Where-Object { $_ -like 'unit_test_modtm_requirement=*' })[0].
                        Substring('unit_test_modtm_requirement='.Length)
                    $requirement = ConvertFrom-Json -InputObject $encoded -AsHashtable
                    $requirement['version'] | Should -BeExactly $Expected
                    $Parameters.RequiredProviders[$Caller].modtm['version'] | Should -BeExactly $Expected
                    $requirement.source | Should -BeIn @('Azure/modtm', 'registry.terraform.io/azure/modtm')
                }
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -ceq 'debug' }
                Should -Invoke Invoke-AvmTerraformInit -Exactly 0
            }
        }

        It 'matches declared provider sources and inferred HashiCorp names without unrelated mocks' {
            InModuleScope Avm.Authoring {
                $result = @(Get-AvmTerraformUnitTestMockProviderName `
                    -ProviderNames @('azapi', 'azapi.alternate', 'random', 'time', 'custom') `
                    -RequiredProviders @{
                        azapi = @{ source = 'Azure/azapi' }
                        custom = @{ source = 'example.com/team/custom' }
                    } `
                    -ProviderSources @(
                        'registry.terraform.io/azure/azapi',
                        'registry.terraform.io/hashicorp/random',
                        'example.com/team/custom'
                    ))
                $result | Should -Be @('azapi', 'azapi.alternate', 'random', 'custom')
            }
        }

        It 'never infers a HashiCorp source for a transitive ModTM mock' {
            InModuleScope Avm.Authoring {
                { Get-AvmTerraformUnitTestMockProviderName -ProviderNames @('modtm') -RequiredProviders @{} `
                        -ProviderSources @('registry.terraform.io/azure/modtm') } |
                    Should -Throw '*proven explicit Azure/modtm source*'
                @(Get-AvmTerraformUnitTestMockProviderName -ProviderNames @('modtm') -RequiredProviders @{} `
                        -ProviderSources @('registry.terraform.io/hashicorp/modtm')) | Should -HaveCount 0
            }
        }

        It 'groups configuration providers by their direct module call without tests or state' {
            InModuleScope Avm.Authoring {
                $text = "Providers required by configuration:`n.`n" +
                "`u{251c}`u{2500}`u{2500} module.published`n" +
                "`u{2502}   `u{2514}`u{2500}`u{2500} module.interfaces`n" +
                "`u{2502}       `u{2514}`u{2500}`u{2500} provider[registry.terraform.io/azure/modtm] 0.3.5`n" +
                "`u{251c}`u{2500}`u{2500} test.tests/other`n" +
                "`u{2502}   `u{2514}`u{2500}`u{2500} provider[registry.terraform.io/hashicorp/random]`n" +
                "`u{2514}`u{2500}`u{2500} provider[registry.terraform.io/azure/azapi]`n"
                $modules = @{}
                $sources = @(ConvertFrom-AvmTerraformProviderTree -Text $text -Path target -ModuleProviderSources $modules)
                $sources | Should -HaveCount 2
                $modules.Keys | Should -Be @('published')
                @($modules.published) | Should -Be @('registry.terraform.io/azure/modtm')
            }
        }
    }

    Context 'complete mock mappings' {
        It 'validates the complete native HCL mapping: <Shape>' -TestCases @(
            @{ Shape = 'same-name bindings'; Expression = '{ azapi = azapi, random = random }'; Valid = $true }
            @{ Shape = 'quoted keys and comments'; Expression = "{`n# keep`n`"random`" = random, /* keep */ azapi = azapi`n}"; Valid = $true }
            @{ Shape = 'partial bindings'; Expression = '{ azapi = azapi }'; Valid = $false }
            @{ Shape = 'remapped binding'; Expression = '{ azapi = azapi.alternate, random = random }'; Valid = $false }
            @{ Shape = 'different provider'; Expression = '{ azapi = random, random = random }'; Valid = $false }
            @{ Shape = 'aliased key'; Expression = '{ azapi.alternate = azapi, random = random }'; Valid = $false }
            @{ Shape = 'additional binding'; Expression = '{ azapi = azapi, random = random, time = time }'; Valid = $false }
            @{ Shape = 'duplicate binding'; Expression = '{ azapi = azapi, random = random, random = random }'; Valid = $false }
            @{ Shape = 'literal rather than reference'; Expression = '{ azapi = "azapi", random = random }'; Valid = $false }
            @{ Shape = 'trailing expression'; Expression = '{ azapi = azapi, random = random } + {}'; Valid = $false }
            @{ Shape = 'computed object'; Expression = 'merge(var.providers, { random = random })'; Valid = $false }
            @{ Shape = 'empty object'; Expression = '{}'; Valid = $false }
            @{ Shape = 'incorrect native representation'; Expression = @{ azapi = 'azapi'; random = 'random' }; Valid = $false }
        ) {
            param($Expression, $Valid)
            InModuleScope Avm.Authoring -Parameters @{ Expression = $Expression; Valid = $Valid } {
                param($Expression, $Valid)
                $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $Expression -ProviderNames @('azapi', 'random')
                ($null -ne $mapping) | Should -Be $Valid
                if ($Valid) {
                    $mapping.Expression | Should -BeExactly $Expression
                    $mapping.Changed | Should -BeFalse
                }
            }
        }

        It 'preserves complete bindings to a known same-provider alias' {
            InModuleScope Avm.Authoring {
                $expression = '{ azapi = azapi.alternate, random = random }'
                $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $expression `
                    -ProviderNames @('azapi', 'random') -MockProviderNames @('azapi', 'azapi.alternate', 'random')
                $mapping.Expression | Should -BeExactly $expression
                $mapping.Changed | Should -BeFalse
            }
        }

        It 'retires only proven unused same-provider alias bindings' {
            InModuleScope Avm.Authoring {
                $expression = '{ azapi = azapi.unit, modtm = modtm.unit, random = random.unit }'
                $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $expression `
                    -ProviderNames @('azapi') -MockProviderNames @('azapi.unit', 'modtm.unit', 'random.unit') `
                    -RetiredProviderNames @('modtm', 'random')
                $mapping.Expression | Should -BeExactly '{ azapi = azapi.unit,       }'
                $mapping.RetiredReferences.modtm | Should -Be 1
                $mapping.RetiredReferences.random | Should -Be 1
                $mapping.Bindings['azapi'] | Should -BeExactly 'azapi.unit'
                $invalid = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression '{ azapi = azapi.unit, modtm = azapi.unit }' `
                    -ProviderNames @('azapi') -MockProviderNames @('azapi.unit') -RetiredProviderNames @('modtm')
                $invalid | Should -BeNullOrEmpty
            }
        }

        Context 'literal mock alias metadata' {
            It 'recognizes alias-only mocks without treating them as unaliased defaults: <Provider>' -TestCases @(
                @{ Provider = 'azapi' }
                @{ Provider = 'azurerm' }
                @{ Provider = 'modtm' }
                @{ Provider = 'random' }
            ) {
                param($Provider)
                $mock = New-UnitProviderAlias -Provider $Provider
                InModuleScope Avm.Authoring -Parameters @{ Provider = $Provider; MockData = $mock } {
                    param($Provider, $MockData)
                    $aliases = Get-AvmTerraformUnitTestMockAlias -Test @{ mock_providers = @{ "$Provider.unit" = $MockData } } -Path fixture
                    $aliases["$Provider.unit"] | Should -BeTrue
                    $aliases.ContainsKey($Provider) | Should -BeFalse
                }
            }

            It 'does not classify a customized or source-backed alias as removable' -TestCases @(
                @{ Shape = 'source' }
                @{ Shape = 'defaults' }
            ) {
                param($Shape)
                $mock = New-UnitProviderAlias -Provider random
                if ($Shape -eq 'source') { $mock.mptf.attributes.source = 'tests/mocks' }
                else { $mock.mock_resource = @(@{ mptf = @{ block_labels = @('random_string') } }) }
                InModuleScope Avm.Authoring -Parameters @{ MockData = $mock } {
                    param($MockData)
                    (Get-AvmTerraformUnitTestMockAlias -Test @{ mock_providers = @{ 'random.unit' = $MockData } } -Path fixture)['random.unit'] |
                        Should -BeFalse
                }
            }

            It 'rejects inconsistent or computed alias identity: <Invalid>' -TestCases @(
                @{ Invalid = 'address' }
                @{ Invalid = 'alias' }
                @{ Invalid = 'labels' }
                @{ Invalid = 'type' }
                @{ Invalid = 'source' }
            ) {
                param($Invalid)
                $mock = New-UnitProviderAlias -Provider azurerm
                switch ($Invalid) {
                    address { $mock.mptf.block_address = 'mock_provider.azurerm' }
                    alias { $mock.mptf.attributes.alias = '${var.alias}' }
                    labels { $mock.mptf.block_labels = @('azapi') }
                    type { $mock.mptf.block_type = 'provider' }
                    source { $mock.mptf.attributes.source = '${var.source}' }
                }
                {
                    InModuleScope Avm.Authoring -Parameters @{ MockData = $mock } {
                        param($MockData)
                        Get-AvmTerraformUnitTestMockAlias -Test @{ mock_providers = @{ 'azurerm.unit' = $MockData } } -Path fixture
                    }
                } | Should -Throw '*Cannot automatically migrate unit test*'
            }
        }

        Context 'literal source-backed client defaults' {
            BeforeEach {
                $script:sourceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                $script:sourceDir = Join-Path $script:sourceRoot 'tests' 'mocks'
                $null = New-Item -ItemType Directory -Path $script:sourceDir -Force
                Set-Content -LiteralPath (Join-Path $script:sourceDir 'client.tfmock.hcl') -Encoding utf8NoBOM `
                    -Value 'mock_data "azapi_client_config" { defaults = { subscription_id = "11111111-1111-1111-1111-111111111111" } }'
                $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] =
                    '{"mptf":{"attributes":{}},"mock_data":[{"mptf":{"block_labels":["azapi_client_config"],"attributes":{"defaults":{"subscription_id":"11111111-1111-1111-1111-111111111111","tenant_id":"22222222-2222-2222-2222-222222222222"}}}}]}'
                Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                    $json = $EnvVars.AVM_TEST_INSPECTION_JSON
                    if ($json -ne 'not JSON') {
                        $metadata = ConvertFrom-Json -InputObject $json -AsHashtable
                        $content = [System.IO.File]::ReadAllText((Join-Path $WorkingDirectory 'source.tftest.hcl'))
                        $metadata.mptf.range = @{
                            start_line = 1
                            end_line = @($content.TrimEnd() -split '\r?\n').Count
                        }
                        $json = ConvertTo-Json -InputObject $metadata -Depth 30 -Compress
                    }
                    [pscustomobject]@{ ExitCode = 0; StdOut = $json; StdErr = '' }
                }
            }

            It 'reflects local source defaults natively without changing their original bytes' {
                $file = Join-Path $script:sourceDir 'client.tfmock.hcl'
                $bytes = [System.IO.File]::ReadAllBytes($file)
                InModuleScope Avm.Authoring -Parameters @{ Root = $script:sourceRoot; Options = $script:fixture.Options } {
                    param($Root, $Options)
                    $defaults = Get-AvmTerraformSourceMockClientDefault -Source 'tests/mocks' -ModuleRoot $Root -Path fixture -Options $Options
                    $defaults.subscription_id | Should -BeExactly '11111111-1111-1111-1111-111111111111'
                    $defaults.tenant_id | Should -BeExactly '22222222-2222-2222-2222-222222222222'
                    Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                        $ArgumentList[0] -ceq 'debug' -and $ArgumentList -ccontains 'source.tftest.hcl' -and
                        $ArgumentList[-1] -ceq 'data.test_file.this.result.mock_providers.azapi'
                    }
                }
                [System.IO.File]::ReadAllBytes($file) | Should -Be $bytes
            }

            It 'rejects unsafe or missing source paths before invoking the parser: <Source>' -TestCases @(
                @{ Source = '../outside' }
                @{ Source = 'missing' }
                @{ Source = '${var.source}' }
                @{ Source = 'https://example.com/mocks' }
            ) {
                param($Source)
                {
                    InModuleScope Avm.Authoring -Parameters @{ Root = $script:sourceRoot; Options = $script:fixture.Options; Source = $Source } {
                        param($Root, $Options, $Source)
                        Get-AvmTerraformSourceMockClientDefault -Source $Source -ModuleRoot $Root -Path fixture -Options $Options
                    }
                } | Should -Throw '*Cannot automatically migrate unit test*'
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }

            It 'retains explicit rejection for ambiguous source metadata: <Shape>' -TestCases @(
                @{ Shape = 'computed'; Json = '{"mptf":{"attributes":{}},"mock_data":[{"mptf":{"block_labels":["azapi_client_config"],"attributes":{"defaults":"${var.defaults}"}}}]}' }
                @{ Shape = 'duplicate'; Json = '{"mptf":{"attributes":{}},"mock_data":[{"mptf":{"block_labels":["azapi_client_config"],"attributes":{"defaults":{}}}},{"mptf":{"block_labels":["azapi_client_config"],"attributes":{"defaults":{}}}}]}' }
                @{ Shape = 'override'; Json = '{"mptf":{"attributes":{}},"override_data":[]}' }
                @{ Shape = 'malformed'; Json = '{"mptf":{"attributes":{}},"mock_data":[{}]}' }
                @{ Shape = 'invalid JSON'; Json = 'not JSON' }
            ) {
                param($Json)
                $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = $Json
                {
                    InModuleScope Avm.Authoring -Parameters @{ Root = $script:sourceRoot; Options = $script:fixture.Options } {
                        param($Root, $Options)
                        Get-AvmTerraformSourceMockClientDefault -Source 'tests/mocks' -ModuleRoot $Root -Path fixture -Options $Options
                    }
                } | Should -Throw '*source-based mock*'
            }
        }

        It 'removes only proven retired bindings while retaining every comment and remaining expression' {
            InModuleScope Avm.Authoring {
                $expression = @'
{
  # ${literal} and %{directive} remain comments.
  azapi = azapi.alternate /* retained */,
  "modtm" /* middle */ = /* before value */ modtm, // end
  random = random # final
}
'@
                $expected = @'
{
  # ${literal} and %{directive} remain comments.
  azapi = azapi.alternate /* retained */,
   /* middle */  /* before value */  // end
     # final
}
'@
                $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $expression `
                    -ProviderNames @('azapi') -MockProviderNames @('azapi.alternate', 'modtm', 'random') `
                    -RetiredProviderNames @('modtm', 'random')
                $mapping.Expression | Should -BeExactly $expected
                $mapping.Changed | Should -BeTrue
                $mapping.RetiredReferences.modtm | Should -Be 1
                $mapping.RetiredReferences.random | Should -Be 1
                $repeat = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $mapping.Expression `
                    -ProviderNames @('azapi') -MockProviderNames @('azapi.alternate')
                $repeat.Changed | Should -BeFalse
                $repeat.Expression | Should -BeExactly $expected
            }
        }
    }

    Context 'scope discovery' {
        BeforeEach {
            Mock Get-AvmTerraformFile -ModuleName Avm.Authoring {
                foreach ($relative in @(
                        @('tests', 'unit', 'root.tftest.hcl'),
                        @('modules', 'child', 'tests', 'unit', 'child.tftest.hcl'),
                        @('tests', 'integration', 'integration.tftest.hcl'),
                        @('tests', 'unit', 'nested', 'nested.tftest.hcl'))) {
                    [pscustomobject]@{
                        Name     = $relative[-1]
                        FullName = [System.IO.Path]::Combine([string[]](@($Root) + $relative))
                    }
                }
            }
            Mock Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring {
                @{ inspected = $Scope.RelativePath; test = @{ mock_providers = @{} } }
            }
        }

        It 'uses the nearest module owner and only snapshots direct unit test files' {
            $result = InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                @(Get-AvmTerraformUnitTestSnapshot -Root $Fixture.Root -ModuleTargets $Fixture.Targets -Options $Fixture.Options)
            }
            $result | Should -HaveCount 2
            $result[0].Scope.Owner.Path | Should -BeExactly $script:fixture.Root
            $result[1].Scope.Owner.Path | Should -BeExactly $script:fixture.Child
            $result[1].Scope.RelativePath | Should -BeExactly 'tests/unit/child.tftest.hcl'
            $result[1].Hash | Should -BeExactly 'before'
            $result[1].Before.inspected | Should -BeExactly 'tests/unit/child.tftest.hcl'
            Should -Invoke Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring -Exactly 2
        }

        It 'inspects standalone test targets without treating them as file owners' {
            $testTarget = [pscustomobject]@{
                Path     = Join-Path $script:fixture.Root 'tests' 'unit'
                Scope    = 'test'
                Profiles = @('module-call', 'variable-order', 'provider-cleanup', 'test')
            }
            $script:fixture.Targets += $testTarget
            $result = InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                @(Get-AvmTerraformUnitTestSnapshot -Root $Fixture.Root -ModuleTargets $Fixture.Targets -Options $Fixture.Options)
            }
            $result | Should -HaveCount 2
            $result[0].Scope.Owner.Path | Should -BeExactly $script:fixture.Root
            $result[0].Scope.IsUnitTest | Should -BeTrue
            Should -Invoke Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring -Exactly 2 -ParameterFilter {
                @($ModuleTargets | Where-Object Scope -EQ 'test').Count -eq 1
            }
        }

        It 'does not promote an example to a unit-test file owner' {
            $script:fixture.Targets += [pscustomobject]@{
                Path     = Join-Path $script:fixture.Root 'examples' 'default'
                Scope    = 'example'
                Profiles = @('example', 'provider-cleanup', 'common')
            }
            Mock Get-AvmTerraformFile -ModuleName Avm.Authoring {
                [pscustomobject]@{
                    Name     = 'example.tftest.hcl'
                    FullName = [System.IO.Path]::Combine($Root, 'examples', 'default', 'tests', 'unit', 'example.tftest.hcl')
                }
            }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                $scope = @(Get-AvmTerraformTestFileScope -Root $Fixture.Root -ModuleTargets $Fixture.Targets)
                $scope | Should -HaveCount 1
                $scope[0].Owner.Path | Should -BeExactly $Fixture.Root
                $scope[0].IsUnitTest | Should -BeFalse
                @(Get-AvmTerraformUnitTestSnapshot -Root $Fixture.Root `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options) | Should -HaveCount 0
            }
            Should -Invoke Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring -Exactly 0
        }

        It 'rejects a path outside every known owner' {
            Mock Get-AvmTerraformFile -ModuleName Avm.Authoring {
                [pscustomobject]@{ Name = 'outside.tftest.hcl'; FullName = $Root + '-outside.tftest.hcl' }
            }
            {
                InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                    param($Fixture)
                    Get-AvmTerraformTestFileScope -Root $Fixture.Root -ModuleTargets $Fixture.Targets
                }
            } | Should -Throw '*Cannot determine the Terraform module*'
        }
    }

    Context 'telemetry identifier assertions' {
        It 'recognizes only supported telemetry count assertions: <Condition>' -TestCases @(
            @{ Condition = 'length(random_uuid.telemetry) == 0'; Count = 1 }
            @{ Condition = 'length(random_uuid.telemetry) == 1'; Count = 1 }
            @{ Condition = "length (`n random_uuid.telemetry `n) == 1"; Count = 1 }
            @{ Condition = 'length(modtm_telemetry.telemetry) == 0 && length(random_uuid.telemetry) == 0'; Count = 1 }
            @{ Condition = 'length(modtm_telemetry.telemetry)==1&&length(random_uuid.telemetry)==1'; Count = 1 }
            @{ Condition = "length(azapi_resource.telemetry) == 1 &&`n length (`n random_uuid.telemetry `n) == 1"; Count = 1 }
            @{ Condition = 'length(modtm_telemetry.telemetry) == 0 && length(random_uuid.telemetry) == 1'; Count = 1 }
            @{ Condition = 'length(random_uuid.telemetry) == 10'; Count = 0 }
            @{ Condition = 'length(random_uuid.telemetry) == 1 && var.enabled'; Count = 0 }
            @{ Condition = 'length(modtm_telemetry.telemetry) == 0 || length(random_uuid.telemetry) == 0'; Count = 0 }
            @{ Condition = 'length(random_uuid.telemetry) == 0 && length(modtm_telemetry.telemetry) == 0'; Count = 0 }
            @{ Condition = 'length(modtm_telemetry.other) == 0 && length(random_uuid.telemetry) == 0'; Count = 0 }
            @{ Condition = 'length(modtm_telemetry.telemetry) == 0 && length(random_uuid.telemetry) == 0 && var.enabled'; Count = 0 }
            @{ Condition = '"length(modtm_telemetry.telemetry) == 0 && length(random_uuid.telemetry) == 0"'; Count = 0 }
            @{ Condition = 'length(random_uuid.telemetry[0].result) == 36'; Count = 0 }
            @{ Condition = 'one(random_uuid.telemetry).result != ""'; Count = 0 }
            @{ Condition = 'length(random_uuid.telemetry_other) == 1'; Count = 0 }
            @{ Condition = '"length(random_uuid.telemetry) == 1"'; Count = 0 }
        ) {
            param($Condition, $Count)
            $script:fixture.After.test.runs.root.assert = @(@{ mptf = @{ attributes = @{ condition = $Condition } } })
            $result = InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                Get-AvmTerraformTelemetryTestCountMigration -Test $Fixture.After.test -ModuleTargets $Fixture.Targets
            }
            $result.ReferenceCount | Should -Be $Count
            $result.Replacement | Should -BeExactly '${1}terraform_data.telemetry${2}'
            if ($Count -eq 1) {
                [regex]::Replace($Condition.Trim(), $result.Pattern, $result.Replacement) |
                    Should -BeExactly $Condition.Trim().Replace('random_uuid.telemetry', 'terraform_data.telemetry')
            }
        }

        It 'does not migrate assertions belonging to an uninstrumented selected target' {
            $script:fixture.Targets[1].Profiles = @('module', 'common')
            foreach ($run in $script:fixture.After.test.runs.Values) {
                $run.assert = @(@{ mptf = @{ attributes = @{
                                condition = 'length(modtm_telemetry.telemetry) == 0 && length(random_uuid.telemetry) == 0'
                            } } })
            }
            $result = InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                Get-AvmTerraformTelemetryTestCountMigration -Test $Fixture.After.test -ModuleTargets $Fixture.Targets
            }
            $result.ReferenceCount | Should -Be 1
        }

        It 'reports malformed assertion inspection explicitly' {
            $script:fixture.After.test.runs.root.assert = @(@{})
            {
                InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                    param($Fixture)
                    Get-AvmTerraformTelemetryTestCountMigration -Test $Fixture.After.test -ModuleTargets $Fixture.Targets
                }
            } | Should -Throw '*Cannot inspect telemetry assertions*'
        }
    }

    Context 'migration decisions' {
        BeforeEach {
            Mock Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring { $Scope.Inspection }
            Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                @{ azapi = @{ source = 'Azure/azapi' } }
            }
            Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                @('registry.terraform.io/azure/azapi')
            }
        }

        It 'migrates newly required root and child locations with selected-file cleanup' {
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -Exactly 1 -ParameterFilter {
                    $UnitTestPlans.Count -eq 1 -and
                    $UnitTestPlans[0].TargetPaths.Count -eq 2 -and
                    $UnitTestPlans[0].TargetPaths -ccontains $Fixture.Child
                }
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList[0] -eq 'transform' -and
                    $ArgumentList[2] -ceq $Fixture.Root -and
                    $ArgumentList[4] -ceq $Fixture.Scope.RelativePath -and
                    $ArgumentList[6] -ceq $Fixture.Options.ProfileDirs['unit-test'] -and
                    @(($ArgumentList[8] -replace '^new_location_modules=', '' | ConvertFrom-Json)).Count -eq 2
                }
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList -join '|' -ceq ('clean-backup|--tf-dir|' + $Fixture.Root +
                        '|--test-file|' + $Fixture.Scope.RelativePath)
                }
            }
        }

        It 'accounts for retired identifier assertions and verifies their exact native rule' {
            foreach ($run in $script:fixture.After.test.runs.Values) {
                $run.assert = @(@{ mptf = @{ attributes = @{
                                condition = 'length(modtm_telemetry.telemetry) == 0 && length(random_uuid.telemetry) == 0'
                            } } })
            }
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
            } -ParameterFilter { $ArgumentList[0] -eq 'debug' }
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                $UnitTestPlans[0].TelemetryCountMigration.ReferenceCount -eq 2 -and
                $UnitTestPlans[0].RetiredProviderReferences.random -eq 2 -and
                $UnitTestPlans[0].MockMigrationValidated
            }
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'debug' -and
                $ArgumentList -ccontains 'migrate_telemetry_counts=true' -and
                $ArgumentList[-1].Contains('telemetry_counts["counts"].regex') -and
                $ArgumentList[-1].Contains('telemetry_counts["counts"].replacement')
            }
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'transform' -and $ArgumentList -ccontains 'migrate_telemetry_counts=true'
            }
        }

        It 'rejects an unsupported count rule before cleanup: <Response>' -TestCases @(
            @{ Response = 'false' }
            @{ Response = '{}' }
            @{ Response = 'invalid JSON' }
        ) {
            param($Response)
            $script:fixture.After.test.runs.root.assert = @(
                @{ mptf = @{ attributes = @{ condition = 'length(random_uuid.telemetry) == 1' } } })
            $script:fixture.Options.EnvVars['AVM_TEST_CAPABILITY_RESPONSE'] = $Response
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                [pscustomobject]@{ ExitCode = 0; StdOut = $EnvVars['AVM_TEST_CAPABILITY_RESPONSE']; StdErr = '' }
            } -ParameterFilter { $ArgumentList[0] -eq 'debug' }
            { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*telemetry count assertions*'
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
                $ArgumentList[0] -in @('transform', 'clean-backup')
            }
        }

        It 'rejects unsupported identifier use before retiring any alias or backup' {
            $script:fixture.After.test.mock_providers = @{
                'azapi.unit' = New-CustomTelemetryMock -Alias unit -Defaults @{ subscription_resource_id = '/subscriptions/00000000-0000-0000-0000-000000000000' }
                'modtm.unit' = New-UnitProviderAlias -Provider modtm
                'random.unit' = New-UnitProviderAlias -Provider random
            }
            foreach ($run in $script:fixture.After.test.runs.Values) {
                $run.mptf.attributes.providers = '{ azapi = azapi.unit, modtm = modtm.unit, random = random.unit }'
            }
            $script:fixture.After.test.runs.root.assert = @(@{
                    mptf = @{ attributes = @{ condition = 'length(random_uuid.telemetry[0].result) == 36' } }
                })
            Mock Test-AvmTerraformScopedRandomProviderInUse -ModuleName Avm.Authoring { $false }
            Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring { @('registry.terraform.io/azure/azapi') }
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring { [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' } }
            { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*before any mock retirement*'
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
                $ArgumentList[0] -in @('transform', 'clean-backup')
            }
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
        }

        It 'restores all cleanup test bytes after alias retirement and a late <FailureStep> failure' -TestCases @(
            @{ FailureStep = 'transform' }
            @{ FailureStep = 'clean-backup' }
            @{ FailureStep = 'rollback' }
        ) {
            param($FailureStep)
            $script:fixture.After.test.mock_providers = @{
                'azapi.unit' = New-CustomTelemetryMock -Alias unit -Defaults @{ subscription_id = '00000000-0000-0000-0000-000000000000' }
                'modtm.unit' = New-UnitProviderAlias -Provider modtm
                'random.unit' = New-UnitProviderAlias -Provider random
            }
            foreach ($run in $script:fixture.After.test.runs.Values) {
                $run.mptf.attributes.providers = '{ azapi = azapi.unit, modtm = modtm.unit, random = random.unit }'
            }
            $script:fixture.Options.EnvVars['AVM_TEST_FILE'] = $script:fixture.Scope.File.FullName
            $script:fixture.Options.EnvVars['AVM_TEST_FAILURE_STEP'] = $FailureStep
            $extraPath = Join-Path $script:fixture.Root 'tests' 'integration' 'authored.tftest.hcl'
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $extraPath) -Force
            $extraContent = "mock_provider `"modtm`" {}`r`n# Keep this unrelated authored test.`r`n"
            [System.IO.File]::WriteAllText($extraPath, $extraContent, [System.Text.UTF8Encoding]::new($false))
            $extraBytes = [System.IO.File]::ReadAllBytes($extraPath)
            $content = "mock_provider `"azapi`" { alias = `"unit`" }`r`n" +
            "mock_provider `"modtm`" { alias = `"unit`" }`r`n" +
            "mock_provider `"random`" { alias = `"unit`" }`r`n" +
            "run `"root`" { providers = { azapi = azapi.unit, modtm = modtm.unit, random = random.unit } }`r`n"
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($content)
            Mock Test-AvmTerraformScopedRandomProviderInUse -ModuleName Avm.Authoring { $false }
            Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring { @('registry.terraform.io/azure/azapi') }
            Mock Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring {
                $path = Join-Path $Root 'tests' 'integration' 'authored.tftest.hcl'
                [System.IO.File]::WriteAllText($path, 'cleanup changed the integration test')
            }
            if ($FailureStep -ceq 'rollback') {
                Mock Restore-AvmFileSnapshot -ModuleName Avm.Authoring
            }
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                if ($ArgumentList[0] -eq 'transform') {
                    if ($ArgumentList -contains 'telemetry_subscription_resource_ids={"azapi.unit":"/subscriptions/00000000-0000-0000-0000-000000000000"}') {
                        $EnvVars['AVM_TEST_MIGRATION_UPDATED'] = 'true'
                        if ($EnvVars.AVM_TEST_FAILURE_STEP -cin @('transform', 'rollback')) {
                            throw [System.InvalidOperationException]::new('late native failure')
                        }
                    }
                    [System.IO.File]::WriteAllText($EnvVars.AVM_TEST_FILE, 'aliases retired')
                }
                if ($ArgumentList[0] -eq 'clean-backup' -and
                    $EnvVars.AVM_TEST_FAILURE_STEP -ceq 'clean-backup' -and
                    $EnvVars['AVM_TEST_MIGRATION_UPDATED'] -ceq 'true') {
                    throw [System.InvalidOperationException]::new('late native failure')
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
            }
            if ($FailureStep -ceq 'rollback') {
                { Invoke-UnitMigrationFixture -Fixture $script:fixture -TestContent $content } |
                    Should -Throw '*could not restore the original test bytes*'
                Should -Invoke Restore-AvmFileSnapshot -ModuleName Avm.Authoring -Exactly 1
            }
            else {
                { Invoke-UnitMigrationFixture -Fixture $script:fixture -TestContent $content } | Should -Throw '*late native failure*'
                [System.IO.File]::ReadAllBytes($script:fixture.Scope.File.FullName) | Should -Be $bytes
                [System.IO.File]::ReadAllBytes($extraPath) | Should -Be $extraBytes
            }
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -eq 'transform' -and
                @($ArgumentList | Where-Object { $_ -like 'retired_mock_provider_names=*' }).Count -eq 1 -and
                @($ArgumentList | Where-Object { $_ -like 'telemetry_subscription_resource_ids=*' }).Count -eq 0
            }
        }

        Context 'retained random mock bindings' {
            BeforeEach {
                foreach ($target in $script:fixture.Targets) {
                    $script:fixture.Before.modules[$target.Path].variables.location = @{ required = $true }
                }
                $script:fixture.After.test.mock_providers.random = @{
                    mptf = @{ is_empty = $false; attributes = @{} }
                }
                Mock Test-AvmTerraformScopedRandomProviderInUse -ModuleName Avm.Authoring { $true }
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/random')
                }
                Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                    [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
                } -ParameterFilter { $ArgumentList[0] -eq 'debug' }
            }

            It 'binds all retained mocks only in the selected target without its own requirement' {
                $script:fixture.After.test.mock_providers.azurerm = @{ mptf = @{ is_empty = $true } }
                $script:fixture.Options.EnvVars['AVM_TEST_OWNER_PATH'] = $script:fixture.Root
                Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                    if ($Path -ceq $Options.EnvVars['AVM_TEST_OWNER_PATH']) {
                        return @{ azapi = @{ source = 'Azure/azapi' }; random = @{ source = 'hashicorp/random' } }
                    }
                    return @{ azapi = @{ source = 'Azure/azapi' } }
                }
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/random', 'registry.terraform.io/hashicorp/azurerm')
                }
                $before = $script:fixture.After.test | ConvertTo-Json -Depth 20 -Compress
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                ($script:fixture.After.test | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $before
                Should -Invoke Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring -Exactly 2
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $ArgumentList[0] -eq 'transform' -and
                    $ArgumentList -ccontains ('provider_mock_bindings=' +
                        (ConvertTo-Json -InputObject @{ child = "{`n  azapi = azapi`n  azurerm = azurerm`n  random = random`n}" } -Compress))
                }
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $ArgumentList[0] -eq 'debug' -and
                    $ArgumentList[-1].Contains('provider_mocks["child"].dynamic_block_body')
                }
            }

            It 'includes the replacement AzAPI mock without binding the retired ModTM mock' {
                $script:fixture.After.test.mock_providers.Remove('azapi')
                $script:fixture.After.test.mock_providers.modtm = @{ mptf = @{ is_empty = $true } }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $ArgumentList[0] -eq 'transform' -and
                    @($ArgumentList | Where-Object {
                            $_ -like 'provider_mock_bindings=*' -and
                            $_.Contains('azapi = azapi') -and $_.Contains('random = random') -and -not $_.Contains('modtm')
                        }).Count -eq 1
                }
            }

            It 'leaves direct random requirements and their implicit bindings alone' {
                Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                    @{ azapi = @{ source = 'Azure/azapi' }; random = @{ source = 'hashicorp/random' } }
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }

            It 'does not retain or bind obsolete empty random mocks' {
                Mock Test-AvmTerraformScopedRandomProviderInUse -ModuleName Avm.Authoring { $false }
                $script:fixture.After.test.mock_providers.random.mptf.is_empty = $true
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    @('registry.terraform.io/azure/azapi')
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring -Exactly 2
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }

            It 'does not impose mappings on uninstrumented targets' {
                foreach ($target in $script:fixture.Targets) {
                    $target.Profiles = @('module', 'common')
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }

            It 'preserves complete authored or previously generated mappings' {
                foreach ($run in $script:fixture.After.test.runs.Values) {
                    $run.mptf.attributes.providers = '{ random = random, azapi = azapi }'
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }

            It 'does not bind a random mock to a target that only uses AzAPI' {
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    @('registry.terraform.io/azure/azapi')
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }

            It 'excludes a mock used only by another target' {
                $script:fixture.After.test.mock_providers.time = @{ mptf = @{ is_empty = $true } }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $ArgumentList[0] -eq 'transform' -and
                    @($ArgumentList | Where-Object { $_ -like 'provider_mock_bindings=*' -and $_.Contains('time') }).Count -eq 0
                }
            }

            It 'rejects unsafe bindings before changing any test file: <Unsafe>' -TestCases @(
                @{ Unsafe = 'random alias' }
                @{ Unsafe = 'unrelated alias' }
                @{ Unsafe = 'real random' }
                @{ Unsafe = 'real unrelated' }
                @{ Unsafe = 'partial mapping' }
                @{ Unsafe = 'remapped mapping' }
                @{ Unsafe = 'missing AzAPI mock' }
            ) {
                param($Unsafe)
                switch ($Unsafe) {
                    'random alias' { $script:fixture.After.test.mock_providers['random.alternate'] = @{ mptf = @{ is_empty = $true } } }
                    'unrelated alias' { $script:fixture.After.test.mock_providers['time.alternate'] = @{ mptf = @{ is_empty = $true } } }
                    'real random' { $script:fixture.After.test.providers.random = @{} }
                    'real unrelated' { $script:fixture.After.test.providers.time = @{} }
                    'partial mapping' { $script:fixture.After.test.runs.root.mptf.attributes.providers = '{ random = random }' }
                    'remapped mapping' { $script:fixture.After.test.runs.root.mptf.attributes.providers = '{ random = random, azapi = azapi.alternate }' }
                    'missing AzAPI mock' { $script:fixture.After.test.mock_providers.Remove('azapi') }
                }
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*Cannot automatically migrate unit test*'
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            }

            It 'rejects unsupported native mapping capabilities before cleanup' -TestCases @(
                @{ Response = 'false' }
                @{ Response = '{}' }
                @{ Response = 'null' }
                @{ Response = 'invalid JSON' }
            ) {
                param($Response)
                $script:fixture.Options.EnvVars['AVM_TEST_CAPABILITY_RESPONSE'] = $Response
                Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                    [pscustomobject]@{ ExitCode = 0; StdOut = $EnvVars['AVM_TEST_CAPABILITY_RESPONSE']; StdErr = '' }
                } -ParameterFilter { $ArgumentList[0] -eq 'debug' }
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*provider bindings*'
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
                    $ArgumentList[0] -in @('transform', 'clean-backup')
                }
            }

            It 'does not change provider bindings under WhatIf' {
                Invoke-UnitMigrationFixture -Fixture $script:fixture -WhatIf
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            }
        }

        Context 'retained ModTM mock bindings' {
            BeforeEach {
                foreach ($target in $script:fixture.Targets) {
                    $script:fixture.Before.modules[$target.Path].variables.location = @{ required = $true }
                }
                $script:fixture.After.test.mock_providers.modtm = @{ mptf = @{ is_empty = $true } }
                Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                    @{ azapi = @{ source = 'Azure/azapi' }; modtm = @{ source = 'Azure/modtm' } }
                }
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    @('registry.terraform.io/azure/azapi', 'registry.terraform.io/azure/modtm')
                }
                Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                    [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
                }
            }

            It 'retains direct ModTM requirements and complete explicit mock mappings' {
                foreach ($run in $script:fixture.After.test.runs.Values) {
                    $run.mptf.attributes.providers = '{ azapi = azapi, modtm = modtm }'
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].RetainModtmMock -and
                    $UnitTestPlans[0].ProviderMockBindings.Count -eq 0 -and
                    $UnitTestPlans[0].RetainedProviderReferences.modtm -eq 2 -and
                    $UnitTestPlans[0].RetiredProviderReferences.modtm -eq 0
                }
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }

            It 'ensures introduced AzAPI coverage with a required nonempty ModTM mock and <Binding> bindings' -TestCases @(
                @{ Binding = 'implicit'; Explicit = $false }
                @{ Binding = 'explicit'; Explicit = $true }
            ) {
                param($Explicit)
                $script:fixture.After.test.mock_providers.Remove('azapi')
                $script:fixture.After.test.mock_providers.azurerm = @{ mptf = @{ is_empty = $true } }
                $script:fixture.After.test.mock_providers.modtm = @{
                    mptf = @{ is_empty = $false; attributes = @{} }
                    mock_resource = @(@{ mptf = @{ block_labels = @('modtm_telemetry'); attributes = @{ defaults = @{ tags = @{ fixture = 'mock-only' } } } } })
                }
                Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                    @{ azapi = @{ source = 'Azure/azapi' }; azurerm = @{ source = 'hashicorp/azurerm' } }
                }
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/azurerm', 'registry.terraform.io/azure/modtm')
                }
                Mock Get-AvmTerraformUnitTestModtmRequirementPlan -ModuleName Avm.Authoring {
                    $RequiredProviders[$Path].modtm = @{ source = 'Azure/modtm' }
                }
                if ($Explicit) {
                    $script:fixture.Before.test.mock_providers = $script:fixture.After.test.mock_providers
                    $originalRequirements = @{}
                    $originalSources = @{}
                    foreach ($path in @($script:fixture.Root, $script:fixture.Child)) {
                        $originalRequirements[$path] = @{
                            azurerm = @{ source = 'hashicorp/azurerm' }
                            modtm = @{ source = 'Azure/modtm' }
                        }
                        $originalSources[$path] = @('registry.terraform.io/hashicorp/azurerm', 'registry.terraform.io/azure/modtm')
                    }
                    $script:fixture.Snapshots[0] | Add-Member -NotePropertyName ProviderRequirements -NotePropertyValue $originalRequirements
                    $script:fixture.Snapshots[0] | Add-Member -NotePropertyName ProviderSources -NotePropertyValue $originalSources
                    foreach ($run in $script:fixture.After.test.runs.Values) {
                        $run.mptf.attributes.providers = '{ azurerm = azurerm, modtm = modtm }'
                    }
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].AddDefaultAzapiMock -and $UnitTestPlans[0].RetainModtmMock -and
                    $UnitTestPlans[0].ProviderMockBindings.root.Contains('azapi = azapi') -and
                    $UnitTestPlans[0].ProviderMockBindings.root.Contains('modtm = modtm')
                }
            }

            It 'does not borrow a child alias binding to cover the root run' {
                $script:fixture.After.test.mock_providers.Remove('modtm')
                $script:fixture.After.test.mock_providers['modtm.unit'] = New-UnitProviderAlias -Provider modtm
                $script:fixture.After.test.runs.child.mptf.attributes.providers = '{ azapi = azapi, modtm = modtm.unit }'
                Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                    @{ azapi = @{ source = 'Azure/azapi' } }
                }
                Mock Get-AvmTerraformUnitTestModtmRequirementPlan -ModuleName Avm.Authoring {
                    $RequiredProviders[$Path].modtm = @{ source = 'Azure/modtm' }
                }
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*Cannot automatically migrate unit test*'
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
                    $ArgumentList[0] -in @('transform', 'clean-backup')
                }
            }

            It 'retires only the unused selected target binding while keeping the required mock' {
                $script:fixture.Options.EnvVars['AVM_TEST_OWNER_PATH'] = $script:fixture.Root
                foreach ($run in $script:fixture.After.test.runs.Values) {
                    $run.mptf.attributes.providers = '{ azapi = azapi, modtm = modtm }'
                }
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    if ($Path -ceq $Options.EnvVars['AVM_TEST_OWNER_PATH']) {
                        return @('registry.terraform.io/azure/azapi', 'registry.terraform.io/azure/modtm')
                    }
                    return @('registry.terraform.io/azure/azapi')
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].RetainModtmMock -and
                    $UnitTestPlans[0].ProviderMockBindings.Count -eq 1 -and
                    $UnitTestPlans[0].ProviderMockBindings.child -ceq '{ azapi = azapi,    }' -and
                    $UnitTestPlans[0].RetainedProviderReferences.modtm -eq 1 -and
                    $UnitTestPlans[0].RetiredProviderReferences.modtm -eq 1
                }
            }

            It 'requires review for a nonempty retained ModTM binding in an unused child' {
                $script:fixture.After.test.mock_providers.modtm = @{
                    mptf = @{ is_empty = $false; attributes = @{} }
                    mock_resource = @(@{ mptf = @{ block_labels = @('modtm_telemetry'); attributes = @{ defaults = @{ tags = @{ fixture = 'mock-only' } } } } })
                }
                $script:fixture.Options.EnvVars['AVM_TEST_OWNER_PATH'] = $script:fixture.Root
                foreach ($run in $script:fixture.After.test.runs.Values) {
                    $run.mptf.attributes.providers = '{ azapi = azapi, modtm = modtm }'
                }
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    if ($Path -ceq $Options.EnvVars['AVM_TEST_OWNER_PATH']) {
                        return @('registry.terraform.io/azure/azapi', 'registry.terraform.io/azure/modtm')
                    }
                    return @('registry.terraform.io/azure/azapi')
                }
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*run provider mappings*'
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }

            It 'does not let an unselected owner retain a selected child unused mock' {
                $script:fixture.After.test.runs.Remove('root')
                $script:fixture.After.test.run_modules.Remove('root')
                $script:fixture.Before.test.runs.Remove('root')
                $script:fixture.Before.test.run_modules.Remove('root')
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    @('registry.terraform.io/azure/azapi')
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                    param($Fixture)
                    Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 1 -ParameterFilter { $Path -ceq $Fixture.Child }
                }
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    -not $UnitTestPlans[0].RetainModtmMock
                }
            }

            It 'binds all required mocks when the selected target inherits ModTM without declaring it' {
                Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                    @{ azapi = @{ source = 'Azure/azapi' } }
                }
                Mock Get-AvmTerraformUnitTestModtmRequirementPlan -ModuleName Avm.Authoring {
                    $RequiredProviders[$Path].modtm = @{ source = 'registry.terraform.io/azure/modtm' }
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $ArgumentList[0] -eq 'transform' -and
                    @($ArgumentList | Where-Object {
                            $_ -like 'provider_mock_bindings=*' -and $_.Contains('modtm = modtm') -and $_.Contains('azapi = azapi')
                        }).Count -eq 1
                }
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].RetainModtmMock -and $UnitTestPlans[0].ProviderMockBindings.Count -eq 2
                }
            }

            It 'rejects an unproven provider source before changing any test' -TestCases @(
                @{ Source = 'registry.terraform.io/hashicorp/modtm' }
                @{ Source = 'example.com/untrusted/modtm' }
            ) {
                param($Source)
                $script:fixture.Options.EnvVars['AVM_TEST_MODTM_SOURCE'] = $Source
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    @('registry.terraform.io/azure/azapi', $Options.EnvVars['AVM_TEST_MODTM_SOURCE'])
                }
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*unexpected ModTM provider source*'
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }

            It 'rejects real or aliased ModTM providers before retaining a mock: <Shape>' -TestCases @(
                @{ Shape = 'real' }
                @{ Shape = 'aliased' }
            ) {
                param($Shape)
                if ($Shape -eq 'real') {
                    $script:fixture.After.test.providers.modtm = @{}
                }
                else {
                    $script:fixture.After.test.mock_providers['modtm.alternate'] = @{ mptf = @{ is_empty = $false } }
                }
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*Cannot automatically migrate unit test*'
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            }
        }

        Context 'customized telemetry mocks' {
                BeforeEach {
                    Mock Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring { $Scope.Inspection }
                    Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                        [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
                    } -ParameterFilter { $ArgumentList[0] -eq 'debug' }
                    foreach ($target in $script:fixture.Targets) {
                        $script:fixture.Before.modules[$target.Path].variables.location = @{ required = $true }
                    }
                    $script:fixture.After.test.mock_providers.azapi = New-CustomTelemetryMock
                }

                It 'adds a native missing-field patch using <Source> without changing inspected defaults' -TestCases @(
                    @{ Source = 'the synthetic subscription'; Defaults = @{}; Id = '00000000-0000-0000-0000-000000000000' }
                    @{
                        Source = 'an authored subscription'
                        Defaults = @{
                            subscription_id = 'A1111111-1111-1111-1111-111111111111'
                            tenant_id = '${var.authored_tenant}'
                            object_id = '22222222-2222-2222-2222-222222222222'
                        }
                        Id = 'A1111111-1111-1111-1111-111111111111'
                    }
                ) {
                    param($Defaults, $Id)
                    $script:fixture.After.test.mock_providers.azapi = New-CustomTelemetryMock -Defaults $Defaults
                    $before = $script:fixture.After.test | ConvertTo-Json -Depth 20 -Compress
                    Invoke-UnitMigrationFixture -Fixture $script:fixture
                    ($script:fixture.After.test | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $before
                    InModuleScope Avm.Authoring -Parameters @{ ResourceId = "/subscriptions/$Id" } {
                        param($ResourceId)
                        Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                            $ArgumentList[0] -eq 'transform' -and
                            $ArgumentList[8] -ceq 'new_location_modules=[]' -and
                            $ArgumentList[10] -ceq ('telemetry_subscription_resource_ids=' +
                                (ConvertTo-Json -InputObject @{ azapi = $ResourceId } -Compress))
                        }
                        Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'clean-backup' }
                    }
                }

                It 'plans a missing client-config block or defaults object' -TestCases @(
                    @{ Missing = 'block' }
                    @{ Missing = 'defaults' }
                ) {
                    param($Missing)
                    $mock = $script:fixture.After.test.mock_providers.azapi
                    if ($Missing -eq 'block') {
                        $mock.mock_data = @($mock.mock_data[1])
                    }
                    else {
                        $mock.mock_data[0].mptf.attributes.Remove('defaults')
                    }
                    Invoke-UnitMigrationFixture -Fixture $script:fixture
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                        $ArgumentList[0] -eq 'transform' -and
                        $ArgumentList[10] -ceq 'telemetry_subscription_resource_ids={"azapi":"/subscriptions/00000000-0000-0000-0000-000000000000"}'
                    }
                }

                It 'patches semantically empty mocks through the native profile' {
                    $script:fixture.After.test.mock_providers.azapi = @{
                        mptf = @{ is_empty = $true; attributes = @{} }
                    }
                    Invoke-UnitMigrationFixture -Fixture $script:fixture
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                        $ArgumentList[0] -eq 'debug'
                    }
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                        $ArgumentList[0] -eq 'transform' -and
                        $ArgumentList[8] -ceq 'new_location_modules=[]' -and
                        $ArgumentList[10] -ceq 'telemetry_subscription_resource_ids={"azapi":"/subscriptions/00000000-0000-0000-0000-000000000000"}'
                    }
                }

                It 'preserves complete same-name bindings while adding a missing client resource ID' {
                    $script:fixture.After.test.runs.root.mptf.attributes.providers = '{ azapi = azapi }'
                    Invoke-UnitMigrationFixture -Fixture $script:fixture
                    $script:fixture.After.test.runs.root.mptf.attributes.providers | Should -BeExactly '{ azapi = azapi }'
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                        $ArgumentList[0] -eq 'transform' -and
                        $ArgumentList -ccontains 'telemetry_subscription_resource_ids={"azapi":"/subscriptions/00000000-0000-0000-0000-000000000000"}'
                    }
                }

                It 'never overwrites an authored resource ID even when it is null or invalid' -TestCases @(
                    @{ Value = '/subscriptions/33333333-3333-3333-3333-333333333333' }
                    @{ Value = '${var.resource_id}' }
                    @{ Value = $null }
                    @{ Value = 'invalid-authored-value' }
                ) {
                    param($Value)
                    $script:fixture.After.test.mock_providers.azapi =
                        New-CustomTelemetryMock -Defaults @{ subscription_resource_id = $Value }
                    Invoke-UnitMigrationFixture -Fixture $script:fixture
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                }

                It 'rejects defaults that cannot be merged without replacing authored expressions' -TestCases @(
                    @{ Value = $null }
                    @{ Value = '${var.client_defaults}' }
                    @{ Value = @('not', 'an object') }
                ) {
                    param($Value)
                    $script:fixture.After.test.mock_providers.azapi = New-CustomTelemetryMock -Defaults $Value
                    { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*defaults must be a statically inspectable object literal*'
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                    Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                }

                It 'rejects subscription IDs that cannot supply a matching resource ID' -TestCases @(
                    @{ Value = $null }
                    @{ Value = '${var.subscription_id}' }
                    @{ Value = '' }
                    @{ Value = 1 }
                    @{ Value = "11111111-1111-1111-1111-111111111111`n" }
                    @{ Value = '/subscriptions/11111111-1111-1111-1111-111111111111' }
                ) {
                    param($Value)
                    $script:fixture.After.test.mock_providers.azapi =
                        New-CustomTelemetryMock -Defaults @{ subscription_id = $Value }
                    { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*subscription_id is not a literal GUID*'
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                    Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                }

                It 'rejects ambiguous mock bindings even when no location input is needed' -TestCases @(
                    @{ Unsafe = 'source' }
                    @{ Unsafe = 'real' }
                    @{ Unsafe = 'alias' }
                    @{ Unsafe = 'mapping' }
                    @{ Unsafe = 'duplicate' }
                ) {
                    param($Unsafe)
                    switch ($Unsafe) {
                        source { $script:fixture.After.test.mock_providers.azapi.mptf.attributes.source = './mocks' }
                        real { $script:fixture.After.test.providers.azapi = @{} }
                        alias { $script:fixture.After.test.mock_providers['azapi.alternate'] = @{ mptf = @{ is_empty = $true } } }
                        mapping { $script:fixture.After.test.runs.root.mptf.attributes.providers = '{ azapi = azapi.alternate }' }
                        duplicate {
                            $script:fixture.After.test.mock_providers.azapi.mock_data +=
                                $script:fixture.After.test.mock_providers.azapi.mock_data[0]
                        }
                    }
                    { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*Cannot automatically migrate unit test*'
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                    Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                }

                It 'rejects incomplete customized-mock inspection' -TestCases @(
                    @{ Missing = 'provider metadata' }
                    @{ Missing = 'provider attributes' }
                    @{ Missing = 'data labels' }
                    @{ Missing = 'data attributes' }
                ) {
                    param($Missing)
                    $mock = $script:fixture.After.test.mock_providers.azapi
                    switch ($Missing) {
                        'provider metadata' { $mock.Remove('mptf') }
                        'provider attributes' { $mock.mptf.Remove('attributes') }
                        'data labels' { $mock.mock_data[0].mptf.Remove('block_labels') }
                        'data attributes' { $mock.mock_data[0].mptf.Remove('attributes') }
                    }
                    { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*invalid AzAPI*'
                    Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                }

                It 'does not augment mocks for targets without telemetry' {
                    foreach ($target in $script:fixture.Targets) {
                        $target.Profiles = @('module', 'common')
                    }
                    Invoke-UnitMigrationFixture -Fixture $script:fixture
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                }

                It 'rejects unsafe binaries or profiles before changing any test file' -TestCases @(
                    @{ Response = 'false' }
                    @{ Response = '{}' }
                    @{ Response = 'null' }
                    @{ Response = 'invalid JSON' }
                ) {
                    param($Response)
                    $script:fixture.Options.EnvVars['AVM_TEST_CAPABILITY_RESPONSE'] = $Response
                    Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                        [pscustomobject]@{ ExitCode = 0; StdOut = $EnvVars['AVM_TEST_CAPABILITY_RESPONSE']; StdErr = '' }
                    } -ParameterFilter { $ArgumentList[0] -eq 'debug' }
                    { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*label-safe*'
                    Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
                        $ArgumentList[0] -in @('transform', 'clean-backup')
                    }
                }

                It 'does not change customized mocks under WhatIf' {
                    Invoke-UnitMigrationFixture -Fixture $script:fixture -WhatIf
                    Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                    Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
                }
        }

        Context 'supported AzAPI aliases' {
            BeforeEach {
                foreach ($target in $script:fixture.Targets) {
                    $script:fixture.Before.modules[$target.Path].variables.location = @{ required = $true }
                }
                $script:fixture.After.test.mock_providers.azapi = New-CustomTelemetryMock -Defaults @{
                    subscription_id = '11111111-1111-1111-1111-111111111111'
                    tenant_id = 'default-tenant'
                }
                $script:fixture.After.test.mock_providers['azapi.alternate'] = New-CustomTelemetryMock -Alias alternate -Defaults @{
                    subscription_id = '22222222-2222-2222-2222-222222222222'
                    tenant_id = 'alternate-tenant'
                }
                $script:fixture.After.test.mock_providers.modtm = @{ mptf = @{ is_empty = $true } }
                $script:fixture.After.test.mock_providers.random = @{ mptf = @{ is_empty = $true } }
                Mock Test-AvmTerraformScopedRandomProviderInUse -ModuleName Avm.Authoring { $false }
                Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                    [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
                } -ParameterFilter { $ArgumentList[0] -eq 'debug' }
            }

            It 'plans distinct default and aliased client IDs and lossless retired bindings' {
                $script:fixture.After.test.runs.root.mptf.attributes.providers =
                    '{ azapi = azapi.alternate, modtm = modtm, random = random }'
                $before = $script:fixture.After.test | ConvertTo-Json -Depth 20 -Compress
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                ($script:fixture.After.test | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $before
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].MockMigrationValidated -and
                    -not $UnitTestPlans[0].AddDefaultAzapiMock -and
                    $UnitTestPlans[0].TelemetrySubscriptionResourceIds.azapi -ceq '/subscriptions/11111111-1111-1111-1111-111111111111' -and
                    $UnitTestPlans[0].TelemetrySubscriptionResourceIds['azapi.alternate'] -ceq '/subscriptions/22222222-2222-2222-2222-222222222222' -and
                    $UnitTestPlans[0].RetiredProviderReferences.modtm -eq 1 -and
                    $UnitTestPlans[0].RetiredProviderReferences.random -eq 1 -and
                    $UnitTestPlans[0].ProviderMockBindings.root -ceq '{ azapi = azapi.alternate,       }'
                }
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $ArgumentList[0] -eq 'debug' -and
                    $ArgumentList[-1].Contains('telemetry_mock["azapi"].match_nested_block_labels') -and
                    $ArgumentList[-1].Contains('telemetry_mock["azapi.alternate"].merge_object_attributes') -and
                    $ArgumentList[-1].Contains('provider_mocks["root"].dynamic_block_body')
                }
            }

            It 'requests a default replacement without confusing it with the existing alias' {
                $script:fixture.After.test.mock_providers.Remove('azapi')
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].AddDefaultAzapiMock -and
                    $UnitTestPlans[0].TelemetrySubscriptionResourceIds.Count -eq 1 -and
                    $UnitTestPlans[0].TelemetrySubscriptionResourceIds.ContainsKey('azapi.alternate')
                }
            }

            It 'accepts an alias-only mock when every run explicitly binds that known alias' {
                $script:fixture.After.test.mock_providers.Remove('azapi')
                $script:fixture.After.test.mock_providers.Remove('modtm')
                foreach ($run in $script:fixture.After.test.runs.Values) {
                    $run.mptf.attributes.providers = '{ azapi = azapi.alternate }'
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].MockMigrationValidated -and
                    -not $UnitTestPlans[0].AddDefaultAzapiMock -and
                    $UnitTestPlans[0].ProviderMockBindings.Count -eq 0 -and
                    $UnitTestPlans[0].TelemetrySubscriptionResourceIds.Count -eq 1
                }
            }

            It 'does not treat an unbound alias as a default provider' {
                $script:fixture.After.test.mock_providers.Remove('azapi')
                $script:fixture.After.test.mock_providers.Remove('modtm')
                $script:fixture.After.test.runs.root.mptf.attributes.providers = '{ azapi = azapi.alternate }'
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*introduced providers need default mocks*'
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            }

            It 'preserves already complete alias bindings and client defaults without a native rewrite' {
                foreach ($name in @('azapi', 'azapi.alternate')) {
                    $script:fixture.After.test.mock_providers[$name].mock_data[0].mptf.attributes.defaults.subscription_resource_id =
                        '/subscriptions/33333333-3333-3333-3333-333333333333'
                }
                $script:fixture.After.test.runs.root.mptf.attributes.providers = '{ azapi = azapi.alternate }'
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].ProviderMockBindings.Count -eq 0 -and
                    $UnitTestPlans[0].TelemetrySubscriptionResourceIds.Count -eq 0
                }
            }

            It 'does not generate an aliased target key when binding inherited defaults' {
                Mock Test-AvmTerraformScopedRandomProviderInUse -ModuleName Avm.Authoring { $true }
                Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                    @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/random')
                }
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].ProviderMockBindings.Count -eq 2 -and
                    $UnitTestPlans[0].ProviderMockBindings.root -ceq "{`n  azapi = azapi`n  random = random`n}" -and
                    $UnitTestPlans[0].ProviderMockBindings.child -ceq "{`n  azapi = azapi`n  random = random`n}"
                }
            }

            It 'rejects unproven alias metadata before any write: <Invalid>' -TestCases @(
                @{ Invalid = 'address' }
                @{ Invalid = 'alias' }
                @{ Invalid = 'labels' }
                @{ Invalid = 'type' }
                @{ Invalid = 'source'; Expected = '*mock source must be an existing local directory*' }
                @{ Invalid = 'empty' }
            ) {
                param($Invalid, $Expected = '*AzAPI alias*requires literal*')
                $mock = $script:fixture.After.test.mock_providers['azapi.alternate']
                switch ($Invalid) {
                    address { $mock.mptf.block_address = 'mock_provider.azapi' }
                    alias { $mock.mptf.attributes.alias = '${var.alias}' }
                    labels { $mock.mptf.block_labels = @('azapi', 'alternate') }
                    type { $mock.mptf.block_type = 'provider' }
                    source { $mock.mptf.attributes.source = './mocks' }
                    empty { $mock.mptf.is_empty = $true }
                }
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw $Expected
                Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            }
        }

        It 'does not repair a pre-existing input or invent a value for an optional or absent input' -TestCases @(
            @{ InputState = 'pre-existing' }
            @{ InputState = 'optional' }
            @{ InputState = 'absent' }
        ) {
            param($InputState)
            foreach ($target in $script:fixture.Targets) {
                switch ($InputState) {
                    pre-existing { $script:fixture.Before.modules[$target.Path].variables.location = @{ required = $true } }
                    optional { $script:fixture.After.modules[$target.Path].variables.location.required = $false }
                    absent { $script:fixture.After.modules[$target.Path].variables.Remove('location') }
                }
            }
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        }

        It 'preserves authored global location values and complete mocks' -TestCases @(
            @{ Value = 'uksouth' }
            @{ Value = $null }
            @{ Value = '${var.authored_location}' }
        ) {
            param($Value)
            $script:fixture.After.test.variables = @{ mptf = @{ attributes = @{ location = $Value } } }
            $mocks = $script:fixture.After.test.mock_providers | ConvertTo-Json -Depth 20 -Compress
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            $script:fixture.After.test.variables.mptf.attributes.location | Should -Be $Value
            ($script:fixture.After.test.mock_providers | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $mocks
        }

        It 'does not let an authored global location hide unmocked telemetry' {
            $script:fixture.After.test.variables = @{ mptf = @{ attributes = @{ location = 'uksouth' } } }
            $script:fixture.After.test.mock_providers.Clear()
            { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*Cannot automatically migrate unit test*'
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
        }

        It 'preserves empty-file safety with <Declaration>' -TestCases @(
            @{ Declaration = 'no providers'; RealProvider = $false }
            @{ Declaration = 'a real provider'; RealProvider = $true }
        ) {
            param($RealProvider)
            foreach ($test in @($script:fixture.Before.test, $script:fixture.After.test)) {
                $test.runs.Clear()
                $test.run_modules.Clear()
                $test.mock_providers.Clear()
            }
            if ($RealProvider) {
                $script:fixture.After.test.providers.azapi = @{}
                { Invoke-UnitMigrationFixture -Fixture $script:fixture -TestContent 'provider "azapi" {}' } |
                    Should -Throw '*without real providers*'
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            }
            else {
                Invoke-UnitMigrationFixture -Fixture $script:fixture -TestContent '# Empty authored test file.'
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].ProviderMockBindings.Count -eq 0 -and
                    -not $UnitTestPlans[0].AddDefaultAzapiMock -and
                    $UnitTestPlans[0].TelemetrySubscriptionResourceIds.Count -eq 0
                }
                Should -Invoke Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring -Exactly 0
                [System.IO.File]::ReadAllText($script:fixture.Scope.File.FullName) | Should -BeExactly '# Empty authored test file.'
            }
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        }

        It 'selects only the target whose run lacks an authored location' -TestCases @(
            @{ Value = 'uksouth' }
            @{ Value = $null }
            @{ Value = '${run.setup.location}' }
        ) {
            param($Value)
            $script:fixture.After.test.runs.root.variables = @(@{ mptf = @{ attributes = @{ location = $Value } } })
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList[0] -eq 'transform' -and
                    $ArgumentList[8] -ceq ('new_location_modules=' +
                        (ConvertTo-Json -InputObject @($Fixture.Child) -Compress))
                }
            }
        }

        It 'requires review for real, mapped, aliased or missing replacement providers' -TestCases @(
            @{ Unsafe = 'unmocked' }
            @{ Unsafe = 'azurerm-only' }
            @{ Unsafe = 'real-azapi' }
            @{ Unsafe = 'real-azurerm' }
            @{ Unsafe = 'mapping' }
            @{ Unsafe = 'alias' }
        ) {
            param($Unsafe)
            switch ($Unsafe) {
                unmocked { $script:fixture.After.test.mock_providers.Clear() }
                azurerm-only {
                    $script:fixture.After.test.mock_providers.Clear()
                    $script:fixture.After.test.mock_providers.azurerm = @{ mptf = @{ is_empty = $true } }
                }
                real-azapi { $script:fixture.After.test.providers.azapi = @{} }
                real-azurerm { $script:fixture.After.test.providers['azurerm.live'] = @{} }
                mapping { $script:fixture.After.test.runs.child.mptf.attributes.providers = '{ azapi = azapi.alternate }' }
                alias { $script:fixture.After.test.mock_providers['azapi.alternate'] = @{ mptf = @{ is_empty = $false } } }
            }
            { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*Cannot automatically migrate unit test*'
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        }

        It 'requires complete original mock coverage before adding an introduced binding: <UnmockedSource>' -TestCases @(
            @{ UnmockedSource = $false }
            @{ UnmockedSource = $true }
        ) {
            param($UnmockedSource)
            $script:fixture.After.test.mock_providers.azurerm = @{ mptf = @{ is_empty = $true } }
            $script:fixture.Before.test.mock_providers.azurerm = @{ mptf = @{ is_empty = $true } }
            $script:fixture.After.test.runs.child.mptf.attributes.providers = '{ azurerm = azurerm /* retain */ }'
            $script:fixture.Before.test.runs.child.mptf.attributes.providers = '{ azurerm = azurerm /* retain */ }'
            $script:fixture.Snapshots[0] | Add-Member -NotePropertyName ProviderRequirements -NotePropertyValue @{
                $script:fixture.Child = @{ azurerm = @{ source = 'hashicorp/azurerm' } }
            }
            $script:fixture.Snapshots[0] | Add-Member -NotePropertyName ProviderSources -NotePropertyValue @{
                $script:fixture.Child = @('registry.terraform.io/hashicorp/azurerm')
            }
            if ($UnmockedSource) {
                $script:fixture.Snapshots[0].ProviderSources[$script:fixture.Child] += 'registry.terraform.io/hashicorp/time'
            }
            Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                @{ azapi = @{ source = 'Azure/azapi' }; azurerm = @{ source = 'hashicorp/azurerm' } }
            }
            Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/azurerm')
            }
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                [pscustomobject]@{ ExitCode = 0; StdOut = 'true'; StdErr = '' }
            }
            if ($UnmockedSource) {
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*Cannot automatically migrate unit test*'
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            }
            else {
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
                    $UnitTestPlans[0].ProviderMockBindings.child -ceq "{ azurerm = azurerm /* retain */ `n  azapi = azapi`n}" -and
                    $UnitTestPlans[0].MockMigrationValidated
                }
            }
        }

        It 'allows an empty modtm mock to be replaced before adding the input' {
            $script:fixture.After.test.mock_providers.Clear()
            $script:fixture.After.test.mock_providers.modtm = @{ mptf = @{ is_empty = $true } }
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 1
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'transform' }
        }

        It 'does not demand an AzAPI mock for a non-telemetry AzureRM helper' {
            foreach ($target in $script:fixture.Targets) {
                $target.Profiles = @('module', 'common')
            }
            $script:fixture.After.test.mock_providers.Clear()
            $script:fixture.After.test.mock_providers.azurerm = @{ mptf = @{ is_empty = $true } }
            Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                @{ azurerm = @{ source = 'hashicorp/azurerm' } }
            }
            Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                @('registry.terraform.io/hashicorp/azurerm')
            }
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'transform' }
        }

        It 'checks selected source coverage even when inputs and client defaults need no repair' {
            foreach ($target in $script:fixture.Targets) {
                $script:fixture.Before.modules[$target.Path].variables.location = @{ required = $true }
            }
            Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/azurerm')
            }
            { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*Cannot automatically migrate unit test*'
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
        }

        It 'preserves uninstrumented identifier assertions without retiring their provider mocks' {
            foreach ($target in $script:fixture.Targets) {
                $target.Profiles = @('module', 'common')
                $script:fixture.Before.modules[$target.Path].variables.location = @{ required = $true }
            }
            $script:fixture.After.test.runs.root.assert = @(@{
                    mptf = @{ attributes = @{ condition = 'length(random_uuid.telemetry[0].result) == 36' } }
                })
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        }

        It 'rejects remapped provider bindings even when only mock cleanup is required' {
            foreach ($target in $script:fixture.Targets) {
                $script:fixture.Before.modules[$target.Path].variables.location = @{ required = $true }
            }
            $script:fixture.After.test.mock_providers.azapi = @{ mptf = @{ is_empty = $true } }
            $script:fixture.After.test.runs.child.mptf.attributes.providers = '{ azapi = azapi.alternate }'
            { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*run provider mappings*'
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
        }

        It 'rejects a concurrently changed test file' {
            Mock Get-FileHash -ModuleName Avm.Authoring { [pscustomobject]@{ Hash = 'changed' } }
            { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*changed while its modules were transformed*'
            Should -Invoke Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring -Exactly 0
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
        }

        It 'rejects changed or removed run targets before modifying any test' -TestCases @(
            @{ Change = 'target' }
            @{ Change = 'removed' }
        ) {
            param($Change)
            if ($Change -eq 'target') {
                $script:fixture.After.test.run_modules.child.dir = $script:fixture.Root
            }
            else {
                $script:fixture.After.test.run_modules.Remove('child')
            }
            { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*changed*target*during migration*'
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        }

        It 'honours WhatIf without modifying mocks or running a native transform' {
            Invoke-UnitMigrationFixture -Fixture $script:fixture -WhatIf
            Should -Invoke Remove-AvmLegacyTelemetryTestMock -ModuleName Avm.Authoring -Exactly 0
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
        }

        It 'surfaces native transform and backup cleanup failures' -TestCases @(
            @{ Command = 'transform' }
            @{ Command = 'clean-backup' }
        ) {
            param($Command)
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; FailedCommand = $Command } {
                param($Fixture, $FailedCommand)
                Mock Invoke-AvmProcess {
                    throw [System.InvalidOperationException]::new('native migration failed')
                } -ParameterFilter { $ArgumentList[0] -eq $FailedCommand }
                {
                    Invoke-AvmTerraformUnitTestMigration -Root $Fixture.Root -ModuleTargets $Fixture.Targets `
                        -Snapshots $Fixture.Snapshots -Options $Fixture.Options
                } | Should -Throw '*native migration failed*'
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'clean-backup' }
            }
        }
    }
}
