#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Terraform utility migration planning' {
    BeforeEach {
        InModuleScope Avm.Authoring -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $script:utilityRoot = $Root
            $script:utilityOptions = [pscustomobject]@{
                ToolPath = 'mapotf'; TerraformPath = 'terraform'; EnvVars = @{}
                InspectionRoot = Join-Path $Root 'inspection'
                ProfileDirs    = @{ 'utility-module' = 'utility-profile' }
            }
            $script:utilityInspection = @{
                calls = @{}; variables = @{}; requirements = @{}
                resources = @{}; data_sources = @{}; ephemeral = @{}
            }
            $script:utilityTargets = @([pscustomobject]@{ Path = $Root; Scope = 'root'; Profiles = @('root', 'module', 'common') })
            Mock Get-AvmTerraformUtilityInspection { $script:utilityInspection }
            Mock Get-ChildItem { @() }
        }
    }

    It 'plans literal exact pins without guessing: <Version>' -TestCases @(
        @{ Version = '0.1.0'; Upgrade = $true; ExpectedCount = 1 }
        @{ Version = '= 0.12.0'; Upgrade = $true; ExpectedCount = 1 }
        @{ Version = '0.13.0'; Upgrade = $false; ExpectedCount = 1 }
        @{ Version = '0.14.0'; Upgrade = $false; ExpectedCount = 0 }
    ) {
        param($Version, $Upgrade, $ExpectedCount)
        InModuleScope Avm.Authoring -Parameters @{ Version = $Version; Upgrade = $Upgrade; ExpectedCount = $ExpectedCount } {
            param($Version, $Upgrade, $ExpectedCount)
            $script:utilityInspection.calls.renamed = @{ source = 'registry.terraform.io/Azure/avm-utl-regions/azurerm'; version = $Version }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            $plans | Should -HaveCount $ExpectedCount
            if ($ExpectedCount) {
                $plans[0].Calls.renamed.Upgrade | Should -Be $Upgrade
                $plans[0].Calls.renamed.Version | Should -BeExactly '0.13.0'
                $plans[0].Before | Should -Be $script:utilityInspection
            }
        }
    }

    It 'rejects unprovable utility pins: <Version>' -TestCases @(
        @{ Version = $null }
        @{ Version = '~> 0.8' }
        @{ Version = '${var.version}' }
        @{ Version = '1.0.0-beta' }
        @{ Version = '01.2.3' }
        @{ Version = '999999999999999999999.0.0' }
    ) {
        param($Version)
        InModuleScope Avm.Authoring -Parameters @{ Version = $Version } {
            param($Version)
            $script:utilityInspection.calls.contracts = @{ source = 'Azure/avm-utl-interfaces/azure'; version = $Version }
            { Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions } |
                Should -Throw '*review*'
        }
    }

    It 'requires compatibility mode only for legacy naming and preserves modern callers' {
        InModuleScope Avm.Authoring {
            $script:utilityInspection.calls.old = @{ source = 'Azure/naming/azurerm'; version = '0.4.2'; legacy_mode = $true }
            $script:utilityInspection.calls.modern = @{ source = 'Azure/avm-utl-naming/azure'; version = '0.2.0'; legacy_mode = $false }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            $plans[0].Calls.Count | Should -Be 1
            $plans[0].Calls.old.Source | Should -BeExactly 'Azure/avm-utl-naming/azure'
            $plans[0].Calls.old.LegacyNaming | Should -BeTrue
            $script:utilityInspection.calls.old.legacy_mode = $false
            { Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions } |
                Should -Throw '*legacy_mode = true*'
        }
    }

    It 'orders local callers by dependency rather than directory depth' {
        InModuleScope Avm.Authoring {
            $child = Join-Path $script:utilityRoot 'modules' 'child'
            $wrapper = Join-Path $script:utilityRoot 'tests' 'wrapper'
            $script:utilityInspections = @{
                $script:utilityRoot = @{ calls = @{ nested = @{ source = './modules/child' } }; requirements = @{} }
                $child              = @{ calls = @{ arbitrary = @{ source = 'Azure/avm-utl-interfaces/azure'; version = '0.8.0' } }; requirements = @{} }
                $wrapper            = @{ calls = @{ parent = @{ source = '../..' } }; requirements = @{} }
            }
            Mock Get-AvmTerraformUtilityInspection { $script:utilityInspections[$Path] }
            $targets = @(
                [pscustomobject]@{ Path = $wrapper; Scope = 'test' }
                [pscustomobject]@{ Path = $script:utilityRoot; Scope = 'root' }
                [pscustomobject]@{ Path = $child; Scope = 'module' }
            )
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $script:utilityOptions)
            @($plans | ForEach-Object { $_.Target.Path }) | Should -Be @($child, $script:utilityRoot, $wrapper)
            @($plans | Where-Object Telemetry) | Should -HaveCount 3
            $script:utilityInspections[$child].calls.cycle = @{ source = '../..' }
            { Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $script:utilityOptions } |
                Should -Throw '*cyclic local module calls*'
        }
    }

    It 'includes local dependency proof without upgrading unrelated module calls' {
        InModuleScope Avm.Authoring {
            $example = Join-Path $script:utilityRoot 'examples' 'default'
            $script:utilityInspections = @{
                $script:utilityRoot = @{ calls = @{ custom = @{ source = 'Example/custom/azure'; version = '1.0.0' } }; requirements = @{} }
                $example            = @{
                    calls        = @{
                        parent    = @{ source = '../..' }
                        selection = @{ source = 'Azure/avm-utl-regions/azurerm'; version = '0.12.0' }
                    }
                    requirements = @{}
                }
            }
            Mock Get-AvmTerraformUtilityInspection { $script:utilityInspections[$Path] }
            $targets = @(
                [pscustomobject]@{ Path = $example; Scope = 'example' }
                [pscustomobject]@{ Path = $script:utilityRoot; Scope = 'root' }
            )
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $script:utilityOptions)
            @($plans | ForEach-Object { $_.Target.Path }) | Should -Be @($script:utilityRoot, $example)
            $plans[0].Affected | Should -BeFalse
            $plans[0].Calls.Count | Should -Be 0
            $plans[1].Affected | Should -BeTrue
        }
    }

    It 'fails a selected native profile capability check before any writing invocation' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmProcess { [pscustomobject]@{ StdOut = 'false' } }
            { Invoke-AvmTerraformUtilityPatch -Path $script:utilityRoot -Options $script:utilityOptions `
                    -Updates @{ region = 'version = "0.13.0"' } } | Should -Throw '*exact native patches*'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -ceq 'debug' }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'transform' }
        }
    }

    It 'skips empty patches and honors WhatIf without writing' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmProcess { [pscustomobject]@{ StdOut = 'true' } }
            Invoke-AvmTerraformUtilityPatch -Path $script:utilityRoot -Options $script:utilityOptions
            Should -Invoke Invoke-AvmProcess -Exactly 0
            Invoke-AvmTerraformUtilityPatch -Path $script:utilityRoot -Options $script:utilityOptions `
                -RemoveMaps region -WhatIf
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'transform' }
        }
    }

    It 'passes exact serialized patches to native transforms without evaluating expressions' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmProcess { [pscustomobject]@{ StdOut = 'true' } }
            Invoke-AvmTerraformUtilityPatch -Path $script:utilityRoot -Options $script:utilityOptions `
                -Updates @{ region = 'location = var.location' } -Mappings @{ region = '{ azapi = azapi.unit /* ${authored} */ }' } `
                -RemoveMaps retired -RemoveRequirements modtm -Inputs @{ location = 'required' }
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $ArgumentList[0] -ceq 'transform' -and
                ($ArgumentList -join "`n").Contains('$${authored}') -and
                $ArgumentList -contains 'remove_requirements=["modtm"]' -and
                $ArgumentList -contains 'remove_provider_maps=["retired"]'
            }
        }
    }

    It 'proves target providers in an isolated wrapper and caches only that exact source and version' {
        InModuleScope Avm.Authoring {
            Mock Get-AvmTerraformUnitTestProviderSource {
                $Path | Should -Not -BeExactly $script:utilityRoot
                [System.IO.File]::ReadAllText((Join-Path $Path 'main.tf')) |
                    Should -Match 'version = "0.13.0"'
                @('registry.terraform.io/azure/azapi')
            }
            $call = [pscustomobject]@{ Source = 'Azure/avm-utl-regions/azurerm'; Version = '0.13.0'; Telemetry = $true }
            $cache = @{}
            @(Get-AvmTerraformUtilityProviderSource -Call $call -Options $script:utilityOptions -Cache $cache) |
                Should -Be @('registry.terraform.io/azure/azapi')
            $null = Get-AvmTerraformUtilityProviderSource -Call $call -Options $script:utilityOptions -Cache $cache
            Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 1
        }
    }
}

