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
        . (Join-Path $PSScriptRoot '..' '..' 'Helpers' 'TerraformQualification.ps1')
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
                Set-AvmTelemetryTagLintDirective -Targets @([pscustomobject]@{ Path = $Root; Profiles = @('root') })
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
