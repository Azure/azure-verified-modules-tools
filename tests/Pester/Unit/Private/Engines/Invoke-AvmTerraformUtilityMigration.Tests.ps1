#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

function global:New-UtilityMigrationInspection {
    param(
        [Parameter(Mandatory)] [hashtable] $Inspection,
        [switch] $PreserveSelections
    )

    $result = @{}
    foreach ($entry in $Inspection.GetEnumerator()) {
        $result[$entry.Key] = $entry.Value
    }
    $targetVersions = @{
        'azure/avm-utl-regions/azurerm'  = [version]'0.13.0'
        'azure/avm-utl-interfaces/azure' = [version]'0.9.0'
        'azure/naming/azurerm'           = [version]'0.2.0'
    }
    $review = @{}
    $calls = @{}
    foreach ($name in $result.calls.Keys) {
        $call = $result.calls[$name]
        $source = ([string]$call.source).ToLowerInvariant() -creplace '^registry[.]terraform[.]io/', ''
        if (-not $targetVersions.ContainsKey($source)) { continue }
        $match = [regex]::Match([string]$call.version, '\A(?:=\s*)?(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)\z')
        if (-not $match.Success) {
            $review[$name] = @{}
            continue
        }
        try {
            $version = [version]($match.Value -creplace '^=\s*', '')
        }
        catch {
            $review[$name] = @{}
            continue
        }
        $legacy = $source -ceq 'azure/naming/azurerm'
        if (-not $PreserveSelections -and ($legacy -or $version -le $targetVersions[$source])) {
            $calls[$name] = @{
                telemetry        = -not $legacy
                provider_source  = if ($legacy) { 'Azure/avm-utl-naming/azure' } else { $call.source }
                provider_version = $targetVersions[$source].ToString()
            }
        }
    }
    $result.migration = @{ review = $review; calls = $calls }
    return $result
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
            Mock Get-AvmTerraformUtilityInspection {
                New-UtilityMigrationInspection -Inspection $script:utilityInspection -PreserveSelections:$PreserveSelections
            }
            Mock Get-ChildItem { @() }
            Mock Invoke-AvmTerraformUtilityNativeMigration {}
            Mock Get-AvmTerraformUtilityProviderSource { @() }
            Mock Assert-AvmTerraformUtilityProviderMappingReview { @{ Configurations = @(); Aliases = @() } }
        }
    }

    It 'preserves exact utility selections without bypassing inspection: <Source>' -ForEach @(
        @{ Source = 'Azure/avm-utl-regions/azurerm'; Version = '0.12.0' }
        @{ Source = 'Azure/avm-utl-interfaces/azure'; Version = '0.8.0' }
        @{ Source = 'registry.terraform.io/Azure/naming/azurerm'; Version = '0.4.3' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Source = $Source; Version = $Version } {
            param($Source, $Version)
            $script:utilityInspection.calls.original = @{
                source = $Source; version = $Version
                providers = '{ azapi = azapi.original }'; location = 'var.original_location'
            }
            $before = $script:utilityInspection | ConvertTo-Json -Depth 10
            @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets `
                    -Options $script:utilityOptions -PreserveSelections) | Should -HaveCount 0
            ($script:utilityInspection | ConvertTo-Json -Depth 10) | Should -BeExactly $before
            Should -Invoke Get-AvmTerraformUtilityInspection -Exactly 1
        }
    }

    It 'still rejects ambiguous pins while preserving selections: <Version>' -ForEach @(
        @{ Version = $null }
        @{ Version = '~> 0.12' }
        @{ Version = '0.12.0-beta' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Version = $Version } {
            param($Version)
            $script:utilityInspection.calls.regions = @{ source = 'Azure/avm-utl-regions/azurerm'; version = $Version }
            { Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets `
                    -Options $script:utilityOptions -PreserveSelections } | Should -Throw '*review*'
        }
    }

    It 'inspects retained ModTM contracts without enabling utility upgrades: <Preserve>' -ForEach @(
        @{ Preserve = $true; Version = '0.12.0' }
        @{ Preserve = $false; Version = '99.0.0' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Preserve = $Preserve; Version = $Version } {
            param($Preserve, $Version)
            $script:utilityInspection.requirements.modtm = @{ source = 'Azure/modtm'; version = '~> 0.3' }
            $script:utilityInspection.calls.original = @{
                source = 'Azure/avm-utl-regions/azurerm'; version = $Version
                providers = '{ modtm = modtm, azapi = azapi.original }'
            }
            $before = $script:utilityInspection | ConvertTo-Json -Depth 10
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets `
                    -Options $script:utilityOptions -PreserveSelections:$Preserve)
            $plans | Should -HaveCount 1
            $plans[0].Affected | Should -BeTrue
            $plans[0].Telemetry | Should -BeFalse
            $plans[0].Calls.Count | Should -Be 0
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 1 -ParameterFilter {
                -not $ApplyUtilityMigration
            }
            Should -Invoke Get-AvmTerraformUtilityProviderSource -Exactly 0
            ($script:utilityInspection | ConvertTo-Json -Depth 10) | Should -BeExactly $before
        }
    }

    It 'does not select leaf provider requirements for dependency inspection' {
        InModuleScope Avm.Authoring {
            $script:utilityInspection.requirements.modtm = @{ source = 'Azure/modtm'; version = '~> 0.3' }
            @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets `
                    -Options $script:utilityOptions) | Should -HaveCount 0
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
                $plans[0].Calls.renamed.Telemetry | Should -BeTrue
                $plans[0].Before.calls.renamed.source | Should -BeExactly 'registry.terraform.io/Azure/avm-utl-regions/azurerm'
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

    It 'surfaces a later native review before applying any selected scope' {
        InModuleScope Avm.Authoring {
            $child = Join-Path $script:utilityRoot 'modules' 'review'
            $script:utilityInspections = @{
                $script:utilityRoot = @{
                    calls = @{ regions = @{ source = 'Azure/avm-utl-regions/azurerm'; version = '0.12.0' } }
                    variables = @{}; requirements = @{}; resources = @{}; data_sources = @{}; ephemeral = @{}
                }
                $child = @{
                    calls = @{ interfaces = @{ source = 'Azure/avm-utl-interfaces/azure'; version = '~> 0.8' } }
                    variables = @{}; requirements = @{}; resources = @{}; data_sources = @{}; ephemeral = @{}
                }
            }
            Mock Get-AvmTerraformUtilityInspection {
                $inspection = $script:utilityInspections[$Path]
                $inspection.migration = if ($Path -ceq $child) {
                    @{ review = @{ interfaces = @{} }; calls = @{} }
                }
                else {
                    @{
                        review = @{}
                        calls  = @{
                            regions = @{
                                telemetry        = $true
                                provider_source  = 'Azure/avm-utl-regions/azurerm'
                                provider_version = '0.13.0'
                            }
                        }
                    }
                }
                $inspection
            }
            $targets = @(
                [pscustomobject]@{ Path = $script:utilityRoot; Scope = 'root' }
                [pscustomobject]@{ Path = $child; Scope = 'module' }
            )
            { Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $script:utilityOptions } |
                Should -Throw '*requires review*'
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 0
        }
    }

    It 'limits the naming conversion to old sources and preserves AVM version/mode: <Version>, <Mode>' -ForEach @(
        @{ Version = '0.2.0'; Mode = $true }
        @{ Version = '0.2.0'; Mode = $false }
        @{ Version = '99.0.0'; Mode = $true }
        @{ Version = '>= 0.2.0'; Mode = $false }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Version = $Version; Mode = $Mode } {
            param($Version, $Mode)
            $script:utilityInspection.calls.old = @{ source = 'Azure/naming/azurerm'; version = '0.4.2' }
            $script:utilityInspection.calls.modern = @{ source = 'Azure/avm-utl-naming/azure'; version = $Version; legacy_mode = $Mode }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            $plans[0].Calls.Count | Should -Be 1
            $plans[0].Calls.old.Telemetry | Should -BeFalse
            Mock Invoke-AvmTerraformUtilityNativeMigration { $Scope | Should -BeExactly 'root' }
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 1
            $script:utilityInspection.calls.modern.version | Should -BeExactly $Version
            $script:utilityInspection.calls.modern.legacy_mode | Should -Be $Mode
        }
    }

    It 'selects modern mode when an old-source call already contains a mode input: <Mode>' -ForEach @(
        @{ Mode = $true }
        @{ Mode = $false }
        @{ Mode = 'var.use_legacy' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mode = $Mode } {
            param($Mode)
            $script:utilityInspection.calls.names = @{
                source = 'Azure/naming/azurerm'; version = '0.4.2'; legacy_mode = $Mode
            }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            Mock Invoke-AvmTerraformUtilityNativeMigration { $Scope | Should -BeExactly 'root' }
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 1
        }
    }

    It 'matches registry identity instead of labels or lookalike sources: <Source>' -ForEach @(
        @{ Source = 'Azure/avm-utl-interfaces/azure'; Expected = 1 }
        @{ Source = 'registry.terraform.io/azure/avm-utl-interfaces/azure'; Expected = 1 }
        @{ Source = 'Azure/avm-utl-regions/azurerm'; Expected = 1 }
        @{ Source = 'example.com/Azure/avm-utl-regions/azurerm'; Expected = 0 }
        @{ Source = './avm-utl-regions'; Expected = 0 }
        @{ Source = 'git::https://github.com/Azure/terraform-azure-avm-utl-regions?ref=v0.8.0'; Expected = 0 }
        @{ Source = 'Azure/avm-utl-regions/azurerm//modules/child'; Expected = 0 }
        @{ Source = 'Azure/avm-utl-naming/azure'; Expected = 0 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Source = $Source; Expected = $Expected } {
            param($Source, $Expected)
            $script:utilityInspection.calls.unrelated_label = @{ source = $Source; version = '0.8.0' }
            @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions) |
                Should -HaveCount $Expected
        }
    }

    It 'does not downgrade Interfaces and leaves current pins unmodified: <Version>' -ForEach @(
        @{ Version = '0.7.0'; Upgrade = $true; Expected = 1 }
        @{ Version = '= 0.8.0'; Upgrade = $true; Expected = 1 }
        @{ Version = '0.9.0'; Upgrade = $false; Expected = 1 }
        @{ Version = '0.10.0'; Upgrade = $false; Expected = 0 }
        @{ Version = '1.0.0'; Upgrade = $false; Expected = 0 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Version = $Version; Upgrade = $Upgrade; Expected = $Expected } {
            param($Version, $Upgrade, $Expected)
            $script:utilityInspection.calls.contracts = @{ source = 'Azure/avm-utl-interfaces/azure'; version = $Version }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            $plans | Should -HaveCount $Expected
            if ($Expected) {
                $plans[0].Calls.contracts.Telemetry | Should -BeTrue
            }
        }
    }

    It 'emits exact missing-input patches for <Scope> without using region lookup outputs' -ForEach @(
        @{ Scope = 'root'; Location = 'required'; Telemetry = $true }
        @{ Scope = 'module'; Location = 'required'; Telemetry = $true }
        @{ Scope = 'example'; Location = 'example'; Telemetry = $true }
        @{ Scope = 'test'; Location = 'required'; Telemetry = $false }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Scope = $Scope; Location = $Location; Telemetry = $Telemetry } {
            param($Scope, $Location, $Telemetry)
            $script:utilityTargets[0].Scope = $Scope
            $script:utilityInspection.calls.choose_region = @{ source = 'Azure/avm-utl-regions/azurerm'; version = '0.12.0' }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            Mock Invoke-AvmTerraformUtilityNativeMigration { $Scope | Should -BeExactly $Scope }
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 1
        }
    }

    It 'does not declare or explicitly bind a child-only AzAPI dependency: <Declared>' -ForEach @(
        @{ Declared = $false }
        @{ Declared = $true }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Declared = $Declared } {
            param($Declared)
            $script:utilityTargets[0].Scope = 'example'
            $script:utilityTargets[0].Profiles = @('example', 'provider-cleanup', 'common')
            $script:utilityInspection.calls.regions = @{ source = 'Azure/avm-utl-regions/azurerm'; version = '0.12.0' }
            if ($Declared) {
                $script:utilityInspection.requirements.azapi = @{ source = 'Azure/azapi'; version = '~> 2.4' }
            }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            if ($Declared) {
                $script:utilityInspection.requirements.azapi.version | Should -BeExactly '~> 2.4'
            }
        }
    }

    It 'completes an existing explicit utility map without replacing its bindings: <Declared>' -ForEach @(
        @{ Declared = $false }
        @{ Declared = $true }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Declared = $Declared } {
            param($Declared)
            $script:utilityTargets[0].Scope = 'example'
            $script:utilityTargets[0].Profiles = @('example')
            $script:utilityInspection.calls.interfaces = @{
                source = 'Azure/avm-utl-interfaces/azure'; version = '0.8.0'
                providers = '{ random = random.original /* keep random */ }'
            }
            if ($Declared) {
                $script:utilityInspection.requirements.azapi = @{ source = 'Azure/azapi'; version = '~> 2.4' }
            }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 1
        }
    }

    It 'preserves an authored utility alias when its parent requirement already exists' {
        InModuleScope Avm.Authoring {
            $script:utilityTargets[0].Scope = 'example'
            $script:utilityTargets[0].Profiles = @('example')
            $script:utilityInspection.calls.regions = @{
                source = 'Azure/avm-utl-regions/azurerm'; version = '0.12.0'
                providers = '{ azapi = azapi.management /* keep subscription */ }'
            }
            $script:utilityInspection.requirements.azapi = @{ source = 'Azure/azapi'; version = '~> 2.12' }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 1
        }
    }

    It 'does not introduce bindings in implicit local callers of a migrated utility' {
        InModuleScope Avm.Authoring {
            $child = Join-Path $script:utilityRoot 'modules' 'child'
            $script:utilityInspections = @{
                $script:utilityRoot = @{
                    calls = @{ child = @{ source = './modules/child' } }
                    requirements = @{}; variables = @{}
                }
                $child = @{
                    calls = @{ regions = @{ source = 'Azure/avm-utl-regions/azurerm'; version = '0.12.0' } }
                    requirements = @{}; variables = @{}
                }
            }
            Mock Get-AvmTerraformUtilityInspection { New-UtilityMigrationInspection -Inspection $script:utilityInspections[$Path] }
            $targets = @(
                [pscustomobject]@{ Path = $script:utilityRoot; Scope = 'example'; Profiles = @('example') }
                [pscustomobject]@{ Path = $child; Scope = 'module'; Profiles = @('module') }
            )
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $script:utilityOptions)
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 2
        }
    }

    It 'preserves authored call locations and opt-outs: <Location>, <Telemetry>' -ForEach @(
        @{ Location = 'each.value.region'; Telemetry = $false }
        @{ Location = '"westus3"'; Telemetry = $true }
        @{ Location = $null; Telemetry = $null }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Location = $Location; Telemetry = $Telemetry } {
            param($Location, $Telemetry)
            $script:utilityInspection.calls.choose_region = @{
                source = 'Azure/avm-utl-regions/azurerm'; version = '0.12.0'
                location = $Location; enable_telemetry = $Telemetry; for_each = 'var.regions'
            }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            Mock Invoke-AvmTerraformUtilityNativeMigration { $Scope | Should -BeExactly 'root' }
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 1
        }
    }

    It 'reuses authored input declarations and selects default modern naming without rewriting compatible inputs' {
        InModuleScope Avm.Authoring {
            $script:utilityInspection.calls.regions = @{ source = 'Azure/avm-utl-regions/azurerm'; version = '0.12.0' }
            $script:utilityInspection.calls.names = @{
                source = 'Azure/naming/azurerm'; version = '0.4.2'; suffix = 'var.suffix'
                'unique-length' = 8; 'unique-seed' = 'original'
            }
            $script:utilityInspection.variables.location = @{ type = 'string'; default = 'authored' }
            $script:utilityInspection.variables.enable_telemetry = @{ type = 'bool'; default = $false }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:utilityTargets -Options $script:utilityOptions)
            Mock Invoke-AvmTerraformUtilityNativeMigration { $Scope | Should -BeExactly 'root' }
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:utilityOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 1
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
            Mock Get-AvmTerraformUtilityInspection { New-UtilityMigrationInspection -Inspection $script:utilityInspections[$Path] }
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
            Mock Get-AvmTerraformUtilityInspection { New-UtilityMigrationInspection -Inspection $script:utilityInspections[$Path] }
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

    It 'includes every caller of a shared migration dependency with reverse target order <Reverse>' -ForEach @(
        @{ Reverse = $false }
        @{ Reverse = $true }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Reverse = $Reverse } {
            param($Reverse)
            $example = Join-Path $script:utilityRoot 'examples' 'default'
            $complete = Join-Path $script:utilityRoot 'examples' 'complete'
            $wrapper = Join-Path $script:utilityRoot 'tests' 'wrapper'
            $unrelated = Join-Path $script:utilityRoot 'modules' 'unrelated'
            $providers = '{ azapi = azapi.management /* keep subscription */ azurerm = azurerm.management }'
            $script:utilityInspections = @{
                $script:utilityRoot = @{
                    calls = @{ dependency = @{ source = 'Azure/avm-res-resources-resourcegroup/azurerm'; version = '0.4.0' } }
                    requirements = @{}
                }
                $example = @{
                    calls = @{
                        parent = @{ source = '../..' }
                        naming = @{ source = 'Azure/naming/azurerm'; version = '0.4.4' }
                    }
                    requirements = @{}
                }
                $complete = @{ calls = @{ parent = @{ source = '../..'; providers = $providers } }; requirements = @{} }
                $wrapper = @{ calls = @{ complete = @{ source = '../../examples/complete' } }; requirements = @{} }
                $unrelated = @{ calls = @{}; requirements = @{} }
            }
            Mock Get-AvmTerraformUtilityInspection { New-UtilityMigrationInspection -Inspection $script:utilityInspections[$Path] }
            $targets = @(
                [pscustomobject]@{ Path = $wrapper; Scope = 'test' }
                [pscustomobject]@{ Path = $complete; Scope = 'example' }
                [pscustomobject]@{ Path = $example; Scope = 'example' }
                [pscustomobject]@{ Path = $unrelated; Scope = 'module' }
                [pscustomobject]@{ Path = $script:utilityRoot; Scope = 'root' }
            )
            if ($Reverse) { [array]::Reverse($targets) }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $script:utilityOptions)
            $paths = @($plans | ForEach-Object { $_.Target.Path })
            $paths | Should -HaveCount 4
            $paths | Should -Not -Contain $unrelated
            $paths.IndexOf($script:utilityRoot) | Should -BeLessThan $paths.IndexOf($complete)
            $paths.IndexOf($complete) | Should -BeLessThan $paths.IndexOf($wrapper)
            @($plans | Where-Object Affected | ForEach-Object { $_.Target.Path }) | Should -Be @($example)
            @($plans | Where-Object Telemetry) | Should -HaveCount 0
            ($plans | Where-Object { $_.Target.Path -ceq $complete }).Before.calls.parent.providers | Should -BeExactly $providers
            $script:utilityInspections[$script:utilityRoot].calls.dependency.version | Should -BeExactly '0.4.0'

            $script:utilityInspections[$complete].calls.cycle = @{ source = '../../tests/wrapper' }
            { Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $script:utilityOptions } |
                Should -Throw '*cyclic local module calls*'
        }
    }

}

