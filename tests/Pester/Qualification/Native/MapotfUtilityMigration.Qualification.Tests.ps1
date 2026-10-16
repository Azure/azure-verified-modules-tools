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
}