Describe 'Terraform utility provider mapping proof' {
    It 'does not use root configuration proof to skip an independently selected random child' {
        InModuleScope Avm.Authoring -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $child = Join-Path $Root 'modules' 'independent'
            $scope = [pscustomobject]@{
                Owner = [pscustomobject]@{ Path = $Root }
                File  = [pscustomobject]@{ FullName = Join-Path $Root 'tests' 'unit' 'scopes.tftest.hcl' }
            }
            $targets = @(
                [pscustomobject]@{ Path = $Root; Profiles = @('root') }
                [pscustomobject]@{ Path = $child; Profiles = @('module') }
            )
            Mock Test-AvmTerraformProviderInUse { $ModulePath -ceq $child }
            Test-AvmTerraformScopedRandomProviderInUse -Scope $scope -ModuleTargets $targets `
                -TargetPaths @($child) -Cache @{} -ProviderSources @{ $Root = @('registry.terraform.io/azure/azapi') } |
                Should -BeTrue
            Should -Invoke Test-AvmTerraformProviderInUse -Exactly 1 -ParameterFilter { $ModulePath -ceq $child }
        }
    }

    It 'tracks only the repairable native warning and keeps ordinary inspection strict' {
        InModuleScope Avm.Authoring {
            $tree = "Providers required by configuration:`n.`n`u{2514}`u{2500}`u{2500} provider[registry.terraform.io/azure/modtm] ~> 0.3`n`n" +
            "Warning: Missing required provider configuration`n`nThe local caller needs a source binding.`n"
            $warnings = @{}
            @(ConvertFrom-AvmTerraformProviderTree -Text $tree -Path 'fixture' `
                    -AllowMissingProviderConfiguration -ProviderWarnings $warnings) |
                Should -Be @('registry.terraform.io/azure/modtm')
            $warnings.fixture | Should -BeTrue
            { ConvertFrom-AvmTerraformProviderTree -Text $tree -Path 'fixture' } |
                Should -Throw '*unexpected Terraform provider tree*'
            { ConvertFrom-AvmTerraformProviderTree -Text $tree -Path 'fixture' -AllowMissingProviderConfiguration } |
                Should -Throw '*diagnostic tracking*'
            $unknown = $tree.Replace('Missing required provider configuration', 'Unrecognized provider diagnostic')
            { ConvertFrom-AvmTerraformProviderTree -Text $unknown -Path 'fixture' `
                    -AllowMissingProviderConfiguration -ProviderWarnings @{} } |
                Should -Throw '*unexpected Terraform provider tree*'
        }
    }

    It 'refuses to finish utility cleanup while an intermediate provider diagnostic remains' {
        InModuleScope Avm.Authoring {
            $target = [pscustomobject]@{ Path = 'fixture'; Scope = 'root' }
            $requirements = @{ modtm = @{ source = 'Azure/modtm'; version = '~> 0.3' } }
            $scope = [pscustomobject]@{ Target = $target; Before = @{ requirements = $requirements }; Dependencies = @{} }
            $options = [pscustomobject]@{ UtilityProviderSources = @{} }
            Mock Get-AvmTerraformUtilityInspection {
                @{
                    calls = @{}; requirements = $requirements
                    resources = @{ modtm_telemetry = @{ custom = @{} } }; data_sources = @{}; ephemeral = @{}
                }
            }
            Mock Get-ChildItem { @() }
            Mock Invoke-AvmTerraformUtilityPatch
            Mock Get-AvmTerraformUnitTestModtmRequirementPlan
            Mock Invoke-AvmMapotfTransformTarget
            Mock Get-AvmTerraformUnitTestProviderSource {
                if ($AllowMissingProviderConfiguration) {
                    $ProviderWarnings[$Path] = $true
                    return @('registry.terraform.io/azure/modtm')
                }
                throw [AvmConfigurationException]::new('provider configuration is still incomplete')
            }
            { Invoke-AvmTerraformUtilityProviderCleanup -Plans @($scope) -ModuleTargets @($target) -Options $options } |
                Should -Throw '*still incomplete*'
            Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 1 -ParameterFilter { $AllowMissingProviderConfiguration }
            Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 1 -ParameterFilter { -not $AllowMissingProviderConfiguration }
            Should -Invoke Invoke-AvmMapotfTransformTarget -Exactly 0
        }
    }

    It 'removes only unused same-provider ModTM mappings and preserves other expressions and comments' {
        InModuleScope Avm.Authoring {
            $expression = @'
{
  modtm = modtm.unit # retain the annotation
  azapi = azapi.secondary
  random = random
}
'@
            $mapping = Get-AvmTerraformUtilityProviderMapping -Path 'fixture' -Name 'renamed' `
                -Call @{ providers = $expression } -ProviderSources @('registry.terraform.io/azure/azapi')
            $mapping.Changed | Should -BeTrue
            $mapping.Expression | Should -Match '# retain the annotation'
            $mapping.Expression | Should -Match 'azapi = azapi.secondary'
            $mapping.Expression | Should -Match 'random = random'
            $mapping.Expression | Should -Not -Match 'modtm\s*='
            Get-AvmTerraformUtilityProviderMapping -Path 'fixture' -Name 'renamed' `
                -Call @{ providers = $expression } -ProviderSources @('registry.terraform.io/azure/modtm') |
                Should -BeNullOrEmpty
        }
    }

    It 'requires review for an unprovable mapping: <Expression>' -TestCases @(
        @{ Expression = '{ modtm = azapi }' }
        @{ Expression = '{ modtm.unit = modtm.unit }' }
        @{ Expression = 'local.providers' }
        @{ Expression = '{ modtm = modtm, modtm = modtm }' }
    ) {
        param($Expression)
        InModuleScope Avm.Authoring -Parameters @{ Expression = $Expression } {
            param($Expression)
            { Get-AvmTerraformUtilityProviderMapping -Path 'fixture' -Name 'renamed' `
                    -Call @{ providers = $Expression } -ProviderSources @() } | Should -Throw '*require review*'
        }
    }

    It 'does not infer that an unexpected ModTM source is safe to remove' {
        InModuleScope Avm.Authoring {
            { Get-AvmTerraformUtilityProviderMapping -Path 'fixture' -Name 'renamed' `
                    -Call @{ providers = '{ modtm = modtm }' } -ProviderSources @('example.com/custom/modtm') } |
                Should -Throw '*provider source*'
        }
    }
}
