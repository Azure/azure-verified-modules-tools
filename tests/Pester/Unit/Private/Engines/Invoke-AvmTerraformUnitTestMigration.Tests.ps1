#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
    . (Join-Path $PSScriptRoot '..' '..' '..' 'Helpers' 'TerraformUnitMigration.ps1')
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Terraform ModTM restoration module enumeration' {
    It 'preserves a retained dependency with <Label> as the <Role> module label' -TestCases @(
        @{ Label = 'keys'; Role = 'other'; RetainedLabel = $false }
        @{ Label = 'Keys'; Role = 'other'; RetainedLabel = $false }
        @{ Label = 'KEYS'; Role = 'other'; RetainedLabel = $false }
        @{ Label = 'keys'; Role = 'retained'; RetainedLabel = $true }
        @{ Label = 'Keys'; Role = 'retained'; RetainedLabel = $true }
        @{ Label = 'KEYS'; Role = 'retained'; RetainedLabel = $true }
        @{ Label = 'dependency'; Role = 'retained with authored aliases'; RetainedLabel = $true; Existing = $true }
    ) {
        param($Label, $RetainedLabel, $Existing = $false)
        InModuleScope Avm.Authoring -Parameters @{
            Root = (Join-Path $TestDrive 'module')
            Label = $Label
            RetainedLabel = $RetainedLabel
            Existing = $Existing
        } {
            param($Root, $Label, $RetainedLabel, $Existing)
            $retainedName = if ($RetainedLabel) { $Label } else { 'avm_interfaces' }
            $otherName = if ($RetainedLabel) { 'other' } else { $Label }
            $dependency = Join-Path $Root '.published' 'interfaces'
            $modtm = 'registry.terraform.io/azure/modtm'
            $sources = @{
                $retainedName = [Collections.Generic.HashSet[string]]::new(
                    [string[]]@($modtm, 'registry.terraform.io/azure/azapi'), [StringComparer]::Ordinal)
                $otherName = [Collections.Generic.HashSet[string]]::new(
                    [string[]]@('registry.terraform.io/azure/azapi', 'terraform.io/builtin/terraform'), [StringComparer]::Ordinal)
            }
            $manifest = ConvertTo-Json -Depth 5 -Compress -InputObject @{
                Modules = @(
                    @{ Key = ''; Dir = '.' }
                    @{ Key = $retainedName; Source = 'Azure/avm-utl-interfaces/azure'; Version = '0.5.0'; Dir = $dependency }
                    @{ Key = $otherName; Source = './modules/other'; Dir = (Join-Path $Root 'modules' 'other') }
                )
            }
            $calls = @{
                $retainedName = @{ source = 'Azure/avm-utl-interfaces/azure'; version = '0.5.0'; mptf = @{} }
                $otherName = @{ source = './modules/other'; mptf = @{} }
            }
            Mock ConvertFrom-AvmTerraformModuleManifest {}
            Mock Get-ChildItem { @() }
            Mock Get-AvmTerraformUnitTestRequiredProvider {
                @{ modtm = @{ source = 'Azure/modtm'; version = '~> 0.3' } }
            }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -cne 'debug') {
                    throw [InvalidOperationException]::new('This pure test permits only mocked native inspection.')
                }
                [pscustomobject]@{ StdOut = $EnvVars['UNIT_CALLS_JSON']; ExitCode = 0; StdErr = '' }
            }
            $parameters = @{
                Path = $Root
                ModuleTargets = @([pscustomobject]@{ Path = $Root })
                Options = [pscustomobject]@{
                    ToolPath = 'mapotf'
                    ProfileDirs = @{ 'provider-restore' = 'provider-restore' }
                    EnvVars = @{ UNIT_CALLS_JSON = $calls | ConvertTo-Json -Depth 5 -Compress }
                }
                RequiredProviders = @{ $Root = @{} }
                ProviderSources = @{ $Root = @($modtm) }
                ModuleProviderSources = @{ $Root = $sources }
                ModuleManifests = @{ $Root = $manifest }
                OriginalRequirements = @{ $Root = @{ modtm = @{ source = 'Azure/modtm'; version = '~> 0.3' } } }
                Plans = @{}
                PlanningPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                BindDependencies = $true
            }
            $authored = @{ source = 'Azure/modtm'; version = '= 0.3.5'; configuration_aliases = @('modtm.owner') }
            if ($Existing) {
                $parameters.RequiredProviders[$Root].modtm = $authored
            }

            $plan = Get-AvmTerraformUnitTestModtmRequirementPlan @parameters

            $expectedDependencies = ConvertTo-Json -Compress -InputObject @($retainedName)
            $plan.Arguments | Should -Contain "unit_test_modtm_dependencies=$expectedDependencies"
            $plan.Arguments | Should -Not -Match '^unit_test_modtm_bindings='
            $plan.Capabilities | Should -Match 'contains\(keys\(data.module.unit_test_modtm_calls.result\[name\]\), "providers"\)'
            $parameters.RequiredProviders[$Root].modtm.source | Should -BeExactly 'Azure/modtm'
            if ($Existing) {
                $parameters.RequiredProviders[$Root].modtm | Should -Be $authored
                $plan.Arguments | Should -Contain 'unit_test_modtm_requirement=""'
            }
            else {
                $parameters.RequiredProviders[$Root].modtm.version | Should -BeExactly '~> 0.3'
            }
            $parameters.ModuleManifests[$Root] | Should -BeExactly $manifest
            $calls[$retainedName].version | Should -BeExactly '0.5.0'
            $parameters.Plans[$Root] | Should -Be $plan
            $parameters.PlanningPaths.Count | Should -Be 0
            Should -Invoke Get-AvmTerraformUnitTestRequiredProvider -Exactly 1 -ParameterFilter { $Path -ceq $dependency }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -ceq 'debug' }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'transform' }
        }
    }
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

        It 'inspects and counts both run targets with label <Label>' -ForEach @(
            @{ Label = 'Keys' }
            @{ Label = 'Values' }
            @{ Label = 'Count' }
        ) {
            foreach ($state in @($script:fixture.Before, $script:fixture.After)) {
                $state.test.runs[$Label] = $state.test.runs['root']
                $state.test.run_modules[$Label] = $state.test.run_modules['root']
                $state.test.runs.Remove('root')
                $state.test.run_modules.Remove('root')
            }
            $inspection = Read-UnitMigrationInspection -Fixture $script:fixture
            @($inspection.test.runs.get_Keys()) | Should -HaveCount 2
            $inspection.test.run_modules[$Label].dir | Should -BeExactly $script:fixture.Root
            $inspection.test.run_modules['child'].dir | Should -BeExactly $script:fixture.Child
            $inspection.test.runs[$Label].assert = @(
                @{ mptf = @{ attributes = @{ condition = 'length(random_uuid.telemetry) == 1' } } })
            $inspection.test.runs['child'].assert = @(
                @{ mptf = @{ attributes = @{ condition = 'length(random_uuid.telemetry) == 0' } } })
            InModuleScope Avm.Authoring -Parameters @{ Inspection = $inspection; Targets = $script:fixture.Targets } {
                param($Inspection, $Targets)
                (Get-AvmTerraformTelemetryTestCountMigration -Test $Inspection.test -ModuleTargets $Targets).ReferenceCount |
                    Should -Be 2
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





    Context 'baseline provider-tree selection' {
        BeforeEach {
            Mock Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring { $Scope.Inspection }
            Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
                @{ azapi = @{ source = 'Azure/azapi' } }
            }
            Mock Test-AvmTerraformScopedProviderInUse -ModuleName Avm.Authoring { $false }
            Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring {
                @('registry.terraform.io/azure/azapi')
            }
        }

        It 'does not load Terraform dependencies before fully mocked templates gain their inputs' {
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                Mock Get-AvmTerraformTestFileScope { $Fixture.Scope }
                $snapshots = @(Get-AvmTerraformUnitTestSnapshot -Root $Fixture.Root `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options)
                $snapshots[0].ProviderSources.Count | Should -Be 0
                Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 0
                Should -Invoke Test-AvmTerraformScopedProviderInUse -Exactly 2 -ParameterFilter {
                    $IncludeSelectedExamples -and $TargetPaths.Count -eq 2
                }
            }
        }

        It 'retains native baseline proof for a possible unmocked <LocalProvider> dependency' -TestCases @(
            @{ LocalProvider = 'random' }
            @{ LocalProvider = 'time' }
        ) {
            param($LocalProvider)
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; LocalProvider = $LocalProvider } {
                param($Fixture, $LocalProvider)
                Mock Get-AvmTerraformTestFileScope { $Fixture.Scope }
                Mock Test-AvmTerraformScopedProviderInUse { $Provider -ceq $LocalProvider }
                $snapshots = @(Get-AvmTerraformUnitTestSnapshot -Root $Fixture.Root `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options)
                $snapshots[0].ProviderSources.Count | Should -Be 2
                Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 2
            }
        }

        It 'does not request preservation proof for mocked <LocalProvider> requirements' -TestCases @(
            @{ LocalProvider = 'random' }
            @{ LocalProvider = 'time' }
        ) {
            param($LocalProvider)
            $script:fixture.After.test.mock_providers[$LocalProvider] = @{ mptf = @{ is_empty = $true } }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture; LocalProvider = $LocalProvider } {
                param($Fixture, $LocalProvider)
                Mock Get-AvmTerraformTestFileScope { $Fixture.Scope }
                Mock Get-AvmTerraformUnitTestRequiredProvider {
                    @{ azapi = @{ source = 'Azure/azapi' }; $LocalProvider = @{ source = "hashicorp/$LocalProvider" } }
                }
                $snapshots = @(Get-AvmTerraformUnitTestSnapshot -Root $Fixture.Root `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options)
                $snapshots[0].ProviderSources.Count | Should -Be 0
                Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 0
                Should -Invoke Test-AvmTerraformScopedProviderInUse -Exactly 0 -ParameterFilter {
                    $Provider -ceq $LocalProvider
                }
            }
        }

        It 'keeps native baseline proof when an authored mapping needs new AzAPI coverage for <Kind> telemetry' -TestCases @(
            @{ Kind = 'root'; Utility = $false }
            @{ Kind = 'planned utility'; Utility = $true }
        ) {
            param($Utility)
            $script:fixture.After.test.mock_providers.modtm = @{ mptf = @{ is_empty = $true } }
            $script:fixture.After.test.runs.root.mptf.attributes.providers = '{ modtm = modtm }'
            if ($Utility) {
                foreach ($target in $script:fixture.Targets) { $target.Profiles = @('module', 'common') }
                $script:fixture.Options | Add-Member -NotePropertyName UtilityTelemetryPaths -NotePropertyValue @($script:fixture.Root)
            }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                Mock Get-AvmTerraformTestFileScope { $Fixture.Scope }
                Mock Get-AvmTerraformUnitTestRequiredProvider { @{ modtm = @{ source = 'Azure/modtm' } } }
                $snapshots = @(Get-AvmTerraformUnitTestSnapshot -Root $Fixture.Root `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options)
                $snapshots[0].ProviderSources.Keys | Should -HaveCount 1
                $snapshots[0].ProviderSources.ContainsKey($Fixture.Root) | Should -BeTrue
                Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 1 -ParameterFilter { $Path -ceq $Fixture.Root }
            }
        }

        It 'preserves proof for an unmocked local provider declared under another name' {
            $script:fixture.After.test.mock_providers.time = @{ mptf = @{ is_empty = $true } }
            InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
                param($Fixture)
                Mock Get-AvmTerraformTestFileScope { $Fixture.Scope }
                Mock Get-AvmTerraformUnitTestRequiredProvider {
                    @{ azapi = @{ source = 'Azure/azapi' }; clock = @{ source = 'hashicorp/time' } }
                }
                $snapshots = @(Get-AvmTerraformUnitTestSnapshot -Root $Fixture.Root `
                        -ModuleTargets $Fixture.Targets -Options $Fixture.Options)
                $snapshots[0].ProviderSources.Count | Should -Be 2
                Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 2
            }
        }
    }

    Context 'built-in mock source proof' {
        It 'resolves only the proven mock identity: <Case>' -TestCases @(
            @{ Case = 'implicit built-in default'; Name = 'terraform'; Required = @{}; Sources = @('terraform.io/builtin/terraform'); Expected = @('terraform') }
            @{ Case = 'implicit built-in alias'; Name = 'terraform.unit'; Required = @{}; Sources = @('terraform.io/builtin/terraform'); Expected = @('terraform.unit') }
            @{ Case = 'explicit local name'; Name = 'native.unit'; Required = @{ native = @{ source = 'terraform.io/builtin/terraform' } }; Sources = @('terraform.io/builtin/terraform'); Expected = @('native.unit') }
            @{ Case = 'unproven built-in source'; Name = 'terraform'; Required = @{}; Sources = @('registry.terraform.io/hashicorp/random'); Expected = @() }
            @{ Case = 'existing registry inference'; Name = 'terraform'; Required = @{}; Sources = @('registry.terraform.io/hashicorp/terraform'); Expected = @('terraform') }
            @{ Case = 'different declared implementation'; Name = 'terraform'; Required = @{ terraform = @{ source = 'hashicorp/terraform' } }; Sources = @('terraform.io/builtin/terraform'); Expected = @() }
            @{ Case = 'explicit source disambiguation'; Name = 'terraform'; Required = @{ terraform = @{ source = 'terraform.io/builtin/terraform' } }; Sources = @('terraform.io/builtin/terraform', 'registry.terraform.io/hashicorp/terraform'); Expected = @('terraform') }
            @{ Case = 'no invented built-in mock'; Name = 'azapi'; Required = @{}; Sources = @('terraform.io/builtin/terraform'); Expected = @() }
        ) {
            param($Name, $Required, $Sources, $Expected)
            InModuleScope Avm.Authoring -Parameters @{ Name = $Name; Required = $Required; Sources = $Sources; Expected = $Expected } {
                param($Name, $Required, $Sources, $Expected)
                $actual = @(Get-AvmTerraformUnitTestMockProviderName -ProviderNames @($Name) `
                        -RequiredProviders $Required -ProviderSources $Sources)
                $actual.Count | Should -Be $Expected.Count
                if ($Expected.Count -gt 0) { $actual | Should -Be $Expected }
            }
        }

        It 'rejects ambiguous inferred built-in and <OtherSource> identities' -TestCases @(
            @{ OtherSource = 'registry.terraform.io/hashicorp/terraform' }
            @{ OtherSource = 'example.com/owner/terraform' }
        ) {
            param($OtherSource)
            InModuleScope Avm.Authoring -Parameters @{ OtherSource = $OtherSource } {
                param($OtherSource)
                { Get-AvmTerraformUnitTestMockProviderName -ProviderNames @('terraform') `
                        -RequiredProviders @{} -ProviderSources @('terraform.io/builtin/terraform', $OtherSource) } |
                    Should -Throw '*ambiguous built-in and registry provider evidence*'
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


}
