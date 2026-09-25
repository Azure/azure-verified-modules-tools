#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: MAPOTF Terraform deployment telemetry' -Tag 'Integration' -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        $script:profilesRoot = Join-Path $moduleRoot 'Resources' 'mapotf'
        $script:originalAvmHome = $env:AVM_HOME
        $script:originalMapotfConfig = $env:AVM_MPTF_CONFIG_DIR
        $script:originalPluginCache = $env:TF_PLUGIN_CACHE_DIR
        if (-not $env:AVM_HOME) {
            $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        }
        $env:AVM_MPTF_CONFIG_DIR = $null
        $env:TF_PLUGIN_CACHE_DIR = $null
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:mapotfPath = InModuleScope 'Avm.Authoring' { (Resolve-AvmTool -Name mapotf).Path }
        $script:terraformPath = InModuleScope 'Avm.Authoring' { (Resolve-AvmTool -Name terraform).Path }
        $script:processEnvironment = InModuleScope 'Avm.Authoring' -Parameters @{ ToolPath = $script:terraformPath } {
            param($ToolPath)
            New-AvmToolPathEnvironment -ToolPath $ToolPath -ToolName terraform
        }
        foreach ($name in @('TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_validate')) {
            $script:processEnvironment[$name] = $null
        }

        function Invoke-TelemetryProcess {
            param([string] $FilePath, [string[]] $ArgumentList, [string] $Root)

            InModuleScope 'Avm.Authoring' -Parameters @{
                ToolPath = $FilePath
                Arguments = $ArgumentList
                Root = $Root
                Environment = $script:processEnvironment
            } {
                param($ToolPath, $Arguments, $Root, $Environment)
                Invoke-AvmProcess -FilePath $ToolPath -ArgumentList $Arguments `
                    -WorkingDirectory $Root -EnvVars $Environment
            }
        }

        function Invoke-TelemetryProfiles {
            param([string] $Root)

            $arguments = @('transform')
            foreach ($profile in @('root', 'module', 'common')) {
                $arguments += @('--mptf-dir', (Join-Path $script:profilesRoot $profile))
            }
            $arguments += @('--tf-dir', $Root)
            $null = Invoke-TelemetryProcess -FilePath $script:mapotfPath -ArgumentList $arguments -Root $Root
            $null = Invoke-TelemetryProcess -FilePath $script:mapotfPath `
                -ArgumentList @('clean-backup', '--tf-dir', $Root) -Root $Root
        }

        function Assert-TelemetryTerraformValid {
            param([string] $Root)

            $null = Invoke-TelemetryProcess -FilePath $script:terraformPath `
                -ArgumentList @('fmt', '-recursive', $Root) -Root $Root
            $init = Invoke-TelemetryProcess -FilePath $script:terraformPath `
                -ArgumentList @('init', '-backend=false', '-input=false', '-upgrade', '-no-color') -Root $Root
            $init.StdOut | Should -Not -Match 'Finding Azure/modtm versions'
            $validation = Invoke-TelemetryProcess -FilePath $script:terraformPath `
                -ArgumentList @('validate', '-json') -Root $Root
            ($validation.StdOut | ConvertFrom-Json).valid | Should -BeTrue
        }

        function Invoke-TelemetryEngine {
            param([string] $Root, [switch] $CheckDrift)

            InModuleScope 'Avm.Authoring' -Parameters @{
                Root = $Root
                CheckDrift = [bool]$CheckDrift
            } {
                param($Root, $CheckDrift)
                Invoke-AvmTerraformTransform -Context ([pscustomobject]@{
                        Kind = 'terraform-module-repo'
                        Root = $Root
                        Ecosystem = 'terraform'
                    }) -ThrottleLimit 2 -CheckDrift:$CheckDrift
            }
        }

        function New-TelemetryModule {
            param([string] $Root, [switch] $WithLocation, [switch] $WithLegacy, [switch] $Child)

            $null = New-Item -ItemType Directory -Path $Root -Force
            $metadata = if ($Child) {
                @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Mock child resource",
  "moduleDescription": "Child resource fixture for telemetry alignment.",
  "canonicalType": "Microsoft.Resources/resourceGroups",
  "telemetryIdPrefix": "46d3xtrf.res.c1d2e3f"
}
'@
            }
            else {
                @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Mock resource",
  "moduleDescription": "Resource fixture for telemetry alignment.",
  "canonicalType": "Microsoft.Resources/resourceGroups",
  "telemetryIdPrefix": "46d3xtrf.res.a1b2c3d",
  "owners": []
}
'@
            }
            Set-Content -LiteralPath (Join-Path $Root 'metadata.json') -Encoding utf8NoBOM -Value $metadata
            $terraform = @'
terraform {
  required_version = ">= 1.9.0, < 2.0.0"
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
      version = "~> 3.6"
    }
  }
}
'@
            if (-not $WithLegacy) {
                $terraform = @'
terraform {
  required_version = ">= 1.9.0, < 2.0.0"
}
'@
            }
            Set-Content -LiteralPath (Join-Path $Root 'terraform.tf') -Encoding utf8NoBOM -Value $terraform
            if ($WithLocation) {
                Set-Content -LiteralPath (Join-Path $Root 'variables.tf') -Encoding utf8NoBOM -Value @'
variable "location" {
  type    = string
  default = "eastus"
}
'@
            }
            if ($WithLegacy) {
                Set-Content -LiteralPath (Join-Path $Root 'main.telemetry.tf') -Encoding utf8NoBOM -Value @'
data "modtm_module_source" "telemetry" {
  count       = var.enable_telemetry ? 1 : 0
  module_path = path.module
}

resource "random_uuid" "telemetry" {
  count = var.enable_telemetry ? 1 : 0
}

resource "modtm_telemetry" "telemetry" {
  count = var.enable_telemetry ? 1 : 0
  tags = {
    module_version = one(data.modtm_module_source.telemetry).module_version
  }
}

locals {
  main_location = "unknown"
}
'@
                Set-Content -LiteralPath (Join-Path $Root 'outputs.tf') -Encoding utf8NoBOM -Value @'
output "telemetry_count" {
  value = length(modtm_telemetry.telemetry)
}
'@
            }
        }
    }

    AfterAll {
        if ($null -eq $script:originalAvmHome) {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_HOME = $script:originalAvmHome
        }
        $env:AVM_MPTF_CONFIG_DIR = $script:originalMapotfConfig
        $env:TF_PLUGIN_CACHE_DIR = $script:originalPluginCache
        Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'migrates legacy telemetry without destroying state and preserves user providers' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation -WithLegacy
        Invoke-TelemetryProfiles -Root $root

        $telemetry = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        $providers = Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw
        $variables = Get-Content -LiteralPath (Join-Path $root 'variables.tf') -Raw
        $telemetry | Should -Not -Match '(?m)^(data "modtm_module_source"|resource "(modtm_telemetry|random_uuid)")'
        $telemetry | Should -Match '(?s)removed \{\s*from\s*=\s*modtm_telemetry\.telemetry\s*lifecycle \{\s*destroy\s*=\s*false'
        $telemetry | Should -Match '(?s)removed \{\s*from\s*=\s*random_uuid\.telemetry\s*lifecycle \{\s*destroy\s*=\s*false'
        $telemetry | Should -Match '(?s)resource "terraform_data" "telemetry" \{\s*count\s*=\s*var\.enable_telemetry'
        $telemetry | Should -Match 'Microsoft.Resources/deployments@2025-04-01'
        $telemetry | Should -Match 'local\.avm_metadata\.telemetryIdPrefix'
        $telemetry | Should -Match 'local\.avm_telemetry_version_token'
        $telemetry | Should -Match 'local\.avm_module_source_type'
        $telemetry | Should -Match 'data\.azapi_client_config\.telemetry\)\.subscription_resource_id'
        $telemetry | Should -Match 'substr\(sha1\(terraform_data\.telemetry\[0\]\.id\), 0, 4\)'
        $telemetry | Should -Match '(?s)apply_id\s*=\s*\{\s*type\s*=\s*"String"\s*value\s*=\s*plantimestamp\(\)'
        $telemetry | Should -Match 'avm_telemetry_version_token\s*=\s*replace\(coalesce\(local\.avm_module_version,\s*"0\.0\.0"\),\s*"\.",\s*"-"\)'
        $telemetry | Should -Not -Match '(?m)^\s*tags\s*='
        $telemetry | Should -Match 'length\(local\.avm_metadata\.telemetryIdPrefix\).*<= 64'
        $telemetry | Should -Match 'response_export_values\s*=\s*\[\]'
        $telemetry | Should -Match 'var\.telemetry_location != null \? var\.telemetry_location : var\.location'
        $providers | Should -Not -Match '(?m)^\s*(modtm|random)\s*='
        $providers | Should -Match '(?m)^\s*azapi\s*='
        (Get-Content -LiteralPath (Join-Path $root 'outputs.tf') -Raw) |
            Should -Match 'length\(azapi_resource\.telemetry\)'
        $variables | Should -Match '(?s)variable "telemetry_location" \{\s*type\s*=\s*string\s*default\s*=\s*null'
        @([regex]::Matches($telemetry, '(?m)^removed \{')) | Should -HaveCount 2

        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw | Should -BeExactly $telemetry
        Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw | Should -BeExactly $providers
        Get-Content -LiteralPath (Join-Path $root 'variables.tf') -Raw | Should -BeExactly $variables
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'defaults a location-free module to westus2 without creating legacy providers' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Invoke-TelemetryProfiles -Root $root

        $telemetry = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        $variables = Get-Content -LiteralPath (Join-Path $root 'variables.tf') -Raw
        $providers = Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw
        $telemetry | Should -Match '(?m)^\s*main_location\s*=\s*var\.telemetry_location'
        $telemetry | Should -Not -Match '(?m)^removed \{'
        $variables | Should -Match '(?s)variable "telemetry_location" \{\s*type\s*=\s*string\s*default\s*=\s*"westus2"'
        $providers | Should -Match '(?m)^\s*azapi\s*='
        $providers | Should -Not -Match '(?m)^\s*(modtm|random)\s*='

        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw | Should -BeExactly $telemetry
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'instruments prefixed children and forwards opt-out and location without touching helpers' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $child = Join-Path $root 'modules' 'child'
        $helper = Join-Path $root 'modules' 'helper'
        New-TelemetryModule -Root $root -WithLocation
        New-TelemetryModule -Root $child -Child
        $null = New-Item -ItemType Directory -Path $helper -Force
        Set-Content -LiteralPath (Join-Path $helper 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Mock helper",
  "moduleDescription": "Helper without telemetry.",
  "canonicalType": "helper"
}
'@
        Set-Content -LiteralPath (Join-Path $helper 'main.tf') -Encoding utf8NoBOM -Value @'
output "name" {
  value = "helper"
}
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "child" {
  source           = "./modules/child"
  enable_telemetry = false # keep this comment
}

module "helper" {
  source = "./modules/helper"
}
'@
        $childTests = Join-Path $child 'tests' 'unit'
        $childWrapper = Join-Path $child 'tests' 'wrapper'
        $helperTests = Join-Path $helper 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $childTests, $childWrapper, $helperTests -Force
        $childTestFile = Join-Path $childTests 'telemetry.tftest.hcl'
        $helperTestFile = Join-Path $helperTests 'helper.tftest.hcl'
        Set-Content -LiteralPath $childTestFile -Encoding utf8NoBOM -Value @'
mock_provider "modtm" {}
run "telemetry" {
  assert {
    condition     = can(modtm_telemetry.telemetry)
    error_message = "Child telemetry is enabled."
  }
}
'@
        Set-Content -LiteralPath $helperTestFile -Encoding utf8NoBOM -Value 'mock_provider "modtm" {}'
        Set-Content -LiteralPath (Join-Path $childWrapper 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    modtm = {
      source = "Azure/modtm"
      version = "~> 0.3"
    }
  }
}
'@

        $result = Invoke-TelemetryEngine -Root $root
        $result.Status | Should -Be 'pass'
        $rootMain = Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw
        $rootMain | Should -Match '(?m)^\s*enable_telemetry\s*=\s*var\.enable_telemetry # keep this comment\r?$'
        $rootMain | Should -Match '(?m)^\s*telemetry_location\s*=\s*local\.main_location'
        $rootMain | Should -Not -Match '(?s)module "helper" \{[^}]*enable_telemetry'
        (Join-Path $root 'main.telemetry.tf') | Should -Exist
        (Join-Path $child 'main.telemetry.tf') | Should -Exist
        (Join-Path $helper 'main.telemetry.tf') | Should -Not -Exist
        $childVariables = Get-Content -LiteralPath (Join-Path $child 'variables.tf') -Raw
        $childVariables | Should -Match '(?s)variable "telemetry_location" \{\s*type\s*=\s*string\s*default\s*=\s*"westus2"'
        Get-Content -LiteralPath $childTestFile -Raw | Should -Match 'can\(azapi_resource\.telemetry\)'
        Get-Content -LiteralPath $childTestFile -Raw | Should -Not -Match 'mock_provider "modtm"'
        Get-Content -LiteralPath (Join-Path $childWrapper 'terraform.tf') -Raw | Should -Not -Match 'modtm\s*='
        $helperMain = Get-Content -LiteralPath (Join-Path $helper 'main.tf') -Raw
        $helperTest = Get-Content -LiteralPath $helperTestFile -Raw

        $drift = Invoke-TelemetryEngine -Root $root -CheckDrift
        $drift.Status | Should -Be 'pass'
        $drift.Changed | Should -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw | Should -BeExactly $rootMain
        Get-Content -LiteralPath (Join-Path $helper 'main.tf') -Raw | Should -BeExactly $helperMain
        Get-Content -LiteralPath $helperTestFile -Raw | Should -BeExactly $helperTest
        $helperTest | Should -Match 'mock_provider "modtm"'
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'allows a disabled parent and child when their location input is null' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $child = Join-Path $root 'modules' 'child'
        New-TelemetryModule -Root $root -WithLocation
        New-TelemetryModule -Root $child -Child
        Set-Content -LiteralPath (Join-Path $root 'variables.tf') -Encoding utf8NoBOM -Value @'
variable "location" {
  type    = string
  default = null
}
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "child" {
  source = "./modules/child"
}
'@

        (Invoke-TelemetryEngine -Root $root).Status | Should -Be 'pass'
        Assert-TelemetryTerraformValid -Root $root
        $plan = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('plan', '-input=false', '-no-color', '-var=enable_telemetry=false') -Root $root
        $plan.StdOut | Should -Match 'No changes'
    }

    It 'migrates test wrapper providers and standard Terraform test mocks' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLegacy
        $wrapper = Join-Path $root 'tests' 'wrapper'
        $unit = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $wrapper, $unit -Force
        Set-Content -LiteralPath (Join-Path $wrapper 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
  }
}
'@
        $testPath = Join-Path $unit 'telemetry.tftest.hcl'
        Set-Content -LiteralPath $testPath -Encoding utf8NoBOM -Value @'
mock_provider "azapi" {}
mock_provider "modtm" {}

run "telemetry" {
  assert {
    condition     = can(modtm_telemetry.telemetry[0])
    error_message = "Telemetry should be created."
  }
}
'@

        $result = Invoke-TelemetryEngine -Root $root
        $result.Status | Should -Be 'pass'
        $result.Changed | Should -Contain ([System.IO.Path]::Combine('tests', 'unit', 'telemetry.tftest.hcl'))
        Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw |
            Should -Match '(?m)^# tflint-ignore: avm_azapi_resource_tags_required\r?\nresource "azapi_resource" "telemetry" \{'
        $testContent = Get-Content -LiteralPath $testPath -Raw
        $testContent | Should -Not -Match 'mock_provider "modtm"'
        $testContent | Should -Match 'can\(azapi_resource\.telemetry\[0\]\)'
        $providerContent = Get-Content -LiteralPath (Join-Path $wrapper 'terraform.tf') -Raw
        $providerContent | Should -Not -Match '(?m)^\s*modtm\s*='
        $providerContent | Should -Match '(?m)^\s*azapi\s*='

        $drift = Invoke-TelemetryEngine -Root $root -CheckDrift
        $drift.Status | Should -Be 'pass'
        $drift.Changed | Should -BeNullOrEmpty
        Get-Content -LiteralPath $testPath -Raw | Should -BeExactly $testContent
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'encodes an unversioned local module in the name and creates no deployment when disabled' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation
        Invoke-TelemetryProfiles -Root $root
        $generated = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        $generated | Should -Not -Match '(?m)^\s*tags\s*='
        $generated | Should -Match '(?m)^\s*value\s*=\s*plantimestamp\(\)'
        Assert-TelemetryTerraformValid -Root $root
        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $testDirectory 'telemetry.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Resources/deployments/telemetry"
    }
  }
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id          = "00000000-0000-0000-0000-000000000000"
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "enabled" {
  command = apply
  variables {
    telemetry_location = "usgovvirginia"
  }
  assert {
    condition     = azapi_resource.telemetry[0].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000"
    error_message = "Telemetry must deploy at the active subscription scope."
  }
  assert {
    condition     = azapi_resource.telemetry[0].location == "usgovvirginia"
    error_message = "The explicit telemetry location must override var.location."
  }
  assert {
    condition = (
      can(regex("^46d3xtrf[.]res[.]a1b2c3d[.]0-0-0[.]x[.][0-9a-f]{4}$", azapi_resource.telemetry[0].name)) &&
      can(formatdate("YYYY-MM-DD", azapi_resource.telemetry[0].body.properties.template.outputs.apply_id.value))
    )
    error_message = "Telemetry must report an unversioned local module in the name and update its empty template."
  }
}

run "disabled" {
  command = plan
  variables {
    enable_telemetry = false
  }
  assert {
    condition     = length(terraform_data.telemetry) == 0 && length(azapi_resource.telemetry) == 0
    error_message = "Disabling telemetry must create neither an instance ID nor an Azure deployment."
  }
}
'@

        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match 'Success! 2 passed, 0 failed\.'
    }

    It 'plans an in-place telemetry update on a subsequent normal apply without changing its name' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Invoke-TelemetryProfiles -Root $root
        Set-Content -LiteralPath (Join-Path $root 'outputs.tf') -Encoding utf8NoBOM -Value @'
output "telemetry_name" {
  value = one(azapi_resource.telemetry).name
}

output "telemetry_apply_id" {
  value = one(azapi_resource.telemetry).body.properties.template.outputs.apply_id.value
}
'@
        Set-Content -LiteralPath (Join-Path $root 'delay.tf') -Encoding utf8NoBOM -Value @'
resource "terraform_data" "delay" {
  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = "Start-Sleep -Seconds 2"
  }
}
'@
        Assert-TelemetryTerraformValid -Root $root
        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $testDirectory 'repeat.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Resources/deployments/telemetry"
    }
  }
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "first" {
  command = apply
  assert {
    condition     = length(azapi_resource.telemetry) == 1
    error_message = "The first apply must create one telemetry deployment."
  }
}

run "second" {
  command = plan
  assert {
    condition = (
      output.telemetry_name == run.first.telemetry_name &&
      output.telemetry_apply_id != run.first.telemetry_apply_id
    )
    error_message = "The next normal plan must update telemetry without changing its name."
  }
}
'@
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', '-no-color', '-verbose', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match 'Success! 2 passed, 0 failed\.'
        $result.StdOut | Should -Match 'azapi_resource\.telemetry\[0\] will be updated in-place'
    }

    It 'accepts a 36-character version at the 64-character Azure name limit' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Invoke-TelemetryProfiles -Root $root
        Assert-TelemetryTerraformValid -Root $root
        $version = ('1' * 12) + '.' + ('2' * 11) + '.' + ('3' * 11)
        $versionToken = $version.Replace('.', '-')
        $versionToken.Length | Should -Be 36
        $prefix = '46d3xtrf.res.a1b2c3d'
        $manifestPath = Join-Path $root '.terraform' 'modules' 'modules.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force
        @{ Modules = @(@{ Dir = '.'; Version = $version; Source = 'C:/private/customer/module' }) } |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $testDirectory 'name.tftest.hcl') -Encoding utf8NoBOM -Value @"
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "name" {
  command = apply
  assert {
    condition = (
      length(azapi_resource.telemetry[0].name) == 64 &&
      startswith(azapi_resource.telemetry[0].name, "${prefix}.${versionToken}.x.")
    )
    error_message = "Telemetry names must fit Azure's 64-character limit."
  }
}
"@
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match 'Success! 1 passed, 0 failed\.'
    }

    It 'rejects a 37-character version before creating an overlong deployment' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Invoke-TelemetryProfiles -Root $root
        Assert-TelemetryTerraformValid -Root $root
        $manifestPath = Join-Path $root '.terraform' 'modules' 'modules.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force
        $overlongVersion = ('1' * 18) + '.' + ('2' * 16) + '.1'
        $overlongVersion.Length | Should -Be 37
        @{ Modules = @(@{ Dir = '.'; Version = $overlongVersion; Source = 'C:/private/customer/module' }) } |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $testDirectory 'name.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "name" {
  command = plan
  assert {
    condition     = length(azapi_resource.telemetry) == 1
    error_message = "The plan should be rejected by the telemetry name precondition."
  }
}
'@
        {
            Invoke-TelemetryProcess -FilePath $script:terraformPath `
                -ArgumentList @('test', '-no-color', '-test-directory=tests/unit') -Root $root
        } | Should -Throw '*64-character limit*'
    }

    It 'classifies <Name> module sources without sending their raw paths' -TestCases @(
        @{ Name = 'Terraform registry'; Source = 'registry.terraform.io/Azure/avm-res-mock/azurerm'; Expected = 't' }
        @{ Name = 'OpenTofu registry'; Source = 'registry.opentofu.org/Azure/avm-res-mock/azurerm'; Expected = 'o' }
        @{ Name = 'Git'; Source = 'git::https://example.com/Azure/mock.git'; Expected = 'g' }
        @{ Name = 'local path'; Source = 'C:/private/customer/module'; Expected = 'x' }
    ) {
        param($Name, $Source, $Expected)

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Invoke-TelemetryProfiles -Root $root
        Assert-TelemetryTerraformValid -Root $root
        $manifestPath = Join-Path $root '.terraform' 'modules' 'modules.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force
        $manifest = @{
            Modules = @(@{ Dir = '.'; Version = '10.12.3'; Source = $Source })
        } | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM -Value $manifest
        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $testDirectory 'source.tftest.hcl') -Encoding utf8NoBOM -Value @"
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "source" {
  command = apply
  assert {
    condition     = can(regex("^46d3xtrf[.]res[.]a1b2c3d[.]10-12-3[.]${Expected}[.][0-9a-f]{4}$", azapi_resource.telemetry[0].name))
    error_message = "The name must encode the full version and only the source-type token, never the source path."
  }
}
"@
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match 'Success! 1 passed, 0 failed\.'
    }

    It 'forgets legacy state after one-time provider installation without destroying it' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLegacy
        Invoke-TelemetryProfiles -Root $root
        Assert-TelemetryTerraformValid -Root $root
        $statePath = Join-Path $root 'legacy.tfstate'
        Set-Content -LiteralPath $statePath -Encoding utf8NoBOM -Value @'
{
  "version": 4,
  "terraform_version": "1.15.8",
  "serial": 1,
  "lineage": "00000000-0000-0000-0000-000000000001",
  "outputs": {},
  "resources": [
    {
      "mode": "managed",
      "type": "modtm_telemetry",
      "name": "telemetry",
      "provider": "provider[\"registry.terraform.io/Azure/modtm\"]",
      "instances": [
        {
          "index_key": 0,
          "schema_version": 0,
          "attributes": { "id": "legacy-modtm-telemetry" },
          "sensitive_attributes": []
        }
      ]
    },
    {
      "mode": "managed",
      "type": "random_uuid",
      "name": "telemetry",
      "provider": "provider[\"registry.terraform.io/hashicorp/random\"]",
      "instances": [
        {
          "index_key": 0,
          "schema_version": 0,
          "attributes": {
            "id": "00000000-0000-0000-0000-000000000000",
            "result": "00000000-0000-0000-0000-000000000000"
          },
          "sensitive_attributes": []
        }
      ]
    }
  ]
}
'@
        $null = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('state', 'push', $statePath) -Root $root
        $legacyInit = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('init', '-backend=false', '-input=false', '-upgrade', '-no-color') -Root $root
        $legacyInit.StdOut | Should -Match 'Azure/modtm'
        $plan = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('plan', '-refresh=false', '-input=false', '-lock=false', '-no-color', '-var=enable_telemetry=false') -Root $root
        $plan.StdOut | Should -Match 'modtm_telemetry\.telemetry\[0\] will no longer be managed'
        $plan.StdOut | Should -Match 'random_uuid\.telemetry\[0\] will no longer be managed'
        $apply = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('apply', '-refresh=false', '-input=false', '-auto-approve', '-no-color', '-var=enable_telemetry=false') -Root $root
        $apply.StdOut | Should -Match 'Apply complete! Resources: 0 added, 0 changed, 0 destroyed\.'
        $remaining = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('state', 'list') -Root $root
        $remaining.StdOut | Should -BeNullOrEmpty
        $cleanInit = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('init', '-backend=false', '-input=false', '-upgrade', '-no-color') -Root $root
        $cleanInit.StdOut | Should -Not -Match 'Finding Azure/modtm versions'
    }

    It 'keeps the <Name> fixture unit suite isolated from Azure after migration' -TestCases @(
        @{ Name = 'terraform-azurerm-avm-res-mock'; ExpectedRuns = 2 }
        @{ Name = 'terraform-azure-avm-res-mock'; ExpectedRuns = 4 }
    ) {
        param($Name, $ExpectedRuns)

        $source = Join-Path $script:repoRoot 'tests' 'fixtures' 'modules' $Name
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $source -Destination $root -Recurse -Force
        $null = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('init', '-backend=false', '-input=false', '-upgrade', '-no-color', '-test-directory=tests/unit') -Root $root
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match ("Success! {0} passed, 0 failed\." -f $ExpectedRuns)
    }
}
