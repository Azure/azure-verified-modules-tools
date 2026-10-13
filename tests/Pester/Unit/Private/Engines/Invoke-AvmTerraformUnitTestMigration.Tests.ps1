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
                ToolPath      = Join-Path $TestDrive 'mapotf'
                TerraformPath = Join-Path $TestDrive 'terraform'
                ProfileDirs   = @{
                    module              = Join-Path $TestDrive 'module-profile'
                    'unit-test-inspect' = Join-Path $TestDrive 'inspection'
                    'unit-test'         = Join-Path $TestDrive 'location'
                }
                EnvVars       = @{}
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
        param($Fixture, [switch] $WhatIf)
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
                Should -Invoke Invoke-AvmTerraformInit -Exactly 1 -ParameterFilter {
                    $TerraformPath -ceq $Fixture.Options.TerraformPath -and
                    $WorkingDirectory -ceq $Fixture.Child -and
                    [bool]$BackendFalse -and [bool]$NoColor -and [bool]$PreserveDependencySelections
                }
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
            Mock Invoke-AvmTerraformInit -ModuleName Avm.Authoring {
                throw [System.InvalidOperationException]::new('module installation failed')
            }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                { Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options } |
                    Should -Throw '*module installation failed*'
                Should -Invoke Invoke-AvmTerraformInit -Exactly 1
                Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'providers' }
            }
        }

        It 'isolates dependency inspection arguments without changing the caller environment' {
            Set-Content -LiteralPath (Join-Path $script:fixture.Child 'main.tf') -Encoding utf8NoBOM `
                -Value 'module "backend" { source = "../backend" }'
            foreach ($name in @('TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_providers')) {
                $script:fixture.Options.EnvVars[$name] = 'authored'
            }
            $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = "Providers required by configuration:`n."
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                @(Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options) | Should -HaveCount 0
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $null -eq $EnvVars.TF_DATA_DIR -and $null -eq $EnvVars.TF_CLI_ARGS -and
                    $null -eq $EnvVars.TF_CLI_ARGS_init -and $null -eq $EnvVars.TF_CLI_ARGS_providers
                }
                $Fixture.Options.EnvVars.TF_DATA_DIR | Should -BeExactly 'authored'
                $Fixture.Options.EnvVars.TF_CLI_ARGS_init | Should -BeExactly 'authored'
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
            }
            $script:fixture.Options.EnvVars['AVM_TEST_FAIL_INIT'] = $Failure
            $script:fixture.Options.EnvVars['AVM_TEST_INSPECTION_JSON'] = "Providers required by configuration:`n."
            $manifestPath = Join-Path -Path $script:fixture.Child -ChildPath '.terraform' -AdditionalChildPath 'modules', 'modules.json'
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force
            $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes(
                "{`r`n  `"Modules`": [{`"Key`":`"`",`"Dir`":`".`"},{`"Key`":`"published`",`"Dir`":`".terraform/modules/published`",`"Source`":`"Azure/example/azurerm`",`"Version`":`"0.1.0`"}]`r`n}`r`n")
            [System.IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
            Mock Invoke-AvmTerraformInit -ModuleName Avm.Authoring {
                Set-Content -LiteralPath (Join-Path $WorkingDirectory '.terraform.lock.hcl') -Value 'updated lock'
                Set-Content -LiteralPath (Join-Path -Path $WorkingDirectory -ChildPath '.terraform' `
                        -AdditionalChildPath 'modules', 'modules.json') -Value '{"Modules":[]}'
                if ($EnvVars.AVM_TEST_FAIL_INIT) {
                    throw [System.InvalidOperationException]::new('module installation failed')
                }
            }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; Failure = $Failure } {
                param($Fixture, $Failure)
                if ($Failure) {
                    { Get-AvmTerraformUnitTestProviderSource -Path $Fixture.Child `
                            -ModuleTargets $Fixture.Targets -Options $Fixture.Options } |
                        Should -Throw '*module installation failed*'
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

        It 'accepts an empty configuration tree without including state requirements' {
            InModuleScope Avm.Authoring {
                @(ConvertFrom-AvmTerraformProviderTree `
                    -Text "Providers required by configuration:`n.`n`nProviders required by state:`nprovider[registry.terraform.io/hashicorp/random]" `
                    -Path 'target') | Should -HaveCount 0
            }
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
        It 'recognizes only complete count comparisons: <Condition>' -TestCases @(
            @{ Condition = 'length(random_uuid.telemetry) == 0'; Count = 1 }
            @{ Condition = 'length(random_uuid.telemetry) == 1'; Count = 1 }
            @{ Condition = "length (`n random_uuid.telemetry `n) == 1"; Count = 1 }
            @{ Condition = 'length(random_uuid.telemetry) == 10'; Count = 0 }
            @{ Condition = 'length(random_uuid.telemetry) == 1 && var.enabled'; Count = 0 }
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
        }

        It 'does not migrate assertions belonging to an uninstrumented selected target' {
            $script:fixture.Targets[1].Profiles = @('module', 'common')
            foreach ($run in $script:fixture.After.test.runs.Values) {
                $run.assert = @(@{ mptf = @{ attributes = @{ condition = 'length(random_uuid.telemetry) == 0' } } })
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
                @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/random')
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
                $run.assert = @(@{ mptf = @{ attributes = @{ condition = 'length(random_uuid.telemetry) == 0' } } })
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

        Context 'retained random mock bindings' {
            BeforeEach {
                foreach ($target in $script:fixture.Targets) {
                    $script:fixture.Before.modules[$target.Path].variables.location = @{ required = $true }
                }
                $script:fixture.After.test.mock_providers.random = @{
                    mptf = @{ is_empty = $false; attributes = @{} }
                }
                Mock Test-AvmTerraformScopedRandomProviderInUse -ModuleName Avm.Authoring { $true }
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
                Invoke-UnitMigrationFixture -Fixture $script:fixture
                Should -Invoke Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring -Exactly 0
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
                @{ Invalid = 'source' }
                @{ Invalid = 'empty' }
            ) {
                param($Invalid)
                $mock = $script:fixture.After.test.mock_providers['azapi.alternate']
                switch ($Invalid) {
                    address { $mock.mptf.block_address = 'mock_provider.azapi' }
                    alias { $mock.mptf.attributes.alias = '${var.alias}' }
                    labels { $mock.mptf.block_labels = @('azapi', 'alternate') }
                    type { $mock.mptf.block_type = 'provider' }
                    source { $mock.mptf.attributes.source = './mocks' }
                    empty { $mock.mptf.is_empty = $true }
                }
                { Invoke-UnitMigrationFixture -Fixture $script:fixture } | Should -Throw '*AzAPI alias*requires literal*'
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

        It 'preserves authored global values without imposing new mock requirements' -TestCases @(
            @{ Value = 'uksouth' }
            @{ Value = $null }
            @{ Value = '${var.authored_location}' }
        ) {
            param($Value)
            $script:fixture.After.test.variables = @{ mptf = @{ attributes = @{ location = $Value } } }
            $script:fixture.After.test.mock_providers.Clear()
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
            $script:fixture.After.test.variables.mptf.attributes.location | Should -Be $Value
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
            Invoke-UnitMigrationFixture -Fixture $script:fixture
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter { $ArgumentList[0] -eq 'transform' }
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
