#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: MAPOTF utility module migration' -Tag Qualification {
BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        . (Join-Path $PSScriptRoot '..' '..' 'Helpers' 'TerraformQualification.ps1')
        . (Join-Path $PSScriptRoot '..' '..' 'Helpers' 'TerraformAcceptance.ps1')
        $script:profilesRoot = Join-Path $moduleRoot 'Resources' 'mapotf'
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
            param([string] $Root, [string[]] $Arguments, [object[]] $ModuleTargets = @())
            if ($Arguments[0] -cin @('apply', 'destroy', 'import')) {
                throw [InvalidOperationException]::new('Qualification forbids direct real-provider mutation commands.')
            }
            if ($Arguments[0] -ceq 'test') {
                return Invoke-MockedTerraformQualification -TerraformPath $script:options.TerraformPath `
                    -MapotfPath $script:options.ToolPath -ProfilesRoot $script:profilesRoot `
                    -Root $Root -ArgumentList $Arguments -Environment $script:options.EnvVars -ModuleTargets $ModuleTargets
            }
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

It 'preserves exact legacy utility selections in an example root through public commands and native mocked execution' {
        $previous = [Environment]::GetEnvironmentVariable('AVM_TF_UTILITY_MIGRATION')
        $context = $null
        try {
            $env:AVM_TF_UTILITY_MIGRATION = 'preserve'
            $example = Join-Path $script:root 'examples' 'default'
            $unit = Join-Path $script:root 'tests' 'unit'
            $null = New-Item -ItemType Directory -Path $example, $unit -Force
            $null = Initialize-AvmModuleMetadata -Path $script:root -Ecosystem terraform -ModuleType utility -InputObject @{
                moduleDisplayName = 'Utility preservation'
                moduleDescription = 'Verifies existing utility selections without dependency migrations.'
                canonicalType = 'utility-preservation'
                owners = @()
            }
            $requirements = @'
terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6, < 4.0"
    }
  }
}
'@
            foreach ($path in @($script:root, $example)) {
                Set-Content -LiteralPath (Join-Path $path 'terraform.tf') -Value $requirements -Encoding utf8NoBOM
                Set-Content -LiteralPath (Join-Path $path '_header.md') -Value '# Utility preservation' -Encoding utf8NoBOM
                Set-Content -LiteralPath (Join-Path $path '_footer.md') -Value '' -Encoding utf8NoBOM
            }
            Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value ".terraform/`n*.tfstate*" -Encoding utf8NoBOM
            $legacyCalls = @'
module "regions" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.12.0"
  providers = {
    azapi  = azapi
    modtm  = modtm
    random = random
  }

  enable_telemetry = var.enable_telemetry
  region_filter    = ["eastus"]
  use_cached_data  = true
}

module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.3"
  providers = {
    random = random
  }

  prefix = ["existing"]
  suffix = ["safe"]
}
'@
            Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
module "regions" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.12.0"
  providers = {
    azapi  = azapi
    modtm  = modtm
    random = random
  }

  enable_telemetry = false
  region_filter    = ["eastus"]
  use_cached_data  = true
}

locals {
  resource_group_name = var.name
}
'@
            Set-Content -LiteralPath (Join-Path $script:root 'variables.tf') -Encoding utf8NoBOM -Value @'
variable "name" {
  type        = string
  description = "The existing resource group name."
  nullable    = false
}
'@
            Set-Content -LiteralPath (Join-Path $script:root 'outputs.tf') -Encoding utf8NoBOM -Value @'
output "region_name" {
  description = "The original regions library's cached region name."
  value       = module.regions.regions_by_name["eastus"].name
}

output "resource_group_name" {
  description = "The existing resource group name."
  value       = local.resource_group_name
}
'@
            $exampleCall = @'
module "example" {
  source = "../.."
  providers = {
    azapi  = azapi
    modtm  = modtm
    random = random
  }

  name = module.naming.resource_group.name
}
'@
            Set-Content -LiteralPath (Join-Path $example 'main.tf') -Value "$legacyCalls`n`n$exampleCall" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $example 'outputs.tf') -Encoding utf8NoBOM -Value @'
output "region_name" {
  description = "The original regions library's cached region name."
  value       = module.example.region_name
}

