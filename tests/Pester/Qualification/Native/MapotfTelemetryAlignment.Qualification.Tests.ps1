#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: MAPOTF Terraform deployment telemetry' -Tag Qualification {
BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
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
        . (Join-Path $PSScriptRoot '..' '..' 'Helpers' 'TerraformAcceptance.ps1')
        $script:mapotfPath = InModuleScope 'Avm.Authoring' { (Resolve-AvmTool -Name mapotf).Path }
        $script:terraformPath = InModuleScope 'Avm.Authoring' { (Resolve-AvmTool -Name terraform).Path }
        $script:processEnvironment = InModuleScope 'Avm.Authoring' -Parameters @{ ToolPath = $script:terraformPath } {
            param($ToolPath)
            New-AvmToolPathEnvironment -ToolPath $ToolPath -ToolName terraform
        }
        foreach ($name in @('TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_validate',
                'TF_CLI_ARGS_test', 'TF_CLI_ARGS_plan', 'TF_CLI_ARGS_show')) {
            $script:processEnvironment[$name] = $null
        }
        $script:processEnvironment.CHECKPOINT_DISABLE = '1'

        function Invoke-TelemetryProcess {
            param([string] $FilePath, [string[]] $ArgumentList, [string] $Root, [switch] $IgnoreExitCode)

            if ($FilePath -ceq $script:terraformPath) {
                if ($ArgumentList[0] -cin @('apply', 'destroy', 'import')) {
                    throw [InvalidOperationException]::new('Qualification forbids direct real-provider mutation commands.')
                }
                if ($ArgumentList[0] -ceq 'test') {
                    return Invoke-MockedTerraformQualification -TerraformPath $FilePath -MapotfPath $script:mapotfPath `
                        -ProfilesRoot $script:profilesRoot -Root $Root -ArgumentList $ArgumentList -Environment $script:processEnvironment
                }
            }
            InModuleScope 'Avm.Authoring' -Parameters @{
                ToolPath = $FilePath
                Arguments = $ArgumentList
                Root = $Root
                Environment = $script:processEnvironment
                IgnoreExitCode = [bool]$IgnoreExitCode
            } {
                param($ToolPath, $Arguments, $Root, $Environment, $IgnoreExitCode)
                Invoke-AvmProcess -FilePath $ToolPath -ArgumentList $Arguments `
                    -WorkingDirectory $Root -EnvVars $Environment `
                    -IgnoreExitCode:$IgnoreExitCode `
                    -RetryNetworkFailure:($Arguments[0] -eq 'init')
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
            param([string] $Root, [string] $TestDirectory = 'tests')

            $null = Invoke-TelemetryProcess -FilePath $script:terraformPath `
                -ArgumentList @('fmt', '-no-color', '-recursive', $Root) -Root $Root
            $init = Invoke-TelemetryProcess -FilePath $script:terraformPath `
                -ArgumentList @('init', '-backend=false', '-input=false', '-no-color', "-test-directory=$TestDirectory") -Root $Root
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
    terraform = {
      source = "terraform.io/builtin/terraform"
    }
  }
}
'@
            if (-not $WithLegacy) {
                $terraform = @'
terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    terraform = {
      source = "terraform.io/builtin/terraform"
    }
  }
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

        function Add-LegacyResourceGroupTelemetry {
            param([string] $Root, [string] $Tags = 'null')

            Add-Content -LiteralPath (Join-Path $Root 'main.telemetry.tf') -Encoding utf8NoBOM -Value @"

resource "random_id" "telem" {
  count       = var.enable_telemetry ? 1 : 0
  byte_length = 4
}

resource "azurerm_resource_group_template_deployment" "telemetry" {
  count               = var.enable_telemetry ? 1 : 0
  deployment_mode     = "Incremental"
  name                = local.telem_arm_deployment_name
  resource_group_name = var.resource_group_name
  tags                = $Tags
  template_content    = local.telem_arm_template_content
}
"@
        }

        function Add-TelemetryAdditionalContentVariable {
            param(
                [string] $Root,
                [string] $Type = 'map(string)',
                [string] $Default = 'null'
            )

            Add-Content -LiteralPath (Join-Path $Root 'variables.tf') -Encoding utf8NoBOM -Value @"

variable "telemetry_additional_content" {
  type    = $Type
  default = $Default
}
"@
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

BeforeEach {
        $script:hadModtmEndpoint = $script:processEnvironment.ContainsKey('MODTM_ENDPOINT')
        $script:previousModtmEndpoint = $script:processEnvironment['MODTM_ENDPOINT']
    }

AfterEach {
        if ($script:hadModtmEndpoint) {
            $script:processEnvironment.MODTM_ENDPOINT = $script:previousModtmEndpoint
        }
        else {
            $script:processEnvironment.Remove('MODTM_ENDPOINT')
        }
    }

It 'preserves real local-library bindings and assertions without running their Terraform tests' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $dependency = Join-Path $root '.published' 'dependency'
        $unit = Join-Path $root 'tests' 'unit'
        $library = Join-Path $unit 'library'
        New-TelemetryModule -Root $root -WithLegacy -WithLocation
        $null = New-Item -ItemType Directory -Path $dependency, $library -Force
        $providers = Join-Path $root 'terraform.tf'
        $localProviders = @'
    alz = {
      source  = "azure/alz"
      version = "~> 0.21"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
'@
        [System.IO.File]::WriteAllText($providers,
            [System.IO.File]::ReadAllText($providers).Replace('  required_providers {', "  required_providers {`n$localProviders"),
            [System.Text.UTF8Encoding]::new($false))
        $libraryPath = Join-Path $library 'local.alz_architecture_definition.yml'
        Set-Content -LiteralPath $libraryPath -Encoding utf8NoBOM -Value @'
name: local
management_groups:
  - id: existing
    display_name: Local library management group
    exists: true
    parent_id: null
    archetypes:
      - empty
'@
        $libraryBytes = [System.IO.File]::ReadAllBytes($libraryPath)
        $published = Join-Path $dependency 'main.tf'
        Set-Content -LiteralPath $published -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "= 0.3.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
resource "modtm_telemetry" "published" {
  endpoint = "http://127.0.0.1:1/never-production"
  tags     = { fixture = "mock-only" }
}
resource "random_uuid" "published" {}
resource "azapi_resource" "published" {
  type                   = "Microsoft.Resources/resourceGroups@2025-04-01"
  name                   = "mock-only"
  parent_id              = "/subscriptions/00000000-0000-0000-0000-000000000000"
  location               = "eastus"
  body                   = {}
  response_export_values = []
}
output "identity" {
  value = {
    azure  = azapi_resource.published.id
    mocked = modtm_telemetry.published.id
    local  = random_uuid.published.result
  }
}
'@
        $publishedHash = (Get-FileHash -LiteralPath $published).Hash
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
data "alz_architecture" "local" {
  name                     = "local"
  root_management_group_id = "parent"
  location                 = var.location
}
resource "time_static" "local" {
  rfc3339 = "2026-01-01T00:00:00Z"
}
module "published" {
  source = "./.published/dependency"
}
'@
        $source = @'
provider "alz" {
  library_references = [{ custom_url = "./tests/unit/library" }]
}
provider "alz" {
  alias              = "library"
  library_references = [{ custom_url = "./tests/unit/library" }]
}
mock_provider "azapi" {}
mock_provider "modtm" {}
variables {
  location = "eastus"
}
run "implicit" {
  command = apply
  assert {
    condition     = data.alz_architecture.local.management_groups[0].exists
    error_message = "The real provider must read the authored local library."
  }
  assert {
    condition     = can(regex("^[A-Za-z0-9]{8}$", module.published.identity.mocked))
    error_message = "The unchanged dependency must use the ModTM mock."
  }
  assert {
    condition     = can(regex("^[A-Za-z0-9]{8}$", module.published.identity.azure))
    error_message = "Restoring the ModTM binding must preserve the dependency's AzAPI mock."
  }
  assert {
    condition     = can(regex("^[0-9a-f-]{36}$", module.published.identity.local))
    error_message = "The unchanged dependency must retain its real local random provider."
  }
  assert {
    condition     = time_static.local.rfc3339 == "2026-01-01T00:00:00Z"
    error_message = "The authored local time provider must retain its default binding."
  }
}
run "explicit" {
  command = plan
  providers = {
    alz   = alz.library # Keep the selected local library.
    azapi = azapi
    modtm = modtm
  }
  assert {
    condition     = data.alz_architecture.local.management_groups[0].exists
    error_message = "The same-provider alias must keep the real library behavior."
  }
}
'@
        $testPath = Join-Path $unit 'local-library.tftest.hcl'
        [System.IO.File]::WriteAllText($testPath, $source, [System.Text.UTF8Encoding]::new($false))
        $null = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
            -ArgumentList @('init', '-backend=false', '-input=false', '-no-color', '-test-directory=tests/unit')
        $lockPath = Join-Path $root '.terraform.lock.hcl'
        $manifestPath = Join-Path $root '.terraform' 'modules' 'modules.json'
        $lock = [System.IO.File]::ReadAllBytes($lockPath)
        $manifest = [System.IO.File]::ReadAllBytes($manifestPath)
        $version = Invoke-TelemetryProcess -FilePath $script:terraformPath -ArgumentList @('version', '-json') -Root $root
        $selections = (($version.StdOut | ConvertFrom-Json).provider_selections | ConvertTo-Json -Compress)
        $providerTree = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
            -ArgumentList @('providers', '-no-color', '-test-directory=tests/unit')
        foreach ($provider in @('azure/alz', 'azure/azapi', 'azure/modtm', 'hashicorp/random', 'hashicorp/time')) {
            $providerTree.StdOut | Should -Match ([regex]::Escape("registry.terraform.io/$provider"))
        }
        $inspectionArguments = @(
            'debug', '--tf-dir', $root, '--test-file', 'tests/unit/local-library.tftest.hcl',
            '--mptf-dir', (Join-Path $script:profilesRoot 'unit-test'), '--eval', 'data.test_file.this.result'
        )
        $inspection = Invoke-TelemetryProcess -FilePath $script:mapotfPath -Root $root -ArgumentList $inspectionArguments
        $before = $inspection.StdOut | ConvertFrom-Json -AsHashtable
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -BeExactly 'fail'
        [System.IO.File]::ReadAllText($testPath) | Should -BeExactly $source
        (Invoke-TelemetryEngine -Root $root).Status | Should -BeExactly 'pass'
        $inspection = Invoke-TelemetryProcess -FilePath $script:mapotfPath -Root $root -ArgumentList $inspectionArguments
        $after = $inspection.StdOut | ConvertFrom-Json -AsHashtable
        @($after.providers.Keys | Sort-Object) | Should -Be @($before.providers.Keys | Sort-Object)
        @($after.runs.Keys | Sort-Object) | Should -Be @($before.runs.Keys | Sort-Object)
        foreach ($name in $before.providers.Keys) {
            ($after.providers[$name].mptf.attributes | ConvertTo-Json -Depth 10 -Compress) |
                Should -BeExactly ($before.providers[$name].mptf.attributes | ConvertTo-Json -Depth 10 -Compress)
        }
        foreach ($name in $before.runs.Keys) {
            $after.runs[$name].mptf.attributes.command | Should -BeExactly $before.runs[$name].mptf.attributes.command
            ($after.runs[$name].assert.mptf.attributes | ConvertTo-Json -Depth 10 -Compress) |
                Should -BeExactly ($before.runs[$name].assert.mptf.attributes | ConvertTo-Json -Depth 10 -Compress)
        }
        $after.runs.implicit.mptf.attributes.Contains('providers') | Should -BeFalse
        $after.runs.explicit.mptf.attributes.providers |
            Should -BeExactly $before.runs.explicit.mptf.attributes.providers
        $after.mock_providers.Keys | Should -Not -Contain 'alz'
        $providerTree = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
            -ArgumentList @('providers', '-no-color', '-test-directory=tests/unit')
        foreach ($provider in @('azure/alz', 'azure/azapi', 'azure/modtm', 'hashicorp/random', 'hashicorp/time')) {
            $providerTree.StdOut | Should -Match ([regex]::Escape("registry.terraform.io/$provider"))
        }
        $validation = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
            -ArgumentList @('validate', '-json', '-test-directory=tests/unit')
        ($validation.StdOut | ConvertFrom-Json).valid | Should -BeTrue
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -BeExactly 'pass'
        (Invoke-TelemetryEngine -Root $root).Changed | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllBytes($lockPath) | Should -Be $lock
        [System.IO.File]::ReadAllBytes($manifestPath) | Should -Be $manifest
        [System.IO.File]::ReadAllBytes($libraryPath) | Should -Be $libraryBytes
        (Get-FileHash -LiteralPath $published).Hash | Should -BeExactly $publishedHash
        $version = Invoke-TelemetryProcess -FilePath $script:terraformPath -ArgumentList @('version', '-json') -Root $root
        (($version.StdOut | ConvertFrom-Json).provider_selections | ConvertTo-Json -Compress) | Should -BeExactly $selections
    }

It 'preserves default and alias bindings through <Graph> with fully mocked providers and rejects an unmocked dependency' -ForEach @(
    @{ Graph = 'direct dependencies'; Transitive = $false; TransitiveOnly = $false }
    @{ Graph = 'an unchanged intermediary and mixed Regions versions'; Transitive = $true; TransitiveOnly = $false }
    @{ Graph = 'only an unchanged intermediary and modern Regions sibling'; Transitive = $true; TransitiveOnly = $true }
) {
        param($Transitive, $TransitiveOnly)
        $root = Join-Path $TestDrive "mocked-provider-bindings-$Transitive-$TransitiveOnly"
        $dependency = Join-Path $root '.published' 'dependency'
        $unit = Join-Path $root 'tests' 'unit'
        New-TelemetryModule -Root $root -WithLegacy:(-not $TransitiveOnly) -WithLocation
        $null = New-Item -ItemType Directory -Path $dependency, $unit -Force
        $requirements = Join-Path $root 'terraform.tf'
        $requirementsContent = @'
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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}
'@
        if ($TransitiveOnly) {
            $requirementsContent = $requirementsContent.Replace(@'
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
'@, '')
        }
        Set-Content -LiteralPath $requirements -Encoding utf8NoBOM -Value $requirementsContent
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
resource "time_static" "current" {}
module "published" {
  source = "./.published/dependency"
  providers = {
    azapi  = azapi
    modtm  = modtm
    random = random
  }
}
module "implicit" {
  source = "./.published/dependency"
}
'@
        $unchangedFiles = @{}
        if ($Transitive) {
            $config = Join-Path $root '.published' 'config'
            $leaf = Join-Path $root '.published' 'leaf'
            $null = New-Item -ItemType Directory -Path $config, $leaf -Force
            Set-Content -LiteralPath (Join-Path $config 'main.tf') -Encoding utf8NoBOM -Value @'
module "dependency" {
  source = "../dependency"
}
module "regions" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.12.0"
  use_cached_data = true
}
module "leaf" {
  source = "../leaf"
}
output "identity" {
  value = module.dependency.identity
}
'@
            Set-Content -LiteralPath (Join-Path $leaf 'main.tf') -Value 'locals { value = "provider-free" }' -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $config 'lookup.tf.json') -Value '{"locals":{"region":"eastus"}}' -Encoding utf8NoBOM
            $main = Join-Path $root 'main.tf'
            $content = [IO.File]::ReadAllText($main).Replace(
                "module `"implicit`" {`n  source = `"./.published/dependency`"",
                "module `"implicit`" {`n  source = `"./.published/config`"")
            if ($TransitiveOnly) {
                $content = $content.Replace(@'
module "published" {
  source = "./.published/dependency"
  providers = {
    azapi  = azapi
    modtm  = modtm
    random = random
  }
}
'@, '')
            }
            [IO.File]::WriteAllText($main, $content, [Text.UTF8Encoding]::new($false))
            Add-Content -LiteralPath $main -Encoding utf8NoBOM -Value @'
module "regions" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.12.0"
  use_cached_data = true
}
'@
            foreach ($directory in @($config, $leaf)) {
                foreach ($file in Get-ChildItem -LiteralPath $directory -File) {
                    $unchangedFiles[$file.FullName] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
                }
            }
        }
        $published = Join-Path $dependency 'main.tf'
        Set-Content -LiteralPath $published -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    azapi = { source = "Azure/azapi", version = "~> 2.12" }
    modtm = { source = "Azure/modtm", version = "= 0.3.5" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
resource "modtm_telemetry" "published" {
  endpoint = "http://127.0.0.1:1/never-production"
  tags = { fixture = "mock-only" }
}
resource "random_uuid" "published" {}
resource "azapi_resource" "published" {
  type = "Microsoft.Resources/resourceGroups@2025-04-01"
  name = "mock-only"
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
  location = "eastus"
  body = {}
}
output "identity" {
  value = {
    azure = azapi_resource.published.id
    modtm = modtm_telemetry.published.id
    random = random_uuid.published.result
  }
}
'@
        $publishedBytes = [IO.File]::ReadAllBytes($published)
        $testPath = Join-Path $unit 'bindings.tftest.hcl'
        Set-Content -LiteralPath $testPath -Encoding utf8NoBOM -Value @'
mock_provider "terraform" {
  override_during = plan
  mock_resource "terraform_data" {
    defaults = { id = "mocked-builtin" }
  }
}
mock_provider "azapi" {
  override_during = plan
  mock_resource "azapi_resource" {
    defaults = { id = "default-azure" }
  }
}
mock_provider "modtm" {
  override_during = plan
  mock_resource "modtm_telemetry" {
    defaults = { id = "default-modtm" }
  }
}
mock_provider "random" {
  override_during = plan
  mock_resource "random_uuid" {
    defaults = { result = "default-random" }
  }
}
mock_provider "time" {
  override_during = plan
  mock_resource "time_static" {
    defaults = { id = "default-time" }
  }
}
mock_provider "azapi" {
  alias = "unit"
  override_during = plan
  mock_resource "azapi_resource" {
    defaults = { id = "aliased-azure" }
  }
}
mock_provider "modtm" {
  alias = "unit"
  override_during = plan
  mock_resource "modtm_telemetry" {
    defaults = { id = "aliased-modtm" }
  }
}
mock_provider "random" {
  alias = "unit"
  override_during = plan
  mock_resource "random_uuid" {
    defaults = { result = "aliased-random" }
  }
}
mock_provider "time" {
  alias = "unit"
  override_during = plan
  mock_resource "time_static" {
    defaults = { id = "aliased-time" }
  }
}
run "defaults" {
  command = plan
  state_key = "default-bindings"
  assert {
    condition = (
      module.published.identity.azure == "default-azure" &&
      module.published.identity.modtm == "default-modtm" &&
      module.implicit.identity.modtm == "default-modtm" &&
      module.published.identity.random == "default-random" &&
      time_static.current.id == "default-time" &&
      terraform_data.telemetry[0].id == "mocked-builtin"
    )
    error_message = "Restoring dependency bindings must preserve every default provider mock, including the built-in provider."
  }
}
run "aliases" {
  command = plan
  state_key = "aliased-bindings"
  providers = {
    azapi     = azapi.unit
    modtm     = modtm.unit
    random    = random.unit
    terraform = terraform
    time      = time.unit
  }
  assert {
    condition = (
      module.published.identity.azure == "aliased-azure" &&
      module.published.identity.modtm == "aliased-modtm" &&
      module.implicit.identity.modtm == "aliased-modtm" &&
      module.published.identity.random == "aliased-random" &&
      time_static.current.id == "aliased-time" &&
      terraform_data.telemetry[0].id == "mocked-builtin"
    )
    error_message = "Same-provider aliases must reach the intended mocks without falling back to a real or default provider."
  }
}
'@
        if ($TransitiveOnly) {
            $content = [IO.File]::ReadAllText($testPath).Replace('module.published.identity', 'module.implicit.identity')
            [IO.File]::WriteAllText($testPath, $content, [Text.UTF8Encoding]::new($false))
            [IO.File]::ReadAllText($requirements) | Should -Not -Match '(?m)^\s*modtm\s*='
        }
        $initialTestDirectory = if ($TransitiveOnly) { 'tests/initialization-only' } else { 'tests/unit' }
        $null = New-Item -ItemType Directory -Path (Join-Path $root $initialTestDirectory) -Force
        $null = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
            -ArgumentList @('init', '-backend=false', '-input=false', '-no-color', "-test-directory=$initialTestDirectory")
        $lockPath = Join-Path $root '.terraform.lock.hcl'
        $manifestPath = Join-Path $root '.terraform' 'modules' 'modules.json'
        $lock = [IO.File]::ReadAllBytes($lockPath)
        $manifest = [IO.File]::ReadAllBytes($manifestPath)
        $inspectionArguments = @(
            'debug', '--tf-dir', $root, '--test-file', 'tests/unit/bindings.tftest.hcl',
            '--mptf-dir', (Join-Path $script:profilesRoot 'unit-test'), '--eval', 'data.test_file.this.result'
        )
        $before = (Invoke-TelemetryProcess -FilePath $script:mapotfPath -Root $root -ArgumentList $inspectionArguments).
            StdOut | ConvertFrom-Json -AsHashtable
        $before.runs.defaults.mptf.attributes.Contains('providers') | Should -BeFalse
        [IO.File]::ReadAllText($requirements) | Should -Not -Match '(?m)^\s*terraform\s*='
        (Invoke-TelemetryEngine -Root $root).Status | Should -BeExactly 'pass'
        if ($TransitiveOnly) {
            InModuleScope Avm.Authoring -Parameters @{
                Root = $root; Tool = $script:mapotfPath; Profiles = $script:profilesRoot; Environment = $script:processEnvironment
            } {
                param($Root, $Tool, $Profiles, $Environment)
                $providers = Get-AvmTerraformUnitTestRequiredProvider -Path $Root -Options ([pscustomobject]@{
                        ToolPath = $Tool
                        ProfileDirs = @{ module = Join-Path $Profiles 'module' }
                        EnvVars = $Environment
                    })
                $providers.modtm.source | Should -BeExactly 'registry.terraform.io/azure/modtm'
                $providers.modtm.version | Should -Match '(^|,\s*)= 0\.3\.5(,|$)'
            }
        }
        [IO.File]::ReadAllBytes($lockPath) | Should -Be $lock
        [IO.File]::ReadAllBytes($manifestPath) | Should -Be $manifest
        if ($Transitive) {
            $null = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
                -ArgumentList @('init', '-backend=false', '-input=false', '-lockfile=readonly', '-no-color', '-test-directory=tests/unit')
            $manifest = [IO.File]::ReadAllBytes($manifestPath)
            $installed = [Text.Encoding]::UTF8.GetString($manifest) | ConvertFrom-Json -AsHashtable
            @($installed.Modules | Where-Object Key -CEQ 'regions')[0].Version | Should -BeExactly '0.13.0'
            @($installed.Modules | Where-Object Key -CEQ 'implicit.regions')[0].Version | Should -BeExactly '0.12.0'
            $null = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root -ArgumentList @('validate', '-no-color')
            $lintConfig = Join-Path $TestDrive 'modtm-contract.tflint.hcl'
            Set-Content -LiteralPath $lintConfig -Encoding utf8NoBOM -Value @'
plugin "terraform" {
  enabled = true
  preset = "recommended"
}
rule "terraform_required_providers" { enabled = true }
rule "terraform_unused_required_providers" { enabled = true }
'@
            InModuleScope Avm.Authoring -Parameters @{ Root = $root; Config = $lintConfig; Environment = $script:processEnvironment } {
                param($Root, $Config, $Environment)
                $lint = Invoke-AvmProcess -FilePath (Resolve-AvmTool -Name tflint).Path -WorkingDirectory $Root `
                    -EnvVars $Environment -ArgumentList @(
                        '--config', $Config, '--only=terraform_required_providers',
                        '--only=terraform_unused_required_providers', '--format=json'
                    )
                @((ConvertFrom-Json -InputObject $lint.StdOut).issues) | Should -HaveCount 0
            }
        }
        $calls = (Invoke-TelemetryProcess -FilePath $script:mapotfPath -Root $root -ArgumentList @(
            'debug', '--tf-dir', $root, '--mptf-dir', (Join-Path $script:profilesRoot 'provider-inheritance'),
            '--eval', 'data.module.provider_inheritance.result'
        )).StdOut | ConvertFrom-Json -AsHashtable
        if ($TransitiveOnly) {
            $calls.Contains('published') | Should -BeFalse
        }
        else {
            $calls.published.Contains('providers') | Should -BeFalse
        }
        $calls.implicit.Contains('providers') | Should -BeFalse
        $after = (Invoke-TelemetryProcess -FilePath $script:mapotfPath -Root $root -ArgumentList $inspectionArguments).
            StdOut | ConvertFrom-Json -AsHashtable
        [IO.File]::ReadAllText($requirements) | Should -Not -Match '(?m)^\s*terraform\s*='
        $after.runs.defaults.mptf.attributes.Contains('providers') | Should -BeFalse
        $after.runs.aliases.mptf.attributes.providers | Should -BeExactly $before.runs.aliases.mptf.attributes.providers
        foreach ($name in $before.runs.Keys) {
            $after.runs[$name].mptf.attributes.command | Should -BeExactly 'plan'
            ($after.runs[$name].assert.mptf.attributes | ConvertTo-Json -Depth 10 -Compress) |
                Should -BeExactly ($before.runs[$name].assert.mptf.attributes | ConvertTo-Json -Depth 10 -Compress)
        }
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit')
        $result.StdOut | Should -Match 'Success! 2 passed, 0 failed'
        $repeatFiles = Get-TerraformAcceptanceFiles -Root $root
        $drift = Invoke-TelemetryEngine -Root $root -CheckDrift
        $drift.Status | Should -BeExactly 'pass' -Because ($drift.Changed -join ', ')
        (Invoke-TelemetryEngine -Root $root).Changed | Should -BeNullOrEmpty
        $repeatedFiles = Get-TerraformAcceptanceFiles -Root $root
        $repeatedFiles.Count | Should -Be $repeatFiles.Count
        foreach ($file in $repeatFiles.Keys) {
            $repeatedFiles.ContainsKey($file) | Should -BeTrue
            $repeatedFiles[$file] | Should -BeExactly $repeatFiles[$file] -Because "$file must remain byte-stable"
        }
        [IO.File]::ReadAllBytes($published) | Should -Be $publishedBytes
        [IO.File]::ReadAllBytes($lockPath) | Should -Be $lock
        [IO.File]::ReadAllBytes($manifestPath) | Should -Be $manifest
        foreach ($file in $unchangedFiles.Keys) {
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) | Should -BeExactly $unchangedFiles[$file]
        }

        $validTest = [IO.File]::ReadAllBytes($testPath)
        Set-Content -LiteralPath (Join-Path $unit 'unmocked-dependency.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "terraform" {}
mock_provider "azapi" {}
mock_provider "random" {}
mock_provider "time" {}
run "reject_unmocked_modtm" {
  command = plan
}
'@
        { Invoke-TelemetryEngine -Root $root -CheckDrift } |
            Should -Throw '*introduced providers need default mocks or complete known alias bindings*'
        [IO.File]::ReadAllBytes($testPath) | Should -Be $validTest
        [IO.File]::ReadAllBytes($published) | Should -Be $publishedBytes
    }

It 'emits the reviewed telemetry bytes for independent fresh migrations and repeated runs' {
    $migration = Join-Path $script:repoRoot 'tests' 'fixtures' 'migrations' 'utility'
    $expected = [IO.File]::ReadAllBytes((Join-Path $migration 'expected' 'main.telemetry.tf'))
    foreach ($index in 1..3) {
        $root = Join-Path $TestDrive "fresh-$index"
        $null = New-Item -ItemType Directory -Path $root
        Copy-Item -LiteralPath (Join-Path $migration 'input' 'main.telemetry.tf') -Destination $root
        foreach ($pass in 1..2) {
            Invoke-TelemetryProfiles -Root $root
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                Remove-AvmTelemetryTagLintDirective -Targets @([pscustomobject]@{ Path = $Root; Profiles = @('root') })
            }
            $null = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root -ArgumentList @('fmt', '-no-color')
            [IO.File]::ReadAllBytes((Join-Path $root 'main.telemetry.tf')) |
                Should -Be $expected -Because "fresh fixture $index, pass $pass must have the same reviewed output"
        }
    }
}

It 'does not reorder an owner deployment precondition or its headers' {
    $root = Join-Path $TestDrive 'owner-deployment'
    $null = New-Item -ItemType Directory -Path $root
    $path = Join-Path $root 'main.tf'
    $content = @'
resource "azapi_resource" "telemetry" {
  type = "Microsoft.Resources/deployments@2025-04-01"
  name = "owner-deployment"
  create_headers = { "User-Agent" = "owner" }
  delete_headers = { "If-Match" = "*" }
  lifecycle {
    precondition {
      error_message = "Owner condition."
      condition = var.owner
    }
  }
}
'@
    [IO.File]::WriteAllText($path, $content + "`n")
    $null = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root -ArgumentList @('fmt', '-no-color')
    $content = [IO.File]::ReadAllText($path)
    $null = Invoke-TelemetryProcess -FilePath $script:mapotfPath -Root $root -ArgumentList @(
        'transform', '--tf-dir', $root, '--mptf-dir', (Join-Path $script:profilesRoot 'module')
    )
    [IO.File]::ReadAllText($path) | Should -BeExactly $content
}

It 'retires older resource-group telemetry without destroying state: <Case>' -ForEach (@(
        @{ Case = 'older transport only'; WithModtm = $false; OtherRandom = $false; Tags = 'null' }
        @{ Case = 'both legacy transports'; WithModtm = $true; OtherRandom = $false; Tags = 'null' }
        @{ Case = 'authored tags and other random use'; WithModtm = $true; OtherRandom = $true; Tags = '{ module = "avm-res-kusto-cluster" }' }
    ) | Where-Object { $_.Case -ceq 'authored tags and other random use' }) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation -WithLegacy:$WithModtm
        if (-not $WithModtm) {
            Set-Content -LiteralPath (Join-Path $root 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
'@
        }
        Add-LegacyResourceGroupTelemetry -Root $root -Tags $Tags
        if ($OtherRandom) {
            Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
provider "random" {
  alias = "owner"
}
ephemeral "random_password" "naming" {
  provider = random.owner
  length   = 20
  special  = false
}
'@
        }

        Invoke-TelemetryProfiles -Root $root

        $telemetry = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        $providers = Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw
        $telemetry | Should -Not -Match 'resource "azurerm_resource_group_template_deployment" "telemetry"'
        $telemetry | Should -Not -Match 'resource "random_id" "telem"'
        $telemetry | Should -Not -Match 'local\.telem_arm_'
        $telemetry | Should -Match '(?s)removed \{\s*from\s*=\s*azurerm_resource_group_template_deployment\.telemetry\s*lifecycle \{\s*destroy\s*=\s*false'
        $telemetry | Should -Match '(?s)removed \{\s*from\s*=\s*random_id\.telem\s*lifecycle \{\s*destroy\s*=\s*false'
        @([regex]::Matches($telemetry, '(?m)^removed \{')) |
            Should -HaveCount $(if ($WithModtm) { 4 } else { 2 })
        if ($OtherRandom) {
            $providers | Should -Match '(?m)^\s*random\s*='
            $providers | Should -Match '(?s)random\s*=\s*\{\s*source\s*=\s*"hashicorp/random"\s*version\s*=\s*"~> 3[.]6"'
            Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw |
                Should -Match '(?s)ephemeral "random_password" "naming" \{\s*provider\s*=\s*random[.]owner\s*length\s*=\s*20\s*special\s*=\s*false'
        }
        else {
            $providers | Should -Not -Match '(?m)^\s*random\s*='
        }

        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw | Should -BeExactly $telemetry
        Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw | Should -BeExactly $providers
        Assert-TelemetryTerraformValid -Root $root
    }

It 'preserves nonstandard resource-group deployments and random helpers: <Case>' -ForEach (@(
        @{ Case = 'custom deployment name'; Attribute = 'name'; Expression = '"business-deployment"'; RemoveDeployment = $false }
        @{ Case = 'custom template'; Attribute = 'template_content'; Expression = '"{}"'; RemoveDeployment = $false }
        @{ Case = 'different deployment gate'; Attribute = 'count'; Expression = '1'; RemoveDeployment = $false }
        @{ Case = 'different deployment mode'; Attribute = 'deployment_mode'; Expression = '"Complete"'; RemoveDeployment = $false }
        @{ Case = 'different helper length'; Attribute = 'byte_length'; Expression = '8'; RemoveDeployment = $true }
        @{ Case = 'different helper gate'; Attribute = 'helper_count'; Expression = '1'; RemoveDeployment = $true }
    ) | Where-Object { $_.Case -cin @('custom deployment name', 'different helper length') }) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation -WithLegacy
        $properties = @{
            count            = 'var.enable_telemetry ? 1 : 0'
            deployment_mode  = '"Incremental"'
            name             = 'local.telem_arm_deployment_name'
            template_content = 'local.telem_arm_template_content'
            byte_length      = '4'
            helper_count     = 'var.enable_telemetry ? 1 : 0'
        }
        $properties[$Attribute] = $Expression
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @"
resource "azurerm_resource_group_template_deployment" "telemetry" {
  count               = $($properties.count)
  deployment_mode     = $($properties.deployment_mode)
  name                = $($properties.name)
  resource_group_name = "business-resources"
  template_content    = $($properties.template_content)
}

resource "random_id" "telem" {
  count       = $($properties.helper_count)
  byte_length = $($properties.byte_length)
}
"@

        Invoke-TelemetryProfiles -Root $root

        $main = Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw
        $telemetry = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        if ($RemoveDeployment) {
            $main | Should -Not -Match 'resource "azurerm_resource_group_template_deployment" "telemetry"'
            $telemetry | Should -Match 'from\s*=\s*azurerm_resource_group_template_deployment\.telemetry'
        }
        else {
            $main | Should -Match 'resource "azurerm_resource_group_template_deployment" "telemetry"'
            $telemetry | Should -Not -Match 'from\s*=\s*azurerm_resource_group_template_deployment\.telemetry'
        }
        $main | Should -Match ([regex]::Escape($Expression))
        $main | Should -Match 'resource "random_id" "telem"'
        $telemetry | Should -Not -Match 'from\s*=\s*random_id\.telem'
        Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw |
            Should -Match '(?m)^\s*random\s*='
    }

It 'retains a legacy random helper still needed by authored <SourceKind>' -ForEach (@(
        @{ SourceKind = 'locals'; Filename = 'locals.tf'; Source = 'locals { legacy_instance = try(random_id.telem[0].hex, null) }' }
        @{
            SourceKind = 'outputs'
            Filename = 'outputs.tf'
            Source = @'
output "legacy_instance" {
  value = try(random_id.telem[0].hex, null)
}
'@
        }
        @{
            SourceKind = 'commented traversals'
            Filename = 'outputs.tf'
            Source = @'
output "legacy_instance" {
  value = try(random_id /* retained */ .telem[0].hex, null)
}
'@
        }
        @{ SourceKind = 'JSON configuration'; Filename = 'instance.tf.json'; Source = '{"locals":{"legacy_instance":"${try(random_id.telem[0].hex, null)}"}}' }
    ) | Where-Object { $_.SourceKind -cin @('commented traversals', 'JSON configuration') }) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation -WithLegacy
        Add-LegacyResourceGroupTelemetry -Root $root
        $sourceFile = Join-Path $root $Filename
        Set-Content -LiteralPath $sourceFile -Encoding utf8NoBOM -Value $Source

        Invoke-TelemetryProfiles -Root $root

        $telemetry = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        $telemetry | Should -Not -Match 'resource "azurerm_resource_group_template_deployment" "telemetry"'
        $telemetry | Should -Match 'from\s*=\s*azurerm_resource_group_template_deployment\.telemetry'
        $telemetry | Should -Match 'resource "random_id" "telem"'
        $telemetry | Should -Not -Match 'from\s*=\s*random_id\.telem'
        Get-Content -LiteralPath $sourceFile -Raw | Should -Match 'telem\[0\]\.hex'
        Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw |
            Should -Match '(?m)^\s*random\s*='
        Assert-TelemetryTerraformValid -Root $root
    }

It 'proves explicit built-in mock selection during a local plan without applying' {
    $root = Join-Path $TestDrive 'builtin-mock-contract'
    $unit = Join-Path $root 'tests' 'unit'
    $child = Join-Path $root 'child'
    $null = New-Item -ItemType Directory -Path $unit, $child -Force
    Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
      version = "~> 3.6"
    }
    terraform = {
      source = "terraform.io/builtin/terraform"
    }
  }
}
resource "terraform_data" "contract" {
  input = "authored-input"
}
module "child" {
  source = "./child"
  providers = {
    random = random
  }
}
'@
    Set-Content -LiteralPath (Join-Path $child 'main.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
resource "terraform_data" "contract" {
  input = "child-input"
}
output "id" {
  value = terraform_data.contract.id
}
output "input" {
  value = terraform_data.contract.input
}
'@
    Set-Content -LiteralPath (Join-Path $unit 'mock.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "random" {}
mock_provider "terraform" {
  override_during = plan
  mock_resource "terraform_data" {
    defaults = {
      id     = "native-qualification-mock"
      output = "mocked-output"
    }
  }
}
run "mock_contract" {
  command = plan
  providers = {
    random = random
    terraform = terraform
  }
  assert {
    condition = (
      terraform_data.contract.id == "native-qualification-mock" &&
      terraform_data.contract.output == "mocked-output" &&
      terraform_data.contract.input == "authored-input" &&
      module.child.id == "native-qualification-mock" &&
      module.child.input == "child-input"
    )
    error_message = "The built-in provider must use the selected native mock, not a real apply."
  }
}
'@
    $null = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
        -ArgumentList @('init', '-backend=false', '-input=false', '-no-color', '-test-directory=tests/unit')
    $result = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
        -ArgumentList @('test', '-no-color', '-test-directory=tests/unit')
    $result.StdOut | Should -Match 'Success! 1 passed, 0 failed'
    $testPath = Join-Path $unit 'mock.tftest.hcl'
    Set-Content -LiteralPath $testPath -Encoding utf8NoBOM -Value @'
mock_provider "random" {}
run "unmocked" { command = plan }
'@
    {
        Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit')
    } | Should -Throw "*requires a default mock for 'terraform.io/builtin/terraform'*"
    Set-Content -LiteralPath $testPath -Encoding utf8NoBOM -Value @'
mock_provider "terraform" {}
mock_provider "random" {}
run "incomplete" {
  command = plan
  providers = {}
}
'@
    {
        Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $root `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit')
    } | Should -Throw '*requires complete known same-provider mock mappings*'
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
mock_provider "terraform" {}
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
    location = "usgovvirginia"
  }
  assert {
    condition     = azapi_resource.telemetry[0].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000"
    error_message = "Telemetry must deploy at the active subscription scope."
  }
  assert {
    condition     = azapi_resource.telemetry[0].location == "usgovvirginia"
    error_message = "The telemetry deployment must use var.location."
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

It 'appends deterministic additional map content without changing null or empty telemetry names' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Add-TelemetryAdditionalContentVariable -Root $root
        Invoke-TelemetryProfiles -Root $root
        $generatedPath = Join-Path $root 'main.telemetry.tf'
        $generated = Get-Content -LiteralPath $generatedPath -Raw
        $generated | Should -Match '(?s)avm_telemetry_additional_content_name\s*=\s*var[.]telemetry_additional_content\s*==\s*null'
        $generated | Should -Match 'sort\(keys\(var[.]telemetry_additional_content\)\)'
        $generated | Should -Match 'var[.]telemetry_additional_content\[key\]\s*==\s*null\s*[?]\s*""'
        $generated | Should -Match 'local[.]avm_telemetry_additional_content_name\s*==\s*""\s*[?]\s*""\s*:\s*"-[$]\{local[.]avm_telemetry_additional_content_name\}"'
        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath $generatedPath -Raw | Should -BeExactly $generated
        Assert-TelemetryTerraformValid -Root $root
        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $testDirectory 'additional-content.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "terraform" {}
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "null" {
  command = apply
  variables {
    location                     = "eastus"
    telemetry_additional_content = null
  }
  assert {
    condition     = can(regex("^46d3xtrf[.]res[.]a1b2c3d[.]0-0-0[.]x[.][0-9a-f]{4}$", azapi_resource.telemetry[0].name))
    error_message = "A null additional-content map must preserve the telemetry name."
  }
}

run "empty" {
  command = plan
  variables {
    location                     = "eastus"
    telemetry_additional_content = {}
  }
  assert {
    condition     = can(regex("^46d3xtrf[.]res[.]a1b2c3d[.]0-0-0[.]x[.][0-9a-f]{4}$", azapi_resource.telemetry[0].name))
    error_message = "An empty additional-content map must preserve the telemetry name."
  }
}

run "sorted" {
  command = plan
  variables {
    location = "eastus"
    telemetry_additional_content = {
      zeta     = "two"
      alpha    = "one"
      nullable = null
    }
  }
  assert {
    condition     = can(regex("^46d3xtrf[.]res[.]a1b2c3d[.]0-0-0[.]x[.][0-9a-f]{4}-alpha-one-nullable--zeta-two$", azapi_resource.telemetry[0].name))
    error_message = "Additional content must retain null values and append sorted key-value pairs."
  }
}

run "parentheses" {
  command = plan
  variables {
    location = "eastus"
    telemetry_additional_content = {
      ring = "blue(green)"
    }
  }
  assert {
    condition     = can(regex("-ring-blue\\(green\\)$", azapi_resource.telemetry[0].name))
    error_message = "Additional content must preserve parentheses allowed in deployment names."
  }
}
'@
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match 'Success! 4 passed, 0 failed\.'
    }

It 'ignores a non-map telemetry additional-content declaration without rewriting it' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Add-TelemetryAdditionalContentVariable -Root $root -Type 'string' -Default '"author-owned"'
        $variablesPath = Join-Path $root 'variables.tf'
        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath $variablesPath -Raw |
            Should -Match '(?s)variable "telemetry_additional_content" \{\s*type\s*=\s*string\s*default\s*=\s*"author-owned"\s*\}'
        $generatedPath = Join-Path $root 'main.telemetry.tf'
        $generated = Get-Content -LiteralPath $generatedPath -Raw
        $generated | Should -Not -Match 'var[.]telemetry_additional_content'
        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath $generatedPath -Raw | Should -BeExactly $generated
    }

It 'updates an already migrated telemetry resource when additional content is declared' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Invoke-TelemetryProfiles -Root $root
        Add-TelemetryAdditionalContentVariable -Root $root
        Invoke-TelemetryProfiles -Root $root
        $generatedPath = Join-Path $root 'main.telemetry.tf'
        $generated = Get-Content -LiteralPath $generatedPath -Raw
        $generated | Should -Match '(?s)avm_telemetry_additional_content_name\s*=\s*var[.]telemetry_additional_content\s*==\s*null'
        $generated | Should -Match 'name\s*=\s*format\("%s%s"'
        $generated | Should -Match 'length\(local[.]avm_metadata[.]telemetryIdPrefix\) \+ length\(local[.]avm_telemetry_version_token\) \+ 8 \+'
        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath $generatedPath -Raw | Should -BeExactly $generated
    }

It 'clears a generated additional-content local when its authored variable is removed or unsupported' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Add-TelemetryAdditionalContentVariable -Root $root
        Invoke-TelemetryProfiles -Root $root
        $variablesPath = Join-Path $root 'variables.tf'
        $withoutAdditionalContent = (Get-Content -LiteralPath $variablesPath -Raw) -replace '(?s)(?:\A|\r?\n)variable "telemetry_additional_content" \{.*?\r?\n\}\r?\n?', ''
        Set-Content -LiteralPath $variablesPath -Encoding utf8NoBOM -Value $withoutAdditionalContent
        (Get-Content -LiteralPath $variablesPath -Raw) | Should -Not -Match 'variable "telemetry_additional_content"'
        Invoke-TelemetryProfiles -Root $root
        $generatedPath = Join-Path $root 'main.telemetry.tf'
        $generated = Get-Content -LiteralPath $generatedPath -Raw
        $generated | Should -Match 'avm_telemetry_additional_content_name\s*=\s*""'
        $generated | Should -Not -Match 'var[.]telemetry_additional_content'
        $generated | Should -Not -Match 'name\s*=\s*format\("%s%s"'

        Add-TelemetryAdditionalContentVariable -Root $root -Type 'string' -Default '"author-owned"'
        Invoke-TelemetryProfiles -Root $root
        $generated = Get-Content -LiteralPath $generatedPath -Raw
        $generated | Should -Match 'avm_telemetry_additional_content_name\s*=\s*""'
        $generated | Should -Not -Match 'var[.]telemetry_additional_content'
        $generated | Should -Not -Match 'name\s*=\s*format\("%s%s"'
    }

It 'composes native plan clocks with a stable-name in-place mocked telemetry update' {
        . (Join-Path $PSScriptRoot '..' '..' 'Helpers' 'TerraformTelemetryClock.ps1')
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
        Assert-TelemetryTerraformValid -Root $root
        @(Get-ChildItem -LiteralPath $root -File -Filter '*_override.tf*') | Should -HaveCount 0
        $sourceHashes = @{}
        foreach ($file in Get-ChildItem -LiteralPath $root -File -Force) {
            $sourceHashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
        $bodyResult = Invoke-TelemetryProcess -FilePath $script:mapotfPath -Root $root -ArgumentList @(
            'debug', '--tf-dir', $root, '--mptf-dir', (Join-Path $script:profilesRoot 'module'),
            '--eval', 'data.resource.telemetry_order.result.azapi_resource.telemetry.body'
        )
        $body = $bodyResult.StdOut | ConvertFrom-Json
        $body | Should -BeOfType ([string])
        $overrideJson = New-TerraformTelemetryClockOverride -Body $body

        $clockRoot = Join-Path $TestDrive ('native-clock-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $clockRoot
        Set-Content -LiteralPath (Join-Path $clockRoot 'main.tf') -Encoding utf8NoBOM -Value @'
output "plan_time" {
  value = plantimestamp()
}
'@
        $null = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $clockRoot -ArgumentList @(
            'init', '-backend=false', '-input=false', '-no-color'
        )
        $nativeTimes = [Collections.Generic.List[string]]::new()
        $wait = [Diagnostics.Stopwatch]::new()
        foreach ($phase in @('first', 'second')) {
            if ($phase -ceq 'second') {
                $deadline = [DateTimeOffset]::Parse($nativeTimes[0], [Globalization.CultureInfo]::InvariantCulture).AddSeconds(2)
                $wait.Start()
                while ([DateTimeOffset]::UtcNow -lt $deadline) {
                    if ($wait.Elapsed.TotalSeconds -ge 5) {
                        throw [InvalidOperationException]::new('Native qualification clock did not cross its bounded timing boundary.')
                    }
                    Start-Sleep -Milliseconds 50
                }
                $wait.Stop()
            }
            $planPath = Join-Path $clockRoot "$phase.tfplan"
            $null = Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $clockRoot -ArgumentList @(
                'plan', '-refresh=false', '-input=false', '-lock=false', '-no-color', "-out=$planPath"
            )
            $clockJson = (Invoke-TelemetryProcess -FilePath $script:terraformPath -Root $clockRoot `
                    -ArgumentList @('show', '-json', $planPath)).StdOut
            $clockPlan = [System.Text.Json.JsonDocument]::Parse($clockJson)
            try {
                $resourceChanges = [System.Text.Json.JsonElement]::new()
                $clockPlan.RootElement.TryGetProperty('resource_changes', [ref]$resourceChanges) | Should -BeFalse
                $nativeTime = $clockPlan.RootElement.GetProperty('planned_values').GetProperty('outputs').
                    GetProperty('plan_time').GetProperty('value').GetString()
                $nativeTime | Should -BeExactly $clockPlan.RootElement.GetProperty('timestamp').GetString()
                $nativeTimes.Add($nativeTime)
            }
            finally { $clockPlan.Dispose() }
        }
        $firstTime = [DateTimeOffset]::Parse($nativeTimes[0], [Globalization.CultureInfo]::InvariantCulture)
        $secondTime = [DateTimeOffset]::Parse($nativeTimes[1], [Globalization.CultureInfo]::InvariantCulture)
        ($secondTime - $firstTime).TotalSeconds | Should -BeGreaterOrEqual 2
        $wait.Elapsed.TotalSeconds | Should -BeLessThan 6

        $clockVariablePath = Join-Path $root 'qualification_clock.tf'
        Set-Content -LiteralPath $clockVariablePath -Encoding utf8NoBOM -Value @'
variable "qualification_plan_time" {
  type = string
}
'@
        $overridePath = Join-Path $root 'qualification_clock_override.tf.json'
        [IO.File]::WriteAllText($overridePath, $overrideJson + "`n", [Text.UTF8Encoding]::new($false))
        $overrideHash = (Get-FileHash -LiteralPath $overridePath -Algorithm SHA256).Hash
        $clockVariableHash = (Get-FileHash -LiteralPath $clockVariablePath -Algorithm SHA256).Hash
        $overrideDocument = Get-Content -LiteralPath $overridePath -Raw | ConvertFrom-Json -AsHashtable
        @($overrideDocument.Keys) | Should -Be @('resource')
        @($overrideDocument.resource.Keys) | Should -Be @('azapi_resource')
        @($overrideDocument.resource.azapi_resource.Keys) | Should -Be @('telemetry')
        @($overrideDocument.resource.azapi_resource.telemetry.Keys) | Should -Be @('body')
        $overrideDocument.resource.azapi_resource.telemetry.body |
            Should -BeExactly ('${' + $body.Replace('plantimestamp()', 'var.qualification_plan_time') + '}')
        foreach ($name in $sourceHashes.Keys) {
            (Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash | Should -BeExactly $sourceHashes[$name]
        }

        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        $testPath = Join-Path $testDirectory 'repeat.tftest.hcl'
        Set-Content -LiteralPath $testPath -Encoding utf8NoBOM -Value @"
mock_provider "terraform" {
  mock_resource "terraform_data" {}
}
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
  providers = {
    azapi     = azapi
    terraform = terraform
  }
  variables {
    qualification_plan_time = "$($nativeTimes[0])"
  }
  assert {
    condition     = length(azapi_resource.telemetry) == 1
    error_message = "The first apply must create one telemetry deployment."
  }
  assert {
    condition     = output.telemetry_apply_id == var.qualification_plan_time
    error_message = "The clock-only seam must use the first native timestamp."
  }
}

run "second" {
  command = plan
  providers = {
    azapi     = azapi
    terraform = terraform
  }
  variables {
    qualification_plan_time = "$($nativeTimes[1])"
  }
  assert {
    condition = (
      output.telemetry_name == run.first.telemetry_name &&
      output.telemetry_apply_id != run.first.telemetry_apply_id
    )
    error_message = "The next normal plan must update telemetry without changing its name."
  }
  assert {
    condition     = output.telemetry_apply_id == var.qualification_plan_time
    error_message = "The clock-only seam must use the ordered second native timestamp."
  }
}
"@
        $testHash = (Get-FileHash -LiteralPath $testPath -Algorithm SHA256).Hash
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', '-json', '-verbose', '-var=location=eastus', '-test-directory=tests/unit') -Root $root
        $records = [Collections.Generic.List[object]]::new()
        $planJson = [Collections.Generic.List[string]]::new()
        foreach ($line in $result.StdOut -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
            $record = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop
            $records.Add($record)
            if ($record.type -ceq 'test_plan') { $planJson.Add($line) }
        }
        $completed = @($records | Where-Object {
                $_.type -ceq 'test_run' -and $_.test_run['status'] -cin @('pass', 'fail', 'error', 'skip')
            })
        $completed | Should -HaveCount 2
        @($completed | Where-Object { $_.test_run.status -cne 'pass' }) | Should -HaveCount 0
        $plans = @($records | Where-Object { $_.type -ceq 'test_plan' })
        $plans | Should -HaveCount 1
        $plans[0]['@testrun'] | Should -BeExactly 'second'
        $plans[0]['@testfile'].Replace('\', '/') | Should -BeExactly 'tests/unit/repeat.tftest.hcl'
        $plan = $plans[0].test_plan
        $planDocument = [System.Text.Json.JsonDocument]::Parse($planJson[0])
        try {
            $applyIdChange = $planDocument.RootElement.GetProperty('test_plan').GetProperty('output_changes').
                GetProperty('telemetry_apply_id')
            $applyIdChange.GetProperty('before').GetString() | Should -BeExactly $nativeTimes[0]
            $applyIdChange.GetProperty('after').GetString() |
                Should -BeExactly $nativeTimes[1]
        }
        finally { $planDocument.Dispose() }
        $changes = @($plan.resource_changes | Where-Object { $_.mode -ceq 'managed' })
        $telemetry = @($changes | Where-Object { $_.address -ceq 'azapi_resource.telemetry[0]' })
        $telemetry | Should -HaveCount 1
        $telemetry[0].change.actions | Should -Be @('update')
        foreach ($change in $changes | Where-Object { $_.address -cne 'azapi_resource.telemetry[0]' }) {
            $change.change.actions | Should -Be @('no-op')
        }
        $expectedFiles = @(@($sourceHashes.Keys) + @('qualification_clock.tf', 'qualification_clock_override.tf.json') | Sort-Object)
        @(Get-ChildItem -LiteralPath $root -File -Force | ForEach-Object Name | Sort-Object) | Should -Be $expectedFiles
        foreach ($name in $sourceHashes.Keys) {
            (Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash | Should -BeExactly $sourceHashes[$name]
        }
        (Get-FileHash -LiteralPath $overridePath -Algorithm SHA256).Hash | Should -BeExactly $overrideHash
        (Get-FileHash -LiteralPath $clockVariablePath -Algorithm SHA256).Hash | Should -BeExactly $clockVariableHash
        (Get-FileHash -LiteralPath $testPath -Algorithm SHA256).Hash | Should -BeExactly $testHash
        Write-Information ("Compositional clock proof: first={0}; second={1}; waitMs={2}; generatedSha256={3}; overrideSha256={4}; actions=update" -f
            $nativeTimes[0], $nativeTimes[1], $wait.ElapsedMilliseconds, $sourceHashes['main.telemetry.tf'], $overrideHash) -InformationAction Continue
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
mock_provider "terraform" {}
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
            -ArgumentList @('test', '-no-color', '-var=location=eastus', '-test-directory=tests/unit') -Root $root
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
mock_provider "terraform" {}
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
                -ArgumentList @('test', '-no-color', '-var=location=eastus', '-test-directory=tests/unit') -Root $root
        } | Should -Throw '*64-character limit*'
    }

It 'accepts additional content at the 64-character name limit' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Add-TelemetryAdditionalContentVariable -Root $root
        Invoke-TelemetryProfiles -Root $root
        Assert-TelemetryTerraformValid -Root $root
        $manifestPath = Join-Path $root '.terraform' 'modules' 'modules.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force
        @{ Modules = @(@{ Dir = '.'; Version = '1'; Source = 'C:/private/customer/module' }) } |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $testDirectory 'name.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "terraform" {}
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "name" {
  command = apply
  variables {
    location = "eastus"
    telemetry_additional_content = {
      a = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    }
  }
  assert {
    condition = (
      length(azapi_resource.telemetry[0].name) == 64 &&
      can(regex("^46d3xtrf[.]res[.]a1b2c3d[.]1[.]x[.][0-9a-f]{4}-a-x{32}$", azapi_resource.telemetry[0].name))
    )
    error_message = "The complete telemetry name including additional content must fit Azure's 64-character limit."
  }
}
'@
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match 'Success! 1 passed, 0 failed\.'
    }

