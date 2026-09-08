#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: MAPOTF provider requirements' -Tag 'Integration' -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $moduleRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
        $script:profilesRoot = Join-Path $moduleRoot 'Resources' 'mapotf'
        $script:originalAvmHome = $env:AVM_HOME
        if (-not $env:AVM_HOME) {
            $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        }
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        Install-AvmTool -Name mapotf, terraform, tflint -ErrorAction Stop
        $script:lintConfig = Join-Path $TestDrive 'tflint.hcl'
        Set-Content -LiteralPath $script:lintConfig -Encoding utf8NoBOM -Value @'
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
rule "terraform_unused_required_providers" {
  enabled = true
}
'@

        function Invoke-ProviderTransform {
            param([string] $Root, [switch] $RootProfile)

            InModuleScope 'Avm.Authoring' -Parameters @{
                Root = $Root
                Profiles = $script:profilesRoot
                RootProfile = [bool]$RootProfile
            } {
                param($Root, $Profiles, $RootProfile)
                $tool = Resolve-AvmTool -Name mapotf
                $arguments = @('transform', '--tf-dir', $Root)
                if ($RootProfile) {
                    $arguments += @('--mptf-dir', (Join-Path $Profiles 'root'))
                }
                $arguments += @('--mptf-dir', (Join-Path $Profiles 'module'))
                $result = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList $arguments -WorkingDirectory $Root
                $result.ExitCode | Should -Be 0
                $null = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('clean-backup', '--tf-dir', $Root) -WorkingDirectory $Root
            }
        }

        function Invoke-UnusedProviderLint {
            param([string] $Root)

            InModuleScope 'Avm.Authoring' -Parameters @{ Root = $Root; Config = $script:lintConfig } {
                param($Root, $Config)
                $tool = Resolve-AvmTool -Name tflint
                Invoke-AvmProcess -FilePath $tool.Path -WorkingDirectory $Root -IgnoreExitCode -ArgumentList @(
                    '--config', $Config, '--only=terraform_unused_required_providers', '--format=json'
                )
            }
        }

        function Get-TerraformContent {
            param([string] $Root)

            @(Get-ChildItem -LiteralPath $Root -Filter '*.tf' -File | Sort-Object Name |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        }
    }

    BeforeEach {
        $script:target = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:target
        Set-Content -LiteralPath (Join-Path $script:target 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_version = "~> 1.9"
}
'@
    }

    AfterAll {
        if ($null -eq $script:originalAvmHome) {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_HOME = $script:originalAvmHome
        }
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'does not add AzAPI for <Name> and stays lint-clean and idempotent' -TestCases @(
        @{
            Name = 'a provider-free helper'
            Source = @'
variable "name" {
  type = string
}
locals {
  name = lower(var.name)
}
output "name" {
  value = local.name
}
'@
        }
        @{
            Name = 'an empty required_providers block'
            Source = @'
terraform {
  required_providers {}
}
'@
        }
        @{
            Name = 'a Terraform built-in resource'
            Source = 'resource "terraform_data" "example" {}'
        }
        @{
            Name = 'another provider'
            Source = 'resource "random_uuid" "example" {}'
        }
        @{
            Name = 'a child module with AzAPI use'
            Source = @'
module "child" {
  source = "./child"
}
'@
        }
    ) {
        param($Name, $Source)
        Set-Content -LiteralPath (Join-Path $script:target 'main.tf') -Value $Source -Encoding utf8NoBOM
        $child = Join-Path $script:target 'child'
        $null = New-Item -ItemType Directory -Path $child
        Set-Content -LiteralPath (Join-Path $child 'main.tf') -Encoding utf8NoBOM -Value 'data "azapi_client_config" "example" {}'

        Invoke-ProviderTransform -Root $script:target
        $first = Get-TerraformContent -Root $script:target
        $first | Should -Not -Match '(?m)^\s*azapi\s*='
        (Invoke-UnusedProviderLint -Root $script:target).ExitCode | Should -Be 0

        Invoke-ProviderTransform -Root $script:target
        Get-TerraformContent -Root $script:target | Should -BeExactly $first
    }

    It 'adds the current AzAPI constraint for a direct <Kind> with no declaration' -TestCases @(
        @{ Kind = 'resource'; Source = 'resource "azapi_resource" "example" {}' }
        @{ Kind = 'data source'; Source = 'data "azapi_client_config" "example" {}' }
    ) {
        param($Kind, $Source)
        Set-Content -LiteralPath (Join-Path $script:target 'main.tf') -Value $Source -Encoding utf8NoBOM

        Invoke-ProviderTransform -Root $script:target
        $first = Get-TerraformContent -Root $script:target
        $first | Should -Match 'source\s*=\s*"Azure/azapi"'
        $first | Should -Match 'version\s*=\s*"~> 2\.12"'
        (Invoke-UnusedProviderLint -Root $script:target).ExitCode | Should -Be 0

        Invoke-ProviderTransform -Root $script:target
        Get-TerraformContent -Root $script:target | Should -BeExactly $first
    }

    It 'enforces the floor for <Constraint> without losing other providers' -TestCases @(
        @{ Constraint = '~> 2.4'; Expected = '~> 2.12' }
        @{ Constraint = '~> 2.11'; Expected = '~> 2.12' }
        @{ Constraint = '~> 3.0'; Expected = '~> 2.12' }
        @{ Constraint = '~> 2.12'; Expected = '~> 2.12' }
        @{ Constraint = '>= 2.12, < 3.0'; Expected = '>= 2.12, < 3.0' }
        @{ Constraint = '~> 2.13'; Expected = '~> 2.13' }
    ) {
        param($Constraint, $Expected)
        Set-Content -LiteralPath (Join-Path $script:target 'terraform.tf') -Encoding utf8NoBOM -Value @"
terraform {
  required_version = "~> 1.9"
  required_providers {
    azapi = {
      source = "Azure/azapi"
      version = "$Constraint"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
"@
        Set-Content -LiteralPath (Join-Path $script:target 'main.tf') -Encoding utf8NoBOM -Value @'
data "azapi_client_config" "example" {
}
'@

        Invoke-ProviderTransform -Root $script:target
        $first = Get-TerraformContent -Root $script:target
        $first | Should -Match ('version\s*=\s*"{0}"' -f [regex]::Escape($Expected))
        $first | Should -Match 'version\s*=\s*"~> 3\.6"'

        Invoke-ProviderTransform -Root $script:target
        Get-TerraformContent -Root $script:target | Should -BeExactly $first
    }

    It 'updates a function-only AzAPI declaration' {
        Set-Content -LiteralPath (Join-Path $script:target 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
      version = "~> 2.4"
    }
  }
}
'@
        Set-Content -LiteralPath (Join-Path $script:target 'outputs.tf') -Encoding utf8NoBOM -Value @'
output "parsed_id" {
  value = provider::azapi::parse_resource_id("/subscriptions/00000000-0000-0000-0000-000000000000")
}
'@

        Invoke-ProviderTransform -Root $script:target
        Get-TerraformContent -Root $script:target | Should -Match 'version\s*=\s*"~> 2\.12"'
    }

    It 'leaves unused declarations visible to the unused-provider lint rule' {
        Set-Content -LiteralPath (Join-Path $script:target 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
      version = "~> 2.12"
    }
  }
}
'@

        Invoke-ProviderTransform -Root $script:target
        $lint = Invoke-UnusedProviderLint -Root $script:target
        $lint.ExitCode | Should -Be 2
        $lint.StdOut | Should -Match 'terraform_unused_required_providers'
    }

    It 'adds the AzAPI requirement for root telemetry on the first pass' {
        Invoke-ProviderTransform -Root $script:target -RootProfile
        $first = Get-TerraformContent -Root $script:target
        $first | Should -Match 'data "azapi_client_config" "telemetry"'
        $first | Should -Match 'version\s*=\s*"~> 2\.12"'

        Invoke-ProviderTransform -Root $script:target -RootProfile
        Get-TerraformContent -Root $script:target | Should -BeExactly $first
    }

    It 'keeps provider-free local helpers lint-clean and drift-free with the full profile chain' {
        $helper = Join-Path $script:target 'modules' 'site_config_helpers'
        $null = New-Item -ItemType Directory -Path $helper -Force
        Copy-Item -LiteralPath (Join-Path $script:target 'terraform.tf') -Destination $helper
        Set-Content -LiteralPath (Join-Path $helper 'main.tf') -Encoding utf8NoBOM -Value @'
variable "name" {
  type = string
}
locals {
  name = lower(var.name)
}
output "name" {
  value = local.name
}
'@
        Set-Content -LiteralPath (Join-Path $script:target 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_version = "~> 1.9"
  required_providers {
    modtm = {
      source = "Azure/modtm"
      version = "~> 0.3"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
'@

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:target } {
            param($Root)
            Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
        }
        $result.Status | Should -Be 'pass'
        Get-TerraformContent -Root $helper | Should -Not -Match '(?m)^\s*azapi\s*='
        Get-TerraformContent -Root $script:target | Should -Match 'version\s*=\s*"~> 2\.12"'
        (Invoke-UnusedProviderLint -Root $helper).ExitCode | Should -Be 0

        $drift = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:target } {
            param($Root)
            Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' }) -CheckDrift
        }
        $drift.Status | Should -Be 'pass'
        $drift.Changed | Should -BeNullOrEmpty
    }
}