Describe 'Terraform utility module label collisions' {
    BeforeEach {
        InModuleScope Avm.Authoring -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $script:labelRoot = $Root
            $script:labelChild = Join-Path $Root 'modules' 'key'
            $script:labelSibling = Join-Path $Root 'modules' 'secret'
            $script:labelTargets = @(
                [pscustomobject]@{ Path = $Root; Scope = 'root' }
                [pscustomobject]@{ Path = $script:labelChild; Scope = 'module' }
                [pscustomobject]@{ Path = $script:labelSibling; Scope = 'module' }
            )
            $script:labelOptions = [pscustomobject]@{
                ToolPath = 'mapotf'
                EnvVars = @{}
                ProfileDirs = @{ 'utility-module' = 'utility-profile' }
                UtilityProviderSources = @{}
            }
            Mock Invoke-AvmProcess {
                $json = if ($WorkingDirectory -ceq $script:labelRoot) {
                    '{"calls":{"LABEL":{"source":"./modules/key","mptf":{"block_address":"module.LABEL"}},"secrets":{"source":"./modules/secret","mptf":{"block_address":"module.secrets"}}},"variables":{},"requirements":{"azapi":{"source":"Azure/azapi","version":"~> 2.12"}},"resources":{},"data_sources":{},"ephemeral":{},"migration":{"review":{},"calls":{}}}'.Replace('LABEL', $script:labelName)
                }
                elseif ($WorkingDirectory -ceq $script:labelChild) {
                    '{"calls":{"regions":{"source":"Azure/avm-utl-regions/azurerm","version":"0.12.0","mptf":{"block_address":"module.regions"}}},"variables":{},"requirements":{},"resources":{},"data_sources":{},"ephemeral":{},"migration":{"review":{},"calls":{"regions":{"telemetry":true,"provider_source":"Azure/avm-utl-regions/azurerm","provider_version":"0.13.0"}}}}'
                }
                else {
                    '{"calls":{},"variables":{},"requirements":{},"resources":{},"data_sources":{},"ephemeral":{},"migration":{"review":{},"calls":{}}}'
                }
                [pscustomobject]@{ StdOut = $json }
            }
            Mock Get-ChildItem { @() }
            Mock Get-AvmTerraformUnitTestRequiredProvider {
                ConvertFrom-Json -InputObject '{"azapi":{"source":"Azure/azapi","version":"~> 2.12"}}' -AsHashtable
            }
            Mock Get-AvmTerraformUnitTestProviderSource {
                if ($Path -ceq $script:labelChild) { return @('registry.terraform.io/azure/azapi') }
                if ($Path -ceq $script:labelSibling) { return @('registry.terraform.io/hashicorp/random') }
                return @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/random')
            }
            Mock Assert-AvmTerraformUtilityProviderMappingReview { @{ Configurations = @(); Aliases = @() } }
            Mock Get-AvmTerraformUtilityProviderConfigurationFact { @{ Configurations = @(); Aliases = @() } }
            Mock Invoke-AvmTerraformUtilityNativeMigration {}
            Mock Invoke-AvmMapotfTransformTarget {}
        }
    }

    It 'traverses both local children and cleans up provider facts with label <Label>' -ForEach @(
        @{ Label = 'ordinary' }
        @{ Label = 'keys' }
        @{ Label = 'Keys' }
        @{ Label = 'values' }
        @{ Label = 'Values' }
        @{ Label = 'Count' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Label = $Label } {
            param($Label)
            $script:labelName = $Label
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:labelTargets -Options $script:labelOptions)
            $plans | Should -HaveCount 3
            $paths = @($plans | ForEach-Object { $_.Target.Path })
            $paths.IndexOf($script:labelChild) | Should -BeLessThan $paths.IndexOf($script:labelRoot)
            $paths.IndexOf($script:labelSibling) | Should -BeLessThan $paths.IndexOf($script:labelRoot)
            $rootPlan = $plans | Where-Object { $_.Target.Path -ceq $script:labelRoot }
            $rootPlan.Before.calls.GetType().FullName | Should -BeExactly 'System.Management.Automation.OrderedHashtable'
            $rootPlan.Dependencies.GetType().FullName | Should -BeExactly 'System.Collections.Hashtable'
            @($rootPlan.Dependencies.get_Keys()) | Should -HaveCount 2
            $rootPlan.Dependencies[$Label] | Should -BeExactly $script:labelChild
            $rootPlan.Dependencies['secrets'] | Should -BeExactly $script:labelSibling
            $rootPlan.Telemetry | Should -BeTrue

            Invoke-AvmTerraformUtilityProviderCleanup -Plans $plans -ModuleTargets $script:labelTargets -Options $script:labelOptions
            Should -Invoke Assert-AvmTerraformUtilityProviderMappingReview -ParameterFilter {
                $Path -ceq $script:labelRoot -and
                $ProviderSourceFacts.ContainsKey($script:labelName) -and
                $ProviderSourceFacts.ContainsKey('secrets') -and
                $ProviderSourceFacts[$script:labelName] -contains 'registry.terraform.io/azure/azapi' -and
                $ProviderSourceFacts['secrets'] -contains 'registry.terraform.io/hashicorp/random' -and
                $CallsRequiringAzapi -contains $script:labelName
            } -Exactly 1
            $script:labelOptions.UtilityProviderSources[$script:labelRoot] |
                Should -Be @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/random')
        }
    }

    It 'forwards local telemetry for label <Label> while preserving the sibling' -ForEach @(
        @{ Label = 'ordinary' }
        @{ Label = 'keys' }
        @{ Label = 'Keys' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Label = $Label } {
            param($Label)
            $script:labelName = $Label
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $script:labelTargets -Options $script:labelOptions)
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:labelOptions
            Should -Invoke Assert-AvmTerraformUtilityProviderMappingReview -Exactly 1 -ParameterFilter {
                $Path -ceq $script:labelRoot -and $CallsRequiringAzapi -contains $script:labelName -and
                $CallsRequiringAzapi -notcontains 'secrets'
            }
        }
    }

    It 'plans a selected utility with label <Label>' -ForEach @(
        @{ Label = 'ordinary' }
        @{ Label = 'keys' }
        @{ Label = 'Keys' }
        @{ Label = 'values' }
        @{ Label = 'Values' }
        @{ Label = 'count' }
        @{ Label = 'Count' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Label = $Label } {
            param($Label)
            $script:labelName = $Label
            Mock Invoke-AvmProcess {
                $json = '{"calls":{"LABEL":{"source":"Azure/avm-utl-regions/azurerm","version":"0.12.0","mptf":{"block_address":"module.LABEL"}}},"variables":{},"requirements":{},"resources":{},"data_sources":{},"ephemeral":{},"migration":{"review":{},"calls":{"LABEL":{"telemetry":true,"provider_source":"Azure/avm-utl-regions/azurerm","provider_version":"0.13.0"}}}}'.Replace('LABEL', $script:labelName)
                [pscustomobject]@{ StdOut = $json }
            }
            $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets @($script:labelTargets[0]) -Options $script:labelOptions)
            $plans | Should -HaveCount 1
            @($plans[0].Calls.get_Keys()) | Should -Be @($Label)
            $plans[0].Affected | Should -BeTrue
            $plans[0].Telemetry | Should -BeTrue
            Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $script:labelOptions
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 1 -ParameterFilter {
                $Path -ceq $script:labelRoot -and $ApplyUtilityMigration
            }
        }
    }
}