It 'rejects additional content that produces a 65-character deployment name' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Add-TelemetryAdditionalContentVariable -Root $root
        Invoke-TelemetryProfiles -Root $root
        Assert-TelemetryTerraformValid -Root $root
        $manifestPath = Join-Path $root '.terraform' 'modules' 'modules.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force
        @{ Modules = @(@{ Dir = '.'; Version = '1'; Source = 'C:/private/customer/module' }) } |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $testDirectory 'name.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "terraform" {}
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "name" {
  command = plan
  variables {
    location = "eastus"
    telemetry_additional_content = {
      a = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    }
  }
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

It 'rejects invalid additional content before creating an Azure deployment name' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Add-TelemetryAdditionalContentVariable -Root $root
        Invoke-TelemetryProfiles -Root $root
        Assert-TelemetryTerraformValid -Root $root
        $testDirectory = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $testDirectory 'name.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "terraform" {}
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "name" {
  command = plan
  variables {
    location = "eastus"
    telemetry_additional_content = {
      invalid = "contains a space"
    }
  }
  assert {
    condition     = length(azapi_resource.telemetry) == 1
    error_message = "The plan should be rejected by the telemetry name precondition."
  }
}
'@
        {
            Invoke-TelemetryProcess -FilePath $script:terraformPath `
                -ArgumentList @('test', '-no-color', '-test-directory=tests/unit') -Root $root
        } | Should -Throw '*underscores, hyphens, and parentheses*'
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
mock_provider "terraform" {}
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
            -ArgumentList @('test', '-no-color', '-var=location=eastus', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match 'Success! 1 passed, 0 failed\.'
    }
}
