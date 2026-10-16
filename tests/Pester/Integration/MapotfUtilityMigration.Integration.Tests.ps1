#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: MAPOTF utility module migration' -Tag Integration -Skip:($env:AVM_OFFLINE -eq '1') -ForEach (@(
        @{ UtilityFixture = 'terraform-azure-avm-res-mock' }
    ) | Where-Object { -not $env:AVM_INTEGRATION_FIXTURE -or $_.UtilityFixture -eq $env:AVM_INTEGRATION_FIXTURE }) {
    BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:options = InModuleScope Avm.Authoring -Parameters @{ ModuleRoot = $moduleRoot; InspectionRoot = (Join-Path $TestDrive 'inspection') } {
            param($ModuleRoot, $InspectionRoot)
            $terraform = Resolve-AvmTool -Name terraform
            $environment = New-AvmToolPathEnvironment -ToolPath $terraform.Path -ToolName terraform
            foreach ($name in @('TF_DATA_DIR', 'TF_PLUGIN_CACHE_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_get',
                    'TF_CLI_ARGS_init', 'TF_CLI_ARGS_test', 'TF_CLI_ARGS_validate', 'TF_VAR_location')) {
                $environment[$name] = $null
            }
            $environment.MODTM_ENDPOINT = 'http://127.0.0.1:1'
            [pscustomobject]@{
                ToolPath       = (Resolve-AvmTool -Name mapotf).Path
                TerraformPath  = $terraform.Path
                ProfileDirs    = @{
                    'utility-module'    = Join-Path $ModuleRoot 'Resources' 'mapotf' 'utility-module'
                    module              = Join-Path $ModuleRoot 'Resources' 'mapotf' 'module'
                    'unit-test-inspect' = Join-Path $ModuleRoot 'Resources' 'mapotf' 'unit-test-inspect'
                }
                EnvVars        = $environment
                InspectionRoot = $InspectionRoot
            }
        }
        function Invoke-UtilityProcess {
            param([string] $Root, [string[]] $Arguments)
            InModuleScope Avm.Authoring -Parameters @{ Root = $Root; Arguments = $Arguments; Options = $script:options } {
                param($Root, $Arguments, $Options)
                Invoke-AvmProcess -FilePath $Options.TerraformPath -ArgumentList $Arguments `
                    -WorkingDirectory $Root -EnvVars $Options.EnvVars
            }
        }
        function Invoke-UtilityEngine {
            param([string] $Root, [switch] $CheckDrift)
            InModuleScope Avm.Authoring -Parameters @{ Root = $Root; CheckDrift = [bool]$CheckDrift } {
                param($Root, $CheckDrift)
                Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' }) -CheckDrift:$CheckDrift
            }
        }
        function Invoke-UtilityMigration {
            param([string] $Root, [string] $Scope = 'root')
            InModuleScope Avm.Authoring -Parameters @{ Root = $Root; Scope = $Scope; Options = $script:options } {
                param($Root, $Scope, $Options)
                $targets = @([pscustomobject]@{
                        Path = $Root; Scope = $Scope
                        Profiles = if ($Scope -ceq 'root') { @('root', 'module', 'common') } else { @('module', 'common') }
                    })
                $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $Options)
                Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $Options
                Get-AvmTerraformUtilityInspection -Path $Root -Options $Options
            }
        }
    }
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:root
        $script:main = Join-Path $script:root 'main.tf'
    }
    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'upgrades only older exact pins for <Source> <Version>' -TestCases @(
        @{ Source = 'Azure/avm-utl-regions/azurerm'; Version = '0.1.0'; Expected = '0.13.0' }
        @{ Source = 'registry.terraform.io/Azure/avm-utl-regions/azurerm'; Version = '= 0.12.0'; Expected = '0.13.0' }
        @{ Source = 'Azure/avm-utl-regions/azurerm'; Version = '0.13.0'; Expected = '0.13.0' }
        @{ Source = 'Azure/avm-utl-regions/azurerm'; Version = '1.0.0'; Expected = '1.0.0' }
        @{ Source = 'Azure/avm-utl-interfaces/azure'; Version = '0.8.0'; Expected = '0.9.0' }
        @{ Source = 'registry.terraform.io/azure/avm-utl-interfaces/azure'; Version = '0.9.0'; Expected = '0.9.0' }
        @{ Source = 'Azure/avm-utl-interfaces/azure'; Version = '0.10.0'; Expected = '0.10.0' }
    ) {
        param($Source, $Version, $Expected)
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @"
module "unrelated_label" {
  source = "$Source"
  version = "$Version"
  location = each.value.region
  enable_telemetry = false
  for_each = var.regions
}
"@
        $inspection = Invoke-UtilityMigration -Root $script:root
        $call = $inspection.calls.unrelated_label
        $call.source | Should -BeExactly $Source
        $call.version | Should -BeExactly $Expected
        $call.location | Should -BeExactly 'each.value.region'
        $call.enable_telemetry | Should -BeFalse
        $call.for_each | Should -BeExactly 'var.regions'
        $first = [System.IO.File]::ReadAllBytes($script:main)
        $null = Invoke-UtilityMigration -Root $script:root
        [System.IO.File]::ReadAllBytes($script:main) | Should -Be $first
        Test-Path -LiteralPath (Join-Path $script:root 'variables.tf') | Should -BeFalse
    }

    It 'adds independent missing location and opt-out inputs for <Scope>' -TestCases @(
        @{ Scope = 'root'; Default = $false; Telemetry = $true }
        @{ Scope = 'module'; Default = $false; Telemetry = $true }
        @{ Scope = 'example'; Default = $true; Telemetry = $true }
        @{ Scope = 'test'; Default = $false; Telemetry = $false }
    ) {
        param($Scope, $Default, $Telemetry)
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    azapi = { source = "Azure/azapi", version = "~> 2.12" }
  }
}
module "choose_location" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.12.0"
  is_recommended = true
}
output "region" {
  value = module.choose_location.regions[0].name
}
'@
        $inspection = Invoke-UtilityMigration -Root $script:root -Scope $Scope
        $inspection.calls.choose_location.location | Should -BeExactly 'var.location'
        $inspection.calls.choose_location.Contains('enable_telemetry') | Should -Be $Telemetry
        $inspection.variables.location.Contains('default') | Should -Be $Default
        if ($Default) { $inspection.variables.location.default | Should -BeExactly 'eastus' }
        $inspection.variables.location.nullable | Should -BeFalse
        $inspection.variables.Contains('enable_telemetry') | Should -Be $Telemetry
        $first = Get-Content -LiteralPath $script:main -Raw
        $null = Invoke-UtilityMigration -Root $script:root -Scope $Scope
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $first
    }

    It 'replaces legacy naming in compatibility mode without changing labels inputs or references' {
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "names" {
  source = "registry.terraform.io/Azure/naming/azurerm"
  version = "0.4.2"
  prefix = ["existing"]
  suffix = var.suffix
  unique-length = 8
  unique-seed = "seed"
}
module "modern" {
  source = "Azure/avm-utl-naming/azure"
  version = "0.2.0"
  legacy_mode = false
}
output "deprecated_name" {
  value = module.names.resource_group.name_unique
}
moved {
  from = module.old_names
  to = module.names
}
'@
        $inspection = Invoke-UtilityMigration -Root $script:root
        $inspection.calls.names.source | Should -BeExactly 'Azure/avm-utl-naming/azure'
        $inspection.calls.names.version | Should -BeExactly '0.2.0'
        $inspection.calls.names.legacy_mode | Should -BeTrue
        $inspection.calls.names.'unique-length' | Should -Be 8
        $inspection.calls.names.'unique-seed' | Should -BeExactly 'seed'
        $inspection.calls.names.suffix | Should -BeExactly 'var.suffix'
        $inspection.calls.modern.legacy_mode | Should -BeFalse
        $content = Get-Content -LiteralPath $script:main -Raw
        $content | Should -Match 'module.names.resource_group.name_unique'
        $content | Should -Match 'from = module.old_names'
        $content | Should -Match 'to\s*= module.names'
        $null = Invoke-UtilityMigration -Root $script:root
        Get-Content -LiteralPath $script:main -Raw | Should -BeExactly $content
    }

    It 'rejects ambiguous utility versions without writing: <Version>' -TestCases @(
        @{ Version = '"~> 0.12"' }
        @{ Version = '">= 0.1, < 1"' }
        @{ Version = 'var.module_version' }
        @{ Version = '"0.13.0-beta.1"' }
    ) {
        param($Version)
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @"
module "regions" {
  source = "Azure/avm-utl-regions/azurerm"
  version = $Version
}
"@
        $before = [System.IO.File]::ReadAllBytes($script:main)
        { Invoke-UtilityMigration -Root $script:root } | Should -Throw '*literal exact version pin*'
        [System.IO.File]::ReadAllBytes($script:main) | Should -Be $before
        @(Get-ChildItem -LiteralPath $script:root -Filter '*.mptfbackup') | Should -HaveCount 0
    }

    It 'does not rewrite custom local Git or modern naming sources' {
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "regions" {
  source = "../avm-utl-regions"
}
module "interfaces" {
  source = "git::https://github.com/Azure/terraform-azure-avm-utl-interfaces?ref=v0.8.0"
}
module "naming" {
  source = "example.com/Azure/naming/azurerm"
  version = "~> 0.4"
}
module "modern" {
  source = "Azure/avm-utl-naming/azure"
  version = "0.2.0"
}
'@
        $before = [System.IO.File]::ReadAllBytes($script:main)
        $null = Invoke-UtilityMigration -Root $script:root
        [System.IO.File]::ReadAllBytes($script:main) | Should -Be $before
    }

    It 'retires obsolete bindings for old and already-upgraded utility pins: <Version>' -TestCases @(
        @{ Version = '0.12.0' }
        @{ Version = '0.13.0' }
    ) {
        param($Version)
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @"
module "region_lookup" {
  source = "Azure/avm-utl-regions/azurerm"
  version = "$Version"
  location = "northeurope"
  enable_telemetry = false
  providers = {
    modtm = modtm # Preserve this explanation.
    azapi = azapi.custom
    random = random
  }
}
"@
        $data = Invoke-UtilityMigration -Root $script:root
        $data.calls.region_lookup.providers | Should -Not -Match '\bmodtm\s*='
        $data.calls.region_lookup.providers | Should -Match 'azapi\s*=\s*azapi.custom'
        $data.calls.region_lookup.providers | Should -Match 'random\s*=\s*random'
        $data.calls.region_lookup.providers | Should -Match '# Preserve this explanation.'
        $data.calls.region_lookup.location | Should -BeExactly 'northeurope'
        $data.calls.region_lookup.enable_telemetry | Should -BeFalse
    }

    It 'preserves naming outputs and random state across the source migration' {
        $before = Join-Path $script:root 'modules' 'before'
        $after = Join-Path $script:root 'modules' 'after'
        $unit = Join-Path $script:root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $before, $after, $unit -Force
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    random = { source = "hashicorp/random", version = ">= 3.3.2, < 4.0" }
  }
}
'@
        $configuration = @'
module "names" {
  source = "Azure/naming/azurerm"
  version = "0.4.2"
  prefix = ["existing"]
  suffix = ["safe"]
  unique-length = 8
}
output "name" {
  value = module.names.resource_group.name
}
output "name_unique" {
  value = module.names.resource_group.name_unique
}
'@
        foreach ($path in @($before, $after)) {
            Set-Content -LiteralPath (Join-Path $path 'main.tf') -Value $configuration -Encoding utf8NoBOM
        }
        $null = Invoke-UtilityMigration -Root $after
        Set-Content -LiteralPath (Join-Path $unit 'continuity.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "random" {
  mock_resource "random_string" {
    defaults = { result = "originalrandomseed" }
  }
}
mock_provider "random" {
  alias = "after"
  mock_resource "random_string" {
    defaults = { result = "mustnotregenerate" }
  }
}
run "legacy" {
  command = apply
  state_key = "naming"
  module {
    source = "./modules/before"
  }
  providers = { random = random }
}
run "upgraded" {
  command = plan
  state_key = "naming"
  module {
    source = "./modules/after"
  }
  providers = { random = random.after }
  assert {
    condition = output.name == run.legacy.name && output.name_unique == run.legacy.name_unique
    error_message = "The compatibility migration must preserve names and existing random state."
  }
}
'@
        $null = Invoke-UtilityProcess -Root $script:root -Arguments @('init', '-backend=false', '-input=false', '-no-color', '-test-directory=tests/unit')
        $result = Invoke-UtilityProcess -Root $script:root -Arguments @('test', '-no-color', '-test-directory=tests/unit')
        $result.StdOut | Should -Match 'Success! 2 passed'
    }

    It 'retires region-only random mocks across selected examples and test wrappers without drift writes' {
        $unit = Join-Path $script:root 'tests' 'unit'
        $wrapper = Join-Path $script:root 'tests' 'wrapper'
        $example = Join-Path $script:root 'examples' 'default'
        $null = New-Item -ItemType Directory -Path $unit, $wrapper, $example -Force
        Set-Content -LiteralPath (Join-Path $script:root 'metadata.json') -Encoding utf8NoBOM `
            -Value '{"canonicalType":"Microsoft.Resources/resourceGroups","telemetryIdPrefix":"46d3xtrf.res.a1b2c3d"}'
        $requirements = @'
terraform {
  required_providers {
    azapi = { source = "Azure/azapi", version = "~> 2.4" }
    modtm = { source = "Azure/modtm", version = "~> 0.3" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
'@
        foreach ($path in @($script:root, $wrapper, $example)) {
            Set-Content -LiteralPath (Join-Path $path 'terraform.tf') -Value $requirements -Encoding utf8NoBOM
        }
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
variable "enable_telemetry" {
  type = bool
  default = true
}
module "choose_region" {
  source = "Azure/avm-utl-regions/azurerm"
  version = "0.12.0"
  providers = { modtm = modtm }
  enable_telemetry = false
}
output "region_count" {
  value = length(module.choose_region.regions)
}
'@
        foreach ($path in @($wrapper, $example)) {
            Set-Content -LiteralPath (Join-Path $path 'main.tf') -Encoding utf8NoBOM -Value @'
module "root" {
  source = "../.."
  providers = { modtm = modtm }
  enable_telemetry = false
}
output "region_count" {
  value = module.root.region_count
}
'@
        }
        $testFile = Join-Path $unit 'scopes.tftest.hcl'
        Set-Content -LiteralPath $testFile -Encoding utf8NoBOM -Value @'
mock_provider "azapi" {}
mock_provider "modtm" {}
mock_provider "random" {}
run "root" {
  command = plan
  providers = { azapi = azapi, modtm = modtm, random = random }
  variables {
    enable_telemetry = false
  }
  assert {
    condition = output.region_count > 0
    error_message = "The regions data must remain available."
  }
}
run "example" {
  command = plan
  providers = { azapi = azapi, modtm = modtm, random = random }
  module {
    source = "./examples/default"
  }
  variables {
    enable_telemetry = false
  }
}
run "wrapper" {
  command = plan
  providers = { azapi = azapi, modtm = modtm, random = random }
  module {
    source = "./tests/wrapper"
  }
}
'@
        $before = InModuleScope Avm.Authoring -Parameters @{ Root = $script:root } {
            param($Root)
            Get-AvmFileSnapshot -Path @((Get-AvmTerraformFile -Root $Root -IncludeBackup).FullName)
        }
        $drift = Invoke-UtilityEngine -Root $script:root -CheckDrift
        $drift.Status | Should -BeExactly 'fail'
        $drift.Changed | Should -Contain 'main.tf'
        foreach ($path in $before.Keys) { [System.IO.File]::ReadAllBytes($path) | Should -Be $before[$path] }
        @(Get-ChildItem -LiteralPath $script:root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $script:root '.terraform') | Should -BeFalse
        (Invoke-UtilityEngine -Root $script:root).Status | Should -BeExactly 'pass'
        $test = Get-Content -LiteralPath $testFile -Raw
        $test | Should -Not -Match 'mock_provider "(modtm|random)"'
        $test | Should -Match 'mock_provider "azapi"'
        foreach ($path in @($script:root, $wrapper, $example)) {
            $inspection = InModuleScope Avm.Authoring -Parameters @{ Path = $path; Options = $script:options } {
                param($Path, $Options)
                Get-AvmTerraformUtilityInspection -Path $Path -Options $Options
            }
            $inspection.requirements.Contains('modtm') | Should -BeFalse
            $inspection.requirements.Contains('random') | Should -BeFalse
            $inspection.requirements.azapi.source | Should -BeExactly 'Azure/azapi'
            if ($path -ceq $wrapper) { $inspection.variables.Contains('enable_telemetry') | Should -BeFalse }
        }
        $testDirectory = 'tests/unit'
        if ($IsWindows) {
            # Windows Terraform cannot reuse module caches under test-file directory keys.
            $runtimeTest = Join-Path $script:root 'scopes.runtime.tftest.hcl'
            Copy-Item -LiteralPath $testFile -Destination $runtimeTest
            [System.IO.File]::ReadAllBytes($runtimeTest) | Should -Be ([System.IO.File]::ReadAllBytes($testFile))
            $testDirectory = 'tests'
        }
        $null = Invoke-UtilityProcess -Root $script:root -Arguments @('init', '-backend=false', '-input=false', '-no-color', "-test-directory=$testDirectory")
        $result = Invoke-UtilityProcess -Root $script:root -Arguments @('test', '-no-color', "-test-directory=$testDirectory")
        $result.StdOut | Should -Match 'Success! 3 passed'
    }

    foreach ($case in @(
            @{ Manifest = 'fresh' }
            @{ Manifest = 'stale' }
            @{ Manifest = 'retained ModTM' }
        )) {
        It "migrates real dependencies before cleanup and runs mocked tests with $($case.Manifest) data" -TestCases $case {
            param($Manifest)
            $child = Join-Path $script:root 'modules' 'helper'
            $unit = Join-Path $script:root 'tests' 'unit'
            $null = New-Item -ItemType Directory -Path $child, $unit -Force
            Set-Content -LiteralPath (Join-Path $script:root 'metadata.json') -Encoding utf8NoBOM `
                -Value '{"canonicalType":"Microsoft.Resources/resourceGroups","telemetryIdPrefix":"46d3xtrf.res.a1b2c3d"}'
            Set-Content -LiteralPath (Join-Path $child 'metadata.json') -Encoding utf8NoBOM -Value '{"canonicalType":"helper"}'
            Set-Content -LiteralPath (Join-Path $script:root 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    azapi = { source = "Azure/azapi", version = "~> 2.12" }
    modtm = { source = "Azure/modtm", version = "~> 0.3" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
'@
            Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "selection" {
  source = "Azure/avm-utl-regions/azurerm"
  version = "0.12.0"
  providers = { modtm = modtm }
  is_recommended = true
  enable_telemetry = false
}
module "names" {
  source = "Azure/naming/azurerm"
  version = "0.4.2"
  suffix = ["safe"]
}
module "child" {
  source = "./modules/helper"
  providers = { modtm = modtm }
}
output "name" {
  value = module.names.resource_group.name
}
'@
            Set-Content -LiteralPath (Join-Path $script:root 'main.telemetry.tf') -Encoding utf8NoBOM -Value @'
variable "enable_telemetry" {
  type = bool
  default = true
}
resource "random_uuid" "telemetry" {
  count = var.enable_telemetry ? 1 : 0
}
data "modtm_module_source" "telemetry" {
  count = var.enable_telemetry ? 1 : 0
  module_path = path.module
}
resource "modtm_telemetry" "telemetry" {
  count = var.enable_telemetry ? 1 : 0
  tags = {
    module_version = one(data.modtm_module_source.telemetry).module_version
  }
}
'@
            Set-Content -LiteralPath (Join-Path $child 'main.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    modtm = { source = "Azure/modtm", version = "~> 0.3" }
  }
}
module "contracts" {
  source = "Azure/avm-utl-interfaces/azure"
  version = "0.8.0"
  providers = { modtm = modtm }
  enable_telemetry = false
}
'@
            $testFile = Join-Path $unit 'utilities.tftest.hcl'
            Set-Content -LiteralPath $testFile -Encoding utf8NoBOM -Value @'
mock_provider "azapi" {}
mock_provider "modtm" {}
mock_provider "random" {}
variables {
  enable_telemetry = false
}
run "utilities" {
  command = plan
  assert {
    condition = output.name == "rg-safe"
    error_message = "Preserve the legacy named output."
  }
  assert {
    condition = length(module.selection.regions) > 0
    error_message = "Keep the region-selection data."
  }
}
'@
            $manifestPath = Join-Path $script:root '.terraform' 'modules' 'modules.json'
            if ($Manifest -ceq 'retained ModTM') {
                $dependency = Join-Path $script:root '.retained'
                $intermediate = Join-Path $script:root 'modules' 'retained-helper'
                $null = New-Item -ItemType Directory -Path $dependency, $intermediate -Force
                $mainSource = (Get-Content -LiteralPath $script:main -Raw).Replace(
                    'version = "0.4.2"', "version = `"0.4.2`"`n  providers = { random = random }")
                Set-Content -LiteralPath $script:main -Value $mainSource -Encoding utf8NoBOM
                Set-Content -LiteralPath (Join-Path $intermediate 'metadata.json') -Encoding utf8NoBOM -Value '{"canonicalType":"helper"}'
                Set-Content -LiteralPath (Join-Path $intermediate 'main.tf') -Encoding utf8NoBOM -Value @'
module "dependency" {
  source = "../../.retained"
}
output "id" {
  value = module.dependency.id
}
'@
                Set-Content -LiteralPath (Join-Path $dependency 'main.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    modtm = { source = "Azure/modtm", version = "~> 0.3" }
  }
}
resource "modtm_telemetry" "custom" {
  tags = { fixture = "mocked-only" }
}
output "id" {
  value = modtm_telemetry.custom.id
}
'@
                Add-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "retained" {
  source = "./modules/retained-helper"
}
'@
                $source = (Get-Content -LiteralPath $testFile -Raw).Replace('mock_provider "modtm" {}', @'
mock_provider "modtm" {
  mock_resource "modtm_telemetry" {
    defaults = { id = "retained" }
  }
}
'@).Replace('condition = output.name == "rg-safe"', 'condition = output.name == "rg-safe" && module.retained.id == "retained"').
                Replace('command = plan', 'command = apply')
                Set-Content -LiteralPath $testFile -Value $source -Encoding utf8NoBOM
            }
            if ($Manifest -ceq 'stale') {
                $null = Invoke-UtilityProcess -Root $script:root -Arguments @('get', '-no-color')
                $manifestBefore = [System.IO.File]::ReadAllBytes($manifestPath)
            }
            $result = Invoke-UtilityEngine -Root $script:root
            $result.Status | Should -BeExactly 'pass'
            $result.Changed | Should -Contain 'main.tf'
            $result.Changed | Should -Contain ([System.IO.Path]::Combine('modules', 'helper', 'main.tf'))
            if ($Manifest -ceq 'stale') { [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $manifestBefore }
            else { Test-Path -LiteralPath $manifestPath | Should -BeFalse }
            Test-Path -LiteralPath (Join-Path $script:root '.terraform.lock.hcl') | Should -BeFalse
            $calls = InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Options = $script:options } {
                param($Root, $Options)
                Get-AvmTerraformUtilityInspection -Path $Root -Options $Options
            }
            $calls.calls.selection.version | Should -BeExactly '0.13.0'
            $calls.calls.selection.enable_telemetry | Should -BeFalse
            $calls.calls.selection.location | Should -BeExactly 'var.location'
            $calls.calls.child.providers | Should -Match 'azapi\s*=\s*azapi'
            $calls.calls.child.providers | Should -Not -Match 'modtm'
            $calls.requirements.Contains('modtm') | Should -Be ($Manifest -ceq 'retained ModTM')
            $testContent = Get-Content -LiteralPath $testFile -Raw
            if ($Manifest -ceq 'retained ModTM') {
                $testContent | Should -Match 'mock_resource "modtm_telemetry"'
                $calls.calls.retained.providers | Should -Match 'modtm\s*=\s*modtm'
                $calls.calls.names.providers | Should -Match 'random\s*=\s*random'
                $calls.requirements.random.version | Should -BeExactly '~> 3.6'
            }
            else { $testContent | Should -Not -Match 'mock_provider "modtm"' }
            $testContent | Should -Match 'mock_provider "random"'
            $testContent | Should -Match 'location\s*=\s*"eastus"'
            Get-Content -LiteralPath (Join-Path $script:root 'main.telemetry.tf') -Raw |
                Should -Match '(?s)from\s*=\s*modtm_telemetry.telemetry.*?destroy\s*=\s*false'
            $first = InModuleScope Avm.Authoring -Parameters @{ Root = $script:root } {
                param($Root)
                Get-AvmFileSnapshot -Path @((Get-AvmTerraformFile -Root $Root).FullName)
            }
            $drift = Invoke-UtilityEngine -Root $script:root -CheckDrift
            $drift.Status | Should -BeExactly 'pass'
            $drift.Changed | Should -HaveCount 0
            foreach ($path in $first.Keys) { [System.IO.File]::ReadAllBytes($path) | Should -Be $first[$path] }
            $null = Invoke-UtilityProcess -Root $script:root -Arguments @('init', '-backend=false', '-input=false', '-no-color', '-test-directory=tests/unit')
            $validation = Invoke-UtilityProcess -Root $script:root -Arguments @('validate', '-json')
            ($validation.StdOut | ConvertFrom-Json).valid | Should -BeTrue
            $tests = Invoke-UtilityProcess -Root $script:root -Arguments @('test', '-no-color', '-test-directory=tests/unit')
            $tests.StdOut | Should -Match 'Success! 1 passed'
        }
    }
}