Describe 'Terraform provider contract call labels' {
    It 'retains both incoming provider bindings when a local call is named Values' {
        InModuleScope Avm.Authoring -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $child = Join-Path $Root 'modules' 'key'
            $sibling = Join-Path $Root 'modules' 'secret'
            $targets = @(
                [pscustomobject]@{ Path = $Root }
                [pscustomobject]@{ Path = $child }
                [pscustomobject]@{ Path = $sibling }
            )
            $options = [pscustomobject]@{
                ToolPath = 'mapotf'
                EnvVars = @{}
                ProfileDirs = @{ 'provider-contract' = 'profile' }
            }
            Mock Invoke-AvmProcess {
                $json = if ($WorkingDirectory -ceq $Root) {
                    '{"calls":{"Values":{"source":"./modules/key","providers":["azapi.owner"]},"secrets":{"source":"./modules/secret","providers":["random"]}},"requirements":{}}'
                }
                else {
                    '{"calls":{},"requirements":{}}'
                }
                [pscustomobject]@{ StdOut = $json }
            }
            $bindings = Get-AvmTerraformProviderContractBinding -Targets $targets -Snapshots @() -Options $options
            @($bindings[$child]) | Should -Be @('azapi')
            @($bindings[$sibling]) | Should -Be @('random')
        }
    }
}

