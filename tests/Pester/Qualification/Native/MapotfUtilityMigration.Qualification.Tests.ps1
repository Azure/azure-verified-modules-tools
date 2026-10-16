#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: MAPOTF utility module migration' -Tag Qualification {
BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
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
