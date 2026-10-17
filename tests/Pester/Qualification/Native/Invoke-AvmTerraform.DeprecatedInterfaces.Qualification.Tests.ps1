#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: Terraform deprecated interfaces' -Tag Qualification {
BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $script:OriginalAvmHome = $env:AVM_HOME
        $script:OriginalPluginCache = $env:TF_PLUGIN_CACHE_DIR
        if (-not $env:AVM_HOME) {
            $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        }
        if (-not $env:TF_PLUGIN_CACHE_DIR) {
            $env:TF_PLUGIN_CACHE_DIR = Join-Path $TestDrive 'provider-cache'
        }
        $null = New-Item -ItemType Directory -Path $env:TF_PLUGIN_CACHE_DIR -Force
        Import-Module (Join-Path $script:RepoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
        Install-AvmTool -Name terraform -SkipModuleVersionCheck -InformationAction Continue -ErrorAction Stop

        function New-AvmDeprecationFixture {
            param([Parameter(Mandatory)] [string] $Root)

            $null = New-Item -ItemType Directory -Path $Root -Force
            [IO.File]::WriteAllText((Join-Path $Root 'terraform.tf'), @'
terraform {
  required_version = ">= 1.15.0, < 2.0.0"
}
'@ + "`n")
            [IO.File]::WriteAllText((Join-Path $Root 'main.tf'), @'
variable "current_value" {
  type    = string
  default = "current"
}

variable "legacy_value" {
  type       = string
  default    = null
  deprecated = "Use the current_value input instead."
}

locals {
  value = coalesce(var.legacy_value, var.current_value)
}

output "current_value" {
  value = local.value
}

output "legacy_value" {
  value      = local.value
  deprecated = "Use the current_value output instead."
}
'@ + "`n")

            foreach ($example in @('default', 'ignored')) {
                $exampleRoot = Join-Path $Root 'examples' $example
                $null = New-Item -ItemType Directory -Path $exampleRoot -Force
                [IO.File]::WriteAllText((Join-Path $exampleRoot 'main.tf'), @'
module "test" {
  source       = "../.."
  legacy_value = "compatibility"
}

output "legacy_value" {
  value = module.test.legacy_value
}
'@ + "`n")
            }
            [IO.File]::WriteAllText((Join-Path $Root 'examples' 'ignored' '.e2eignore'), '')
        }
    }

AfterAll {
        $env:AVM_HOME = $script:OriginalAvmHome
        $env:TF_PLUGIN_CACHE_DIR = $script:OriginalPluginCache
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

It 'still fails on an actual validation error in a deprecated library' {
            $script:Library = Join-Path $TestDrive 'deprecated-library'
            New-AvmDeprecationFixture -Root $script:Library
            [IO.File]::AppendAllText((Join-Path $script:Library 'main.tf'), @'

output "broken" {
  value = var.undeclared
}
'@ + "`n")

            $result = Invoke-AvmTest -Path $script:Library -Ecosystem terraform

            $result.Status | Should -Be 'fail'
            @($result.Issues | Where-Object {
                    $_.Severity -eq 'error' -and $_.File -eq 'main.tf' -and
                    $_.Message -match 'undeclared input variable'
                }).Count | Should -BeGreaterThan 0
        }
}
