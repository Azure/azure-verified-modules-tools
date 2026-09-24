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
        $tools = @('terraform', 'tflint')
        if ($env:AVM_MAPOTF_TEST_BINARY) {
            (Get-Item -LiteralPath $env:AVM_MAPOTF_TEST_BINARY -ErrorAction Stop).PSIsContainer | Should -BeFalse
            Mock Resolve-AvmTool -ModuleName 'Avm.Authoring' -ParameterFilter { $Name -eq 'mapotf' } {
                [pscustomobject]@{
                    Name = 'mapotf'
                    Path = (Get-Item -LiteralPath $env:AVM_MAPOTF_TEST_BINARY -ErrorAction Stop).FullName
                    Version = 'development'
                    Source = 'AVM_MAPOTF_TEST_BINARY'
                }
            }
        }
        else {
            $tools += 'mapotf'
        }
        Install-AvmTool -Name $tools -ErrorAction Stop
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

        function New-AliasedProviderConfiguration {
            param(
                [string] $Syntax,
                [string] $AzapiVersion,
                [string] $RandomVersion
            )

            $template = switch ($Syntax) {
                'multiline' {
                    @'
    __NAME__ = {
      source = "__SOURCE__"
      version = "__VERSION__"
      configuration_aliases = [__NAME__.primary, __NAME__.secondary]
    }
'@
                }
                'inline' {
                    '    __NAME__ = { source = "__SOURCE__", version = "__VERSION__", configuration_aliases = [__NAME__.primary, __NAME__.secondary] }'
                }
                'comments' {
                    @'
    __NAME__ = {
      # version = "~> 2.4"; source = "example/untouched"
      "configuration_aliases" = [
        __NAME__.primary, # primary account
        /* secondary account */ __NAME__.secondary,
      ]
      "source" = "__SOURCE__" # keep the source note
      "version" = "__VERSION__" # keep the version note
    }
'@
                }
            }

            $providers = @(
                @{ Name = 'azapi'; Source = 'Azure/azapi'; Version = $AzapiVersion }
                @{ Name = 'random'; Source = 'hashicorp/random'; Version = $RandomVersion }
                @{ Name = 'azurerm'; Source = 'hashicorp/azurerm'; Version = '~> 4.0' }
            )
            $requirements = foreach ($provider in $providers) {
                $template.Replace('__NAME__', $provider.Name).
                    Replace('__SOURCE__', $provider.Source).
                    Replace('__VERSION__', $provider.Version)
            }

            @"
terraform {
  required_version = "~> 1.9"
  required_providers {
$($requirements -join "`n")
  }
}

locals {
  untouched = "version = \"~> 2.4\" and source = \"example/untouched\""
}
"@ + "`n"
        }

        function Assert-ProviderRequirements {
            param([string] $Root, [string] $ExpectedConfiguration)

            $expectedRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $expectedRoot
            $expectedFile = Join-Path $expectedRoot 'terraform.tf'
            Set-Content -LiteralPath $expectedFile -Value $ExpectedConfiguration -Encoding utf8NoBOM -NoNewline

            Invoke-ProviderTransform -Root $Root
            $first = Get-TerraformContent -Root $Root
            Invoke-ProviderTransform -Root $Root
            Get-TerraformContent -Root $Root | Should -BeExactly $first

            $actualFile = Join-Path $expectedRoot 'actual.tf'
            Copy-Item -LiteralPath (Join-Path $Root 'terraform.tf') -Destination $actualFile
            InModuleScope 'Avm.Authoring' -Parameters @{ Root = $Root; ExpectedRoot = $expectedRoot } {
                param($Root, $ExpectedRoot)
                $tool = Resolve-AvmTool -Name terraform
                $null = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('fmt', $ExpectedRoot) -WorkingDirectory $Root
                $null = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('providers') -WorkingDirectory $Root
            }
            Get-Content -LiteralPath $actualFile -Raw | Should -BeExactly (Get-Content -LiteralPath $expectedFile -Raw)
        }
    }

    BeforeEach {
        $script:target = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:target
        Set-Content -LiteralPath (Join-Path $script:target 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Provider requirements fixture",
  "moduleDescription": "Fixture for provider requirement transforms.",
  "canonicalType": "Microsoft.Resources/resourceGroups",
  "telemetryIdPrefix": "46d3xtrf.res.provider-test",
  "owners": []
}
'@
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

    It 'preserves aliases for <Scenario> with <Syntax> syntax' -TestCases @(
        foreach ($scenario in @(
            @{ Name = 'compliant providers'; Azapi = '~> 2.12'; Random = '~> 3.6'; ExpectedAzapi = '~> 2.12'; ExpectedRandom = '~> 3.6' }
            @{ Name = 'an AzAPI upgrade'; Azapi = '~> 2.4'; Random = '~> 3.6'; ExpectedAzapi = '~> 2.12'; ExpectedRandom = '~> 3.6' }
            @{ Name = 'a Random upgrade'; Azapi = '~> 2.12'; Random = '~> 2.0'; ExpectedAzapi = '~> 2.12'; ExpectedRandom = '~> 3.0' }
            @{ Name = 'both upgrades'; Azapi = '~> 2.4'; Random = '~> 2.0'; ExpectedAzapi = '~> 2.12'; ExpectedRandom = '~> 3.0' }
        )) {
            foreach ($syntax in @('multiline', 'inline', 'comments')) {
                @{
                    Scenario = $scenario.Name
                    Syntax = $syntax
                    AzapiVersion = $scenario.Azapi
                    RandomVersion = $scenario.Random
                    ExpectedAzapiVersion = $scenario.ExpectedAzapi
                    ExpectedRandomVersion = $scenario.ExpectedRandom
                }
            }
        }
    ) {
        param($Scenario, $Syntax, $AzapiVersion, $RandomVersion, $ExpectedAzapiVersion, $ExpectedRandomVersion)

        $source = New-AliasedProviderConfiguration -Syntax $Syntax -AzapiVersion $AzapiVersion -RandomVersion $RandomVersion
        Set-Content -LiteralPath (Join-Path $script:target 'terraform.tf') -Value $source -Encoding utf8NoBOM -NoNewline
        $expected = New-AliasedProviderConfiguration -Syntax $Syntax -AzapiVersion $ExpectedAzapiVersion -RandomVersion $ExpectedRandomVersion
        Assert-ProviderRequirements -Root $script:target -ExpectedConfiguration $expected
    }

    It 'preserves representative Fabric workspace aliases and references for <AzapiVersion>' -TestCases @(
        @{ AzapiVersion = '~> 2.12'; ExpectedAzapiVersion = '~> 2.12' }
        @{ AzapiVersion = '~> 2.4'; ExpectedAzapiVersion = '~> 2.12' }
    ) {
        param($AzapiVersion, $ExpectedAzapiVersion)

        $requirements = @'
terraform {
  required_version = "~> 1.9"
  required_providers {
    fabric = {
      source = "microsoft/fabric"
      version = "~> 1.0"
      configuration_aliases = [fabric.workspaces, fabric.capacities]
    }
    azapi = {
      source = "Azure/azapi"
      version = "__AZAPI_VERSION__"
      configuration_aliases = [azapi.networking, azapi.identity]
    }
  }
}
'@
        Set-Content -LiteralPath (Join-Path $script:target 'terraform.tf') -Encoding utf8NoBOM -NoNewline -Value ($requirements.Replace('__AZAPI_VERSION__', $AzapiVersion) + "`n")
        $mainFile = Join-Path $script:target 'main.tf'
        $workloadSource = @'
data "fabric_capacity" "existing" {
  provider     = fabric.capacities
  display_name = "existing-shared-capacity"
}

resource "fabric_workspace" "this" {
  provider     = fabric.workspaces
  display_name = "alias-regression-workspace"
  capacity_id  = data.fabric_capacity.existing.id
}

data "azapi_client_config" "current" {
  provider = azapi.identity
}

resource "azapi_resource" "network" {
  provider  = azapi.networking
  type      = "Microsoft.Network/virtualNetworks@2024-05-01"
  name      = "alias-regression-network"
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/alias-regression"
  location  = "westeurope"
  body = {
    properties = {
      addressSpace = {
        addressPrefixes = ["10.0.0.0/24"]
      }
    }
  }
}
'@
        Set-Content -LiteralPath $mainFile -Value ($workloadSource + "`n") -Encoding utf8NoBOM -NoNewline
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $script:target } {
            param($Root)
            $tool = Resolve-AvmTool -Name terraform
            $null = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('fmt', $Root) -WorkingDirectory $Root
        }
        $workload = Get-Content -LiteralPath $mainFile -Raw
        $expected = $requirements.Replace('__AZAPI_VERSION__', $ExpectedAzapiVersion) + "`n"

        Assert-ProviderRequirements -Root $script:target -ExpectedConfiguration $expected
        Get-Content -LiteralPath $mainFile -Raw | Should -BeExactly $workload
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
        Set-Content -LiteralPath (Join-Path $helper 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Provider-free helper",
  "moduleDescription": "Helper fixture without telemetry.",
  "canonicalType": "helper"
}
'@
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