Describe 'Terraform utility provider mapping proof' {
    It 'reconciles only selected local callers whose child no longer declares ModTM' {
        InModuleScope Avm.Authoring -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $retired = Join-Path $Root 'modules' 'retired'
            $retained = Join-Path $Root 'modules' 'retained'
            $unselected = Join-Path $Root 'modules' 'unselected'
            $targets = @(
                [pscustomobject]@{
                    Target = [pscustomobject]@{ Path = $Root; Scope = 'root' }
                    Dependencies = @{ retired = $retired; retained = $retained; unselected = $unselected }
                }
                [pscustomobject]@{
                    Target = [pscustomobject]@{ Path = Join-Path $Root 'examples' 'management'; Scope = 'example' }
                    Dependencies = @{ shared = $retired }
                }
            )
            Mock Get-AvmTerraformUnitTestRequiredProvider {
                if ($Path -ceq $retained) { return @{ modtm = @{ source = 'Azure/modtm'; version = '~> 0.3' } } }
                return @{}
            }
            Mock Assert-AvmTerraformUtilityProviderMappingReview {
                $CallsRequiringAzapi | Should -HaveCount 0
                $ProviderSourceFacts.Count | Should -Be 1
                @($ProviderSourceFacts.Values)[0] | Should -HaveCount 0
                @{ Configurations = @(); Aliases = @() }
            }
            Mock Invoke-AvmTerraformUtilityNativeMigration {}
            Sync-AvmTerraformLocalProviderMapping -Plans $targets -Options ([pscustomobject]@{}) `
                -DependencyPaths @($retired, $retained)
            Should -Invoke Get-AvmTerraformUnitTestRequiredProvider -Exactly 1 -ParameterFilter { $Path -ceq $retired }
            Should -Invoke Get-AvmTerraformUnitTestRequiredProvider -Exactly 1 -ParameterFilter { $Path -ceq $retained }
            Should -Invoke Get-AvmTerraformUnitTestRequiredProvider -Exactly 0 -ParameterFilter { $Path -ceq $unselected }
            Should -Invoke Invoke-AvmTerraformUtilityNativeMigration -Exactly 2 -ParameterFilter {
                -not $ApplyUtilityMigration -and -not $ProviderFactsComplete -and
                -not $ProviderSourceFacts.ContainsKey('retained') -and -not $ProviderSourceFacts.ContainsKey('unselected')
            }
        }
    }

    It 'repairs local caller contracts before every potentially retiring dependency inspection' {
        InModuleScope Avm.Authoring {
            $target = [pscustomobject]@{ Path = 'fixture'; Scope = 'root' }
            $scope = [pscustomobject]@{ Target = $target; Before = @{ requirements = @{} }; Dependencies = @{} }
            $options = [pscustomobject]@{ UtilityProviderSources = @{} }
            $script:providerSequence = [System.Collections.Generic.List[string]]::new()
            Mock Sync-AvmTerraformLocalProviderMapping { $script:providerSequence.Add('repair') }
            Mock Get-AvmTerraformUtilityInspection { @{ requirements = @{} } }
            Mock Assert-AvmTerraformUtilityProviderMappingReview { @{ Configurations = @(); Aliases = @() } }
            Mock Get-AvmTerraformUtilityProviderConfigurationFact { @{ Configurations = @(); Aliases = @() } }
            Mock Invoke-AvmTerraformUtilityNativeMigration {
                $script:providerSequence.Add($(if ($ProviderFactsComplete) { 'retire' } else { 'map' }))
            }
            Mock Get-AvmTerraformUnitTestProviderSource {
                $script:providerSequence.Add('inspect')
                @()
            }
            Mock Invoke-AvmMapotfTransformTarget {}
            Invoke-AvmTerraformUtilityProviderCleanup -Plans @($scope) -ModuleTargets @($target) -Options $options
            @($script:providerSequence) | Should -Be @('repair', 'map', 'inspect', 'retire', 'repair', 'inspect')
        }
    }

    It 'rejects incomplete native response shapes before writing: <Json>' -ForEach @(
        @{ Json = 'not json' }
        @{ Json = 'null' }
        @{ Json = '{"calls":{}}' }
        @{ Json = '{"calls":[],"variables":{},"requirements":{},"resources":{},"data_sources":{},"ephemeral":{}}' }
        @{ Json = '{"calls":{"example":{"source":"Azure/avm-utl-regions/azurerm"}},"variables":{},"requirements":{},"resources":{},"data_sources":{},"ephemeral":{}}' }
        @{ Json = '{"calls":{"example":{"source":"Azure/avm-utl-regions/azurerm","mptf":{"block_address":"module.wrong"}}},"variables":{},"requirements":{},"resources":{},"data_sources":{},"ephemeral":{}}' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Json = $Json } {
            param($Json)
            Mock Invoke-AvmProcess { [pscustomobject]@{ StdOut = $Json } }
            $options = [pscustomobject]@{
                ToolPath = 'mapotf'; EnvVars = @{}; ProfileDirs = @{ 'utility-module' = 'profile' }
            }
            { Get-AvmTerraformUtilityInspection -Path 'fixture' -Options $options } | Should -Throw '*Cannot inspect utility*'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -ceq 'debug' }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'transform' }
        }
    }

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
            Mock Invoke-AvmTerraformUtilityNativeMigration
            Mock Assert-AvmTerraformUtilityProviderMappingReview { @{ Configurations = @(); Aliases = @() } }
            Mock Get-AvmTerraformUtilityProviderConfigurationFact { @{ Configurations = @(); Aliases = @() } }
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
            Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 2 -ParameterFilter { $AllowMissingProviderConfiguration }
            Should -Invoke Get-AvmTerraformUnitTestProviderSource -Exactly 1 -ParameterFilter { -not $AllowMissingProviderConfiguration }
            Should -Invoke Invoke-AvmMapotfTransformTarget -Exactly 0
        }
    }

    It 'surfaces native provider-map review before a transform writes' {
        InModuleScope Avm.Authoring {
            $options = [pscustomobject]@{
                ToolPath = 'mapotf'; EnvVars = @{}; ProfileDirs = @{ 'utility-module' = 'profile' }
            }
            Mock Get-AvmTerraformUtilityProviderConfigurationFact { @{ Configurations = @(); Aliases = @() } }
            Mock Invoke-AvmProcess { [pscustomobject]@{ StdOut = '{"regions":{}}' } }
            {
                Assert-AvmTerraformUtilityProviderMappingReview -Path 'fixture' -Options $options `
                    -ProviderSourceFacts @{ regions = @('registry.terraform.io/azure/azapi') } `
                    -CallsRequiringAzapi regions
            } | Should -Throw '*requires review*'
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[0] -ceq 'debug' }
        }
    }
}