output "resource_group_name" {
  description = "The original naming library's resource group name."
  value       = module.example.resource_group_name
}
'@
            Set-Content -LiteralPath (Join-Path $example 'variables.tf') -Encoding utf8NoBOM -Value @'
variable "enable_telemetry" {
  type        = bool
  default     = false
  description = "Whether the existing regions dependency emits telemetry."
}
'@
            Set-Content -LiteralPath (Join-Path $unit 'legacy.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
mock_provider "modtm" {}
mock_provider "random" {}

run "legacy_naming" {
  command = apply
  module {
    source = "./examples/default"
  }
  providers = {
    azapi  = azapi
    modtm  = modtm
    random = random
  }

  assert {
    condition     = output.resource_group_name == "existing-rg-safe"
    error_message = "Preservation must retain the legacy naming output for existing caller inputs."
  }

  assert {
    condition     = output.region_name == "eastus"
    error_message = "Preservation must retain cached region lookup for existing caller inputs."
  }
}
'@
            foreach ($file in Get-ChildItem -LiteralPath $script:root -Recurse -File) {
                $content = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
                [IO.File]::WriteAllText($file.FullName, $content, [Text.UTF8Encoding]::new($false))
            }
            $null = Invoke-UtilityProcess -Root $script:root -Arguments @('fmt', '-recursive', '-no-color')
            $context = New-TerraformAcceptanceContext -Source $script:root `
                -Name 'terraform-azure-avm-utl-utility-preservation' -InitializeLock
            $exampleRoot = Join-Path $context.Root 'examples' 'default'
            $null = Invoke-UtilityProcess -Root $exampleRoot -Arguments @('init', '-backend=false', '-input=false', '-no-color')
            $context.Authored['examples/default/.terraform.lock.hcl'] = (
                Get-FileHash -LiteralPath (Join-Path $exampleRoot '.terraform.lock.hcl') -Algorithm SHA256
            ).Hash
            $context.Authored = Get-TerraformAcceptanceFiles -Root $context.Root -Authored $context.Authored `
                -ConfigurationDirectories $context.ConfigurationDirectories
            $null = Invoke-TerraformAcceptanceGit -Root $context.Root -Arguments @('add', '--force', 'examples/default/.terraform.lock.hcl')
            $null = Invoke-TerraformAcceptanceGit -Root $context.Root -Arguments @('commit', '--quiet', '-m', 'test: locked legacy example selections')
            $protected = @{}
            foreach ($name in @('main.tf', 'terraform.tf', 'variables.tf', 'outputs.tf', '.terraform.lock.hcl',
                    'examples/default/main.tf', 'examples/default/terraform.tf', 'examples/default/.terraform.lock.hcl',
                    'examples/default/variables.tf',
                    'tests/unit/legacy.tftest.hcl')) {
                $protected[$name] = (Get-FileHash -LiteralPath (Join-Path $context.Root $name) -Algorithm SHA256).Hash
            }
            foreach ($iteration in 1..2) {
                $result = Invoke-TerraformAcceptancePreCommit -Context $context
                foreach ($name in $protected.Keys) {
                    (Get-FileHash -LiteralPath (Join-Path $context.Root $name) -Algorithm SHA256).Hash |
                        Should -BeExactly $protected[$name] -Because "$name must remain byte-identical on pre-commit $iteration"
                }
                if ($iteration -eq 1) {
                    $null = Invoke-TerraformAcceptanceGit -Root $context.Root -Arguments @('add', '--all')
                    $null = Invoke-TerraformAcceptanceGit -Root $context.Root -Arguments @('commit', '--quiet', '-m', 'test: generated preservation artifacts')
                    $stable = Get-TerraformAcceptanceFiles -Root $context.Root -Authored $context.Authored `
                        -ConfigurationDirectories $context.ConfigurationDirectories
                }
                else {
                    Assert-TerraformAcceptanceFiles -Context $context -Expected $stable
                }
            }
            $result = avm pr-check -Path $context.Root -Ecosystem terraform -ExcludeSteps 'check policy' --passthru
            $result.Status | Should -BeExactly 'pass'
            ($result.Steps.Step -join ',') | Should -BeExactly 'metadata,sync,format,transform,lint,check policy,check convention,validate,docs'
            @($result.Steps | Where-Object Status -eq pass) | Should -HaveCount 8
            $skipped = @($result.Steps | Where-Object Status -eq skipped)
            $skipped | Should -HaveCount 1
            $skipped[0].Step | Should -BeExactly 'check policy'
            Assert-TerraformAcceptanceFiles -Context $context -Expected $stable
            $unitTargets = @(
                [pscustomobject]@{ Path = $context.Root; Scope = 'root'; Profiles = @('module', 'common') }
                [pscustomobject]@{ Path = $exampleRoot; Scope = 'example'; Profiles = @('example', 'provider-cleanup', 'common') }
            )
            $unitResult = Invoke-UtilityProcess -Root $context.Root -Arguments @('test', '-no-color', '-test-directory=tests/unit') `
                -ModuleTargets $unitTargets
            $unitResult.StdOut | Should -Match 'Success! 1 passed'
            Assert-TerraformAcceptanceFiles -Context $context -Expected $stable
        }
        finally {
            if ($null -ne $context) { Remove-TerraformAcceptanceContext -Context $context }
            $value = if ($null -eq $previous) { [NullString]::Value } else { $previous }
            [Environment]::SetEnvironmentVariable('AVM_TF_UTILITY_MIGRATION', $value, 'Process')
        }
    }

It 'uses modern naming through existing output references without changing owner-selected AVM modes' {
        $unit = Join-Path $script:root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $unit -Force
        Set-Content -LiteralPath $script:main -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    random = { source = "hashicorp/random", version = ">= 3.3.2, < 4.0" }
  }
}
module "names" {
  source = "Azure/naming/azurerm"
  version = "0.4.2"
  prefix = ["existing"]
  suffix = ["safe"]
  unique-length = 8
  unique-seed = "modernseed123"
}
module "owner_mode" {
  source = "Azure/avm-utl-naming/azure"
  version = "0.2.0"
  legacy_mode = true
  prefix = ["existing"]
  suffix = ["safe"]
}
'@
        $inspection = Invoke-UtilityMigration -Root $script:root
        $inspection.calls.names.source | Should -BeExactly 'Azure/avm-utl-naming/azure'
        $inspection.calls.names.version | Should -BeExactly '0.2.0'
        $inspection.calls.names.Contains('legacy_mode') | Should -BeFalse
        $inspection.calls.names.'unique-length' | Should -Be 8
        $inspection.calls.names.'unique-seed' | Should -BeExactly 'modernseed123'
        $inspection.calls.owner_mode.legacy_mode | Should -BeTrue
        $first = [IO.File]::ReadAllBytes($script:main)
        $null = Invoke-UtilityMigration -Root $script:root
        [IO.File]::ReadAllBytes($script:main) | Should -Be $first
        Set-Content -LiteralPath (Join-Path $unit 'modern.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "random" {
  mock_resource "random_string" {
    defaults = { result = "mockedseed" }
  }
}
run "modern" {
  command = apply
  providers = { random = random }

  assert {
    condition = (
      length(module.names.names) > 0 &&
      module.names.names.resource_group.name_available &&
      module.names.names.resource_group.name_unique_available &&
      module.names.names.resource_group.unique_seed == "modernseed123"
    )
    error_message = "The old library must migrate into the fixed utility's modern renderer with compatible inputs intact."
  }
  assert {
    condition = (
      module.names.resource_group.name == module.names.names.resource_group.name &&
      module.names.resource_group.name_unique == module.names.names.resource_group.name_unique &&
      module.names.storage_account.name == module.names.names.storage_account.name &&
      module.names.storage_account.name_unique == module.names.names.storage_account.name_unique
    )
    error_message = "Existing named output references must expose modern results without requiring caller rewrites."
  }
  assert {
    condition = length(module.owner_mode.names) == 0
    error_message = "An existing AVM naming call must retain its owner-selected legacy mode."
  }
}
'@
        $null = Invoke-UtilityProcess -Root $script:root -Arguments @('init', '-backend=false', '-input=false', '-no-color', '-test-directory=tests/unit')
        $result = Invoke-UtilityProcess -Root $script:root -Arguments @('test', '-no-color', '-test-directory=tests/unit')
        $result.StdOut | Should -Match 'Success! 1 passed'
    }
}
