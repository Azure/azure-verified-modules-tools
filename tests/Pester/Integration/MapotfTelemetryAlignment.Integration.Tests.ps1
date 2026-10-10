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
        foreach ($name in @('TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_validate', 'TF_CLI_ARGS_test')) {
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
                    -WorkingDirectory $Root -EnvVars $Environment `
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
                -ArgumentList @('init', '-backend=false', '-input=false', '-upgrade', '-no-color', "-test-directory=$TestDirectory") -Root $Root
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

        function Add-LegacyAzapiHeaderHelpers {
            param([string] $Root, [switch] $SplitBlocks, [string] $HeaderExpression)

            $values = [ordered]@{
                avm_azapi_header = 'join(" ", [for k, v in local.avm_azapi_headers : "${k}=${v}"])'
                avm_azapi_headers = @'
!var.enable_telemetry ? {} : (local.fork_avm ? {
  fork_avm  = "true"
  random_id = one(random_uuid.telemetry).result
  } : {
  avm                = "true"
  random_id          = one(random_uuid.telemetry).result
  avm_module_source  = one(data.modtm_module_source.telemetry).module_source
  avm_module_version = one(data.modtm_module_source.telemetry).module_version
})
'@
                fork_avm = '!anytrue([for r in local.valid_module_source_regex : can(regex(r, one(data.modtm_module_source.telemetry).module_source))])'
                valid_module_source_regex = @'
[
  "registry.terraform.io/[A|a]zure/.+",
  "registry.opentofu.io/[A|a]zure/.+",
  "git::https://github\\.com/[A|a]zure/.+",
  "git::ssh:://git@github\\.com/[A|a]zure/.+",
]
'@
            }
            if ($HeaderExpression) {
                $values['avm_azapi_header'] = $HeaderExpression
            }
            $attributes = @($values.GetEnumerator() | ForEach-Object { "  $($_.Key) = $($_.Value)" })
            $attributes += '  customer_value = "keep"'
            $source = if ($SplitBlocks) {
                ($attributes | ForEach-Object { "locals {`n$_`n}" }) -join "`n`n"
            }
            else {
                "locals {`n$($attributes -join "`n")`n}"
            }
            Add-Content -LiteralPath (Join-Path $Root 'main.telemetry.tf') -Encoding utf8NoBOM -Value "`n$source"
        }

        function New-AzureResourceHelper {
            param([string] $Root)

            New-TelemetryModule -Root $Root -Child
            Set-Content -LiteralPath (Join-Path $Root 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Azure helper",
  "moduleDescription": "Deploys a resource without child telemetry.",
  "canonicalType": "helper"
}
'@
            Set-Content -LiteralPath (Join-Path $Root 'main.tf') -Encoding utf8NoBOM -Value @'
resource "azapi_resource" "example" {
  type                   = "Microsoft.Resources/resourceGroups@2024-03-01"
  name                   = "rg-location-test"
  parent_id              = "/subscriptions/00000000-0000-0000-0000-000000000000"
  location               = var.location
  body                   = {}
  response_export_values = []
}
'@
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
        $telemetry | Should -Match '(?m)^\s*main_location\s*=\s*var\.location'
        $telemetry | Should -Not -Match 'var\.telemetry_location'
        $providers | Should -Not -Match '(?m)^\s*(modtm|random)\s*='
        $providers | Should -Match '(?m)^\s*azapi\s*='
        (Get-Content -LiteralPath (Join-Path $root 'outputs.tf') -Raw) |
            Should -Match 'length\(azapi_resource\.telemetry\)'
        $variables | Should -Match 'variable "location"'
        $variables | Should -Not -Match 'variable "telemetry_location"'
        @([regex]::Matches($telemetry, '(?m)^removed \{')) | Should -HaveCount 2

        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw | Should -BeExactly $telemetry
        Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw | Should -BeExactly $providers
        Get-Content -LiteralPath (Join-Path $root 'variables.tf') -Raw | Should -BeExactly $variables
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'retires older resource-group telemetry without destroying state: <Case>' -ForEach @(
        @{ Case = 'older transport only'; WithModtm = $false; OtherRandom = $false; Tags = 'null' }
        @{ Case = 'both legacy transports'; WithModtm = $true; OtherRandom = $false; Tags = 'null' }
        @{ Case = 'authored tags and other random use'; WithModtm = $true; OtherRandom = $true; Tags = '{ module = "avm-res-kusto-cluster" }' }
    ) {
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
resource "random_id" "naming" {
  byte_length = 8
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
            Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw |
                Should -Match '(?s)resource "random_id" "naming" \{\s*byte_length\s*=\s*8'
        }
        else {
            $providers | Should -Not -Match '(?m)^\s*random\s*='
        }

        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw | Should -BeExactly $telemetry
        Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw | Should -BeExactly $providers
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'preserves nonstandard resource-group deployments and random helpers: <Case>' -ForEach @(
        @{ Case = 'custom deployment name'; Attribute = 'name'; Expression = '"business-deployment"'; RemoveDeployment = $false }
        @{ Case = 'custom template'; Attribute = 'template_content'; Expression = '"{}"'; RemoveDeployment = $false }
        @{ Case = 'different deployment gate'; Attribute = 'count'; Expression = '1'; RemoveDeployment = $false }
        @{ Case = 'different deployment mode'; Attribute = 'deployment_mode'; Expression = '"Complete"'; RemoveDeployment = $false }
        @{ Case = 'different helper length'; Attribute = 'byte_length'; Expression = '8'; RemoveDeployment = $true }
        @{ Case = 'different helper gate'; Attribute = 'helper_count'; Expression = '1'; RemoveDeployment = $true }
    ) {
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

    It 'retains a legacy random helper still needed by authored <SourceKind>' -ForEach @(
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
    ) {
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

    It 'retires dangling AzAPI telemetry headers: <Case>' -ForEach @(
        @{
            Case = 'all operation headers'
            IfMatch = $false
            Headers = @'
  create_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  read_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  update_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : {}
  delete_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
'@
        }
        @{
            Case = 'multiline equals syntax'
            IfMatch = $false
            Headers = @'
  create_headers = var.enable_telemetry ? {
    "User-Agent" = local.avm_azapi_header,
  } : {}
'@
        }
        @{
            Case = 'mandatory deletion precondition'
            IfMatch = $true
            Headers = @'
  # Preserve the service deletion precondition.
  delete_headers = merge({ "If-Match" = "*" }, var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : {})
'@
        }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @"
resource "azapi_resource" "business" {
  type = "Microsoft.Resources/resourceGroups@2024-03-01"
  name = "business"
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
  location = var.location
  body = {}
$Headers
}

resource "azapi_resource" "custom" {
  type = "Microsoft.Resources/resourceGroups@2024-03-01"
  name = "custom"
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
  location = var.location
  body = {}
  create_headers = { "X-Business" = "keep" }
  delete_headers = { "User-Agent" = "authored-client" }
}
"@
        Invoke-TelemetryProfiles -Root $root

        $main = Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw
        $main | Should -Not -Match 'avm_azapi_header'
        $main | Should -Match '"X-Business"\s*=\s*"keep"'
        $main | Should -Match '"User-Agent"\s*=\s*"authored-client"'
        if ($IfMatch) {
            $main | Should -Match 'delete_headers\s*=\s*\{\s*"If-Match"\s*=\s*"\*"'
            $main | Should -Match '# Preserve the service deletion precondition\.'
        }
        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw | Should -BeExactly $main

        if ($IfMatch) {
            $tests = Join-Path $root 'tests'
            $null = New-Item -ItemType Directory -Path $tests -Force
            Set-Content -LiteralPath (Join-Path $tests 'headers.tftest.hcl') -Encoding utf8NoBOM -Value @'
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

run "telemetry_enabled" {
  command = plan
  variables {
    enable_telemetry = true
  }
  assert {
    condition = azapi_resource.business.delete_headers == tomap({ "If-Match" = "*" }) && length(azapi_resource.telemetry) == 1
    error_message = "Keep the deletion precondition without the retired User-Agent while deployment telemetry is enabled."
  }
}

run "telemetry_disabled" {
  command = plan
  variables {
    enable_telemetry = false
  }
  assert {
    condition = azapi_resource.business.delete_headers == tomap({ "If-Match" = "*" }) && length(azapi_resource.telemetry) == 0
    error_message = "Keep the deletion precondition when telemetry is disabled."
  }
}
'@
        }
        Assert-TelemetryTerraformValid -Root $root
        if ($IfMatch) {
            $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
                -ArgumentList @('test', '-json', '-no-color') -Root $root
            $events = @($result.StdOut -split '\r?\n' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            $summary = @($events | Where-Object type -EQ 'test_summary')
            $summary | Should -HaveCount 1
            $summary[0].test_summary.passed | Should -Be 2
            $summary[0].test_summary.failed | Should -Be 0
            $summary[0].test_summary.skipped | Should -Be 0
        }
    }

    It 'preserves ambiguous AzAPI telemetry headers: <Case>' -ForEach @(
        @{ Case = 'declared header local'; Header = 'var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null'; Declaration = 'locals { avm_azapi_header = "authored-client" }'; Json = $false }
        @{ Case = 'JSON configuration'; Header = 'var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null'; Declaration = ''; Json = $true }
        @{ Case = 'authored header input'; Header = 'var.enable_telemetry ? { "User-Agent" : var.avm_azapi_header } : null'; Declaration = ''; Json = $false }
        @{ Case = 'different gate'; Header = 'var.enable_business_headers ? { "User-Agent" : local.avm_azapi_header } : null'; Declaration = ''; Json = $false }
        @{ Case = 'mixed header fields'; Header = 'var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header, "X-Business" = "keep" } : null'; Declaration = ''; Json = $false }
        @{ Case = 'authored deletion condition'; Header = 'merge({ "If-Match" = var.etag }, var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : {})'; Declaration = ''; Json = $false }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @"
$Declaration
resource "azapi_resource" "business" {
  type = "Microsoft.Resources/resourceGroups@2024-03-01"
  name = "business"
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
  location = var.location
  body = {}
  delete_headers = $Header
}
"@
        if ($Json) {
            Set-Content -LiteralPath (Join-Path $root 'headers.tf.json') -Encoding utf8NoBOM -Value `
                '{"locals":{"avm_azapi_header":"authored-json-client"}}'
        }
        $null = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('fmt', '-no-color', $root) -Root $root
        $headerPattern = '(?m)^\s*delete_headers\s*=\s*(.+)$'
        $before = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw), $headerPattern)
        $before.Success | Should -BeTrue
        Invoke-TelemetryProfiles -Root $root
        $main = Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw
        $after = @([regex]::Matches($main, $headerPattern))
        $after | Should -HaveCount 1
        $after[0].Groups[1].Value | Should -BeExactly $before.Groups[1].Value
        if ($Declaration) {
            $main | Should -Match ([regex]::Escape($Declaration))
        }
        if ($Json) {
            (Get-Content -LiteralPath (Join-Path $root 'headers.tf.json') -Raw).Trim() |
                Should -BeExactly '{"locals":{"avm_azapi_header":"authored-json-client"}}'
        }
        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw | Should -BeExactly $main
    }

    It 'retires unused legacy AzAPI header helpers: <Case>' -ForEach @(
        @{ Case = 'separate local blocks'; SplitBlocks = $true; AlreadyRetired = $false; NoResources = $false }
        @{ Case = 'shared block with an authored value'; SplitBlocks = $false; AlreadyRetired = $false; NoResources = $false }
        @{ Case = 'previously retired telemetry providers'; SplitBlocks = $false; AlreadyRetired = $true; NoResources = $false }
        @{ Case = 'helpers without remaining resources'; SplitBlocks = $false; AlreadyRetired = $true; NoResources = $true }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation -WithLegacy
        if ($AlreadyRetired) {
            Invoke-TelemetryProfiles -Root $root
        }
        if ($NoResources) {
            Set-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Encoding utf8NoBOM -Value ''
        }
        Add-LegacyAzapiHeaderHelpers -Root $root -SplitBlocks:$SplitBlocks
        Invoke-TelemetryProfiles -Root $root

        $telemetry = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        $telemetry | Should -Not -Match '(?m)^\s*(avm_azapi_headers?|fork_avm|valid_module_source_regex)\s*='
        $telemetry | Should -Match 'customer_value\s*=\s*"keep"'
        $telemetry | Should -Match 'main_location\s*=\s*var\.location'
        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw | Should -BeExactly $telemetry
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'preserves authored or referenced legacy AzAPI header helpers: <Case>' -ForEach @(
        @{ Case = 'custom header'; HeaderExpression = '"authored-client"'; Source = ''; Kind = 'source' }
        @{
            Case = 'resource header'
            HeaderExpression = ''
            Kind = 'source'
            Source = @'
resource "azapi_resource" "business" {
  type = "Microsoft.Resources/resourceGroups@2024-03-01"
  name = "business"
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
  location = var.location
  create_headers = var.enable_telemetry ? { "User-Agent" = local.avm_azapi_header } : null
}
'@
        }
        @{
            Case = 'output reference'
            HeaderExpression = ''
            Kind = 'source'
            Source = @'
output "legacy_header" {
  value = local.avm_azapi_header
}
'@
        }
        @{ Case = 'identical alias expression'; HeaderExpression = ''; Kind = 'source'; Source = 'locals { authored_alias = join(" ", [for k, v in local.avm_azapi_headers : "${k}=${v}"]) }' }
        @{ Case = 'duplicate declaration'; HeaderExpression = ''; Kind = 'early_source'; Source = 'locals { avm_azapi_header = "authored-client" }' }
        @{
            Case = 'commented traversal'
            HeaderExpression = ''
            Kind = 'source'
            Source = @'
output "legacy_fork" {
  value = local /* preserve */ . fork_avm
}
'@
        }
        @{
            Case = 'Terraform test assertion'
            HeaderExpression = ''
            Kind = 'test'
            Source = @'
run "authored_assertion" {
  command = plan
  assert {
    condition = local.fork_avm
    error_message = "Retain the authored fork assertion."
  }
}
'@
        }
        @{
            Case = 'root Terraform test assertion'
            HeaderExpression = ''
            Kind = 'root_test'
            Source = @'
run "authored_assertion" {
  command = plan
  assert {
    condition = local.fork_avm
    error_message = "Retain the authored fork assertion."
  }
}
'@
        }
        @{
            Case = 'JSON Terraform test assertion'
            HeaderExpression = ''
            Kind = 'json_test'
            Source = '{"run":{"authored_assertion":{"command":"plan","assert":[{"condition":"${local.fork_avm}","error_message":"Retain the authored fork assertion."}]}}}'
        }
        @{
            Case = 'root JSON Terraform test assertion'
            HeaderExpression = ''
            Kind = 'root_json_test'
            Source = '{"run":{"authored_assertion":{"command":"plan","assert":[{"condition":"${local.fork_avm}","error_message":"Retain the authored fork assertion."}]}}}'
        }
        @{ Case = 'JSON configuration'; HeaderExpression = ''; Kind = 'json'; Source = '{"locals":{"authored_alias":"${local.avm_azapi_header}"}}' }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation -WithLegacy
        Add-LegacyAzapiHeaderHelpers -Root $root -HeaderExpression $HeaderExpression
        if ($Source) {
            $file = switch ($Kind) {
                'test' { Join-Path $root 'tests' 'unit' 'header.tftest.hcl' }
                'root_test' { Join-Path $root 'header.tftest.hcl' }
                'json_test' { Join-Path $root 'tests' 'unit' 'header.tftest.json' }
                'root_json_test' { Join-Path $root 'header.tftest.json' }
                'json' { Join-Path $root 'headers.tf.json' }
                'early_source' { Join-Path $root 'authored.tf' }
                default { Join-Path $root 'outputs.tf' }
            }
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force
            Set-Content -LiteralPath $file -Encoding utf8NoBOM -Value $Source
        }
        Invoke-TelemetryProfiles -Root $root
        $telemetry = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        foreach ($name in @('avm_azapi_header', 'avm_azapi_headers', 'fork_avm', 'valid_module_source_regex')) {
            $telemetry | Should -Match "(?m)^\s*$name\s*="
        }
        $telemetry | Should -Match 'customer_value\s*=\s*"keep"'
        if ($HeaderExpression) {
            $telemetry | Should -Match ([regex]::Escape($HeaderExpression))
        }
    }

    It 'preserves commented-out AzAPI telemetry headers' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root -WithLocation -WithLegacy
        $comment = @'
/*
resource "azapi_resource" "old_connection" {
  create_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  delete_headers = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
}
*/
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @"
$comment
resource "terraform_data" "business" {
  input = "keep"
}
"@
        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw |
            Should -Match ([regex]::Escape($comment))
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'creates a required location input for a module without one' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Invoke-TelemetryProfiles -Root $root

        $telemetry = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        $variables = Get-Content -LiteralPath (Join-Path $root 'variables.tf') -Raw
        $providers = Get-Content -LiteralPath (Join-Path $root 'terraform.tf') -Raw
        $telemetry | Should -Match '(?m)^\s*main_location\s*=\s*var\.location'
        $telemetry | Should -Not -Match '(?m)^removed \{'
        $locationBlock = [regex]::Match($variables, '(?s)variable "location" \{(?<body>[^}]*)\}')
        $locationBlock.Success | Should -BeTrue
        $locationBlock.Groups['body'].Value | Should -Match 'type\s*=\s*string'
        $locationBlock.Groups['body'].Value | Should -Match 'nullable\s*=\s*false'
        $locationBlock.Groups['body'].Value | Should -Not -Match 'default\s*='
        $variables | Should -Not -Match 'variable "telemetry_location"'
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
        $rootMain | Should -Match '(?m)^\s*location\s*=\s*var\.location'
        $rootMain | Should -Not -Match 'telemetry_location'
        $rootMain | Should -Not -Match '(?s)module "helper" \{[^}]*enable_telemetry'
        (Join-Path $root 'main.telemetry.tf') | Should -Exist
        (Join-Path $child 'main.telemetry.tf') | Should -Exist
        (Join-Path $helper 'main.telemetry.tf') | Should -Not -Exist
        $childVariables = Get-Content -LiteralPath (Join-Path $child 'variables.tf') -Raw
        $childVariables | Should -Match '(?s)variable "location" \{[^}]*nullable\s*=\s*false'
        $childVariables | Should -Not -Match 'variable "telemetry_location"'
        (Join-Path $helper 'variables.tf') | Should -Not -Exist
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

    It 'adds and forwards location for a child with Azure resources but no telemetry prefix' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $child = Join-Path $root 'modules' 'azure-helper'
        New-TelemetryModule -Root $root -WithLocation
        New-AzureResourceHelper -Root $child
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "azure_helper" {
  source = "./modules/azure-helper"
}
'@

        (Invoke-TelemetryEngine -Root $root).Status | Should -Be 'pass'
        $childVariables = Get-Content -LiteralPath (Join-Path $child 'variables.tf') -Raw
        $childVariables | Should -Match '(?s)variable "location" \{[^}]*nullable\s*=\s*false'
        $childVariables | Should -Not -Match 'variable "telemetry_location"'
        (Join-Path $child 'main.telemetry.tf') | Should -Not -Exist
        Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw |
            Should -Match '(?ms)^module "azure_helper" \{[^}]*location\s*=\s*var\.location'
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -Be 'pass'
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'sorts a generated child location among authored required inputs on the first pass' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $child = Join-Path $root 'modules' 'azure-helper'
        New-TelemetryModule -Root $root -WithLocation
        New-AzureResourceHelper -Root $child
        Set-Content -LiteralPath (Join-Path $child 'variables.tf') -Encoding utf8NoBOM -Value @'
variable "key_vault_resource_id" {
  type = string
}

variable "name" {
  type = string
}
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "azure_helper" {
  source                = "./modules/azure-helper"
  key_vault_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
  name                  = "example"
}
'@

        (Invoke-TelemetryEngine -Root $root).Status | Should -Be 'pass'
        $variables = Get-Content -LiteralPath (Join-Path $child 'variables.tf') -Raw
        @([regex]::Matches($variables, '(?m)^variable "([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value }) |
            Should -Be @('key_vault_resource_id', 'location', 'name')
        $drift = Invoke-TelemetryEngine -Root $root -CheckDrift
        $drift.Status | Should -Be 'pass'
        $drift.Changed | Should -BeNullOrEmpty
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'passes location from root through a nested Azure-resource helper' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $wrapper = Join-Path $root 'modules' 'group' 'wrapper'
        $leaf = Join-Path $root 'modules' 'group' 'azure-leaf'
        New-TelemetryModule -Root $root
        New-AzureResourceHelper -Root $leaf
        $null = New-Item -ItemType Directory -Path $wrapper -Force
        Set-Content -LiteralPath (Join-Path $wrapper 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Wrapper helper",
  "moduleDescription": "Forwards an Azure-resource child.",
  "canonicalType": "helper"
}
'@
        Set-Content -LiteralPath (Join-Path $wrapper 'main.tf') -Encoding utf8NoBOM -Value @'
module "azure_leaf" {
  source = "../azure-leaf"
}
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "wrapper" {
  source = "./modules/group/wrapper"
}
'@

        (Invoke-TelemetryEngine -Root $root).Status | Should -Be 'pass'
        foreach ($path in @($root, $wrapper, $leaf)) {
            Get-Content -LiteralPath (Join-Path $path 'variables.tf') -Raw |
                Should -Match '(?s)variable "location" \{[^}]*nullable\s*=\s*false'
        }
        Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw |
            Should -Match '(?ms)^module "wrapper" \{[^}]*location\s*=\s*var\.location'
        Get-Content -LiteralPath (Join-Path $wrapper 'main.tf') -Raw |
            Should -Match '(?ms)^module "azure_leaf" \{[^}]*location\s*=\s*var\.location'
        (Join-Path $wrapper 'main.telemetry.tf') | Should -Not -Exist
        (Join-Path $leaf 'main.telemetry.tf') | Should -Not -Exist
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -Be 'pass'
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'keeps a local child call with an authored per-item location' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $child = Join-Path $root 'modules' 'child'
        New-TelemetryModule -Root $root -WithLocation
        New-TelemetryModule -Root $child -Child
        Add-Content -LiteralPath (Join-Path $root 'variables.tf') -Encoding utf8NoBOM -Value @'
variable "hub_location" {
  type    = string
  default = "westus2"
}
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "child" {
  source   = "./modules/child"
  location = var.hub_location
}
'@

        (Invoke-TelemetryEngine -Root $root).Status | Should -Be 'pass'
        $call = Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw
        $call | Should -Match '(?m)^\s*location\s*=\s*var\.hub_location'
        $call | Should -Match '(?m)^\s*enable_telemetry\s*=\s*var\.enable_telemetry'
        $call | Should -Not -Match 'telemetry_location'
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -Be 'pass'
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'leaves a utility root without Azure resources free of location inputs' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $root
        Set-Content -LiteralPath (Join-Path $root 'metadata.json') -Encoding utf8NoBOM -Value @'
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Utility",
  "moduleDescription": "Does not deploy Azure resources.",
  "canonicalType": "naming",
  "owners": []
}
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
output "name" {
  value = "utility"
}
'@

        (Invoke-TelemetryEngine -Root $root).Status | Should -Be 'pass'
        (Join-Path $root 'main.telemetry.tf') | Should -Not -Exist
        (Join-Path $root 'variables.tf') | Should -Not -Exist
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -Be 'pass'
        Assert-TelemetryTerraformValid -Root $root
    }

    It 'allows a disabled parent and child when a location is supplied' {
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
            -ArgumentList @('plan', '-input=false', '-no-color', '-var=enable_telemetry=false', '-var=location=eastus') -Root $root
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
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  location = "eastus"
}

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
        $testContent | Should -Not -Match 'mock_provider "random"'
        [regex]::Matches($testContent, 'mock_provider "azapi"').Count | Should -Be 1
        $testContent | Should -Match 'can\(azapi_resource\.telemetry\[0\]\)'
        $providerContent = Get-Content -LiteralPath (Join-Path $wrapper 'terraform.tf') -Raw
        $providerContent | Should -Not -Match '(?m)^\s*modtm\s*='
        $providerContent | Should -Match '(?m)^\s*azapi\s*='

        $drift = Invoke-TelemetryEngine -Root $root -CheckDrift
        $drift.Status | Should -Be 'pass'
        $drift.Changed | Should -BeNullOrEmpty
        Get-Content -LiteralPath $testPath -Raw | Should -BeExactly $testContent
        Assert-TelemetryTerraformValid -Root $root
        $unitResult = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', ('-test-directory=' + [System.IO.Path]::Combine('tests', 'unit')), '-no-color') -Root $root
        $unitResult.StdOut | Should -Match 'Success! 1 passed, 0 failed'
    }

    It 'runs root and child telemetry assertions with <Shape> customized client mocks' -TestCases @(
        @{ Shape = 'missing'; SubscriptionId = '00000000-0000-0000-0000-000000000000' }
        @{ Shape = 'partial'; SubscriptionId = '11111111-1111-1111-1111-111111111111' }
    ) {
        param($Shape, $SubscriptionId)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $child = Join-Path $root 'modules' 'child'
        New-TelemetryModule -Root $root -WithLegacy
        New-TelemetryModule -Root $child -WithLegacy -Child
        foreach ($target in @($root, $child)) {
            Set-Content -LiteralPath (Join-Path $target 'main.tf') -Encoding utf8NoBOM -Value @'
data "azapi_resource_list" "authored" {
  type      = "Microsoft.Resources/resourceGroups@2025-04-01"
  parent_id = "/subscriptions/11111111-1111-1111-1111-111111111111"
}
'@
        }
        $unit = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $unit -Force
        $testPath = Join-Path $unit 'custom.tftest.hcl'
        $client = if ($Shape -eq 'partial') {
            @'
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id = "11111111-1111-1111-1111-111111111111"
      object_id       = "22222222-2222-2222-2222-222222222222"
    }
  }
'@
        }
        else { '' }
        $assertion = if ($Shape -eq 'partial') {
            @'
  assert {
    condition = (
      data.azapi_client_config.telemetry[0].subscription_id == "11111111-1111-1111-1111-111111111111" &&
      data.azapi_client_config.telemetry[0].object_id == "22222222-2222-2222-2222-222222222222"
    )
    error_message = "Keep the authored client identity defaults."
  }
'@
        }
        else { '' }
        $source = @'
mock_provider "modtm" {}
mock_provider "random" {}
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = { output = { value = [] } }
  }
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Resources/deployments/authored"
    }
  }
__CLIENT__
}

variables {
  location = "westeurope"
}

run "root_on" {
  command = apply
  assert {
    condition = (
      length(modtm_telemetry.telemetry) == 1 &&
      azapi_resource.telemetry[0].parent_id == "/subscriptions/__SUBSCRIPTION__" &&
      azapi_resource.telemetry[0].location == "westeurope" &&
      length(data.azapi_resource_list.authored.output.value) == 0
    )
    error_message = "Telemetry must work without changing the location or unrelated mock."
  }
__ASSERTION__
}

run "root_off" {
  command = plan
  variables {
    enable_telemetry = false
  }
  assert {
    condition     = length(modtm_telemetry.telemetry) == 0
    error_message = "Keep the authored telemetry opt-out assertion."
  }
}

run "child_on" {
  command = apply
  module {
    source = "./modules/child"
  }
  variables {
    location = "swedencentral"
  }
  assert {
    condition = (
      length(modtm_telemetry.telemetry) == 1 &&
      azapi_resource.telemetry[0].parent_id == "/subscriptions/__SUBSCRIPTION__" &&
      azapi_resource.telemetry[0].location == "swedencentral" &&
      length(data.azapi_resource_list.authored.output.value) == 0
    )
    error_message = "Keep the local child target and its authored region."
  }
__ASSERTION__
}
'@
        $source = $source.Replace('__CLIENT__', $client).Replace('__ASSERTION__', $assertion).
            Replace('__SUBSCRIPTION__', $SubscriptionId)
        [System.IO.File]::WriteAllText($testPath, $source + "`n", [System.Text.UTF8Encoding]::new($false))
        $snapshot = InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Get-AvmFileSnapshot -Path @((Get-AvmTerraformFile -Root $Root).FullName)
        }
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -Be 'fail'
        foreach ($path in $snapshot.Keys) {
            [System.IO.File]::ReadAllBytes($path) | Should -Be $snapshot[$path]
        }
        (Invoke-TelemetryEngine -Root $root).Status | Should -Be 'pass'
        $first = [System.IO.File]::ReadAllText($testPath)
        $first | Should -Not -Match 'mock_provider "(modtm|random)"'
        $first | Should -Match 'source\s*=\s*"\./modules/child"'
        $first | Should -Match 'enable_telemetry\s*=\s*false'
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -Be 'pass'
        [System.IO.File]::ReadAllText($testPath) | Should -BeExactly $first
        Assert-TelemetryTerraformValid -Root $root -TestDirectory 'tests/unit'
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', '-no-color', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match 'Success! 3 passed, 0 failed'
    }

    It 'preserves root and local-child unit targets with <MockShape> AzAPI mocks' -TestCases @(
        @{ MockShape = 'empty'; MockBody = '' }
        @{ MockShape = 'comment-only'; MockBody = "`n  # Keep the authored provider explanation.`n" }
    ) {
        param($MockBody)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $child = Join-Path $root 'modules' 'child'
        New-TelemetryModule -Root $root -WithLegacy
        New-TelemetryModule -Root $child -WithLegacy -Child
        foreach ($target in @($root, $child)) {
            Add-Content -LiteralPath (Join-Path $target 'variables.tf') -Encoding utf8NoBOM -Value @'
variable "hub_regions" {
  type = map(string)
}
'@
            Set-Content -LiteralPath (Join-Path $target 'main.tf') -Encoding utf8NoBOM -Value @'
locals {
  primary_region = var.hub_regions.primary
}
'@
        }
        $unit = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $unit -Force
        $testPath = Join-Path $unit 'scopes.tftest.hcl'
        $source = @'
mock_provider "azapi" {__AZAPI_MOCK_BODY__}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  enable_telemetry = false
  hub_regions = {
    primary   = "westeurope"
    secondary = "swedencentral"
  }
}

run "root" {
  command = plan

  assert {
    condition     = local.primary_region == "westeurope" && var.hub_regions.secondary == "swedencentral"
    error_message = "Authored hub regions must be preserved."
  }
  assert {
    condition     = length(azapi_resource.telemetry) == 0 && var.location == "eastus"
    error_message = "Supply only the new test input and preserve the telemetry opt-out."
  }
}

run "child" {
  command = plan

  module {
    source = "./modules/child"
  }

  assert {
    condition     = local.primary_region == "westeurope" && var.hub_regions.secondary == "swedencentral"
    error_message = "The delegated module must retain the authored hub regions."
  }
  assert {
    condition     = length(azapi_resource.telemetry) == 0 && var.location == "eastus"
    error_message = "The delegated module must receive only the new input."
  }
}
'@
        [System.IO.File]::WriteAllText(
            $testPath, $source.Replace('__AZAPI_MOCK_BODY__', $MockBody) + "`n",
            [System.Text.UTF8Encoding]::new($false))

        $before = InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Get-AvmFileSnapshot -Path @((Get-AvmTerraformFile -Root $Root).FullName)
        }
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -Be 'fail'
        foreach ($path in $before.Keys) {
            [System.IO.File]::ReadAllBytes($path) | Should -Be $before[$path]
        }
        @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
        (Invoke-TelemetryEngine -Root $root).Status | Should -Be 'pass'
        $content = [System.IO.File]::ReadAllText($testPath)
        $content | Should -Match 'source\s*=\s*"\./modules/child"'
        $content | Should -Match 'mock_provider "azapi"'
        $content | Should -Not -Match 'mock_provider "(modtm|random)"'
        $content | Should -Match 'subscription_resource_id\s*=\s*"/subscriptions/00000000-0000-0000-0000-000000000000"'
        if ($MockBody) {
            $content | Should -Match '# Keep the authored provider explanation\.'
        }
        (Invoke-TelemetryEngine -Root $root -CheckDrift).Status | Should -Be 'pass'
        [System.IO.File]::ReadAllText($testPath) | Should -BeExactly $content
        Assert-TelemetryTerraformValid -Root $root -TestDirectory 'tests/unit'
        $result = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('test', ('-test-directory=' + [System.IO.Path]::Combine('tests', 'unit')), '-no-color') -Root $root
        $result.StdOut | Should -Match 'Success! 2 passed, 0 failed'
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
            -ArgumentList @('test', '-no-color', '-verbose', '-var=location=eastus', '-test-directory=tests/unit') -Root $root
        $result.StdOut | Should -Match 'Success! 2 passed, 0 failed\.'
        $result.StdOut | Should -Match 'azapi_resource\.telemetry\[0\] will be updated in-place'
    }

    It 'preserves existing delegated fixture tests during transformation for <Fixture>' -TestCases @(
        @{ Fixture = 'terraform-azure-avm-res-mock' }
        @{ Fixture = 'terraform-azurerm-avm-res-mock' }
    ) {
        param($Fixture)

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $source = Join-Path $script:repoRoot 'tests' 'fixtures' 'modules' $Fixture
        Copy-Item -LiteralPath $source -Destination $root -Recurse -Force
        $tests = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.tftest.hcl')
        $hashes = @{}
        foreach ($file in $tests) {
            $hashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash
        }
        $result = Invoke-TelemetryEngine -Root $root -CheckDrift
        $result.Status | Should -BeExactly 'pass'
        @($result.Changed).Count | Should -Be 0
        foreach ($file in $tests) {
            (Get-FileHash -LiteralPath $file.FullName).Hash | Should -BeExactly $hashes[$file.FullName]
        }
        @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.mptfbackup') | Should -HaveCount 0
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

    It 'migrates a module with no random provider after forgetting legacy state without destruction' {
        $source = Join-Path $script:repoRoot 'tests' 'fixtures' 'telemetry' 'terraform-no-random'
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $source -Destination $root -Recurse -Force
        $providerPath = Join-Path $root 'terraform.tf'
        $fixtureProviders = Get-Content -LiteralPath $providerPath -Raw
        $fixtureProviders | Should -Match '(?m)^\s*azapi\s*='
        $fixtureProviders | Should -Not -Match '(?m)^\s*(modtm|random)\s*='

        $legacyRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-TelemetryModule -Root $legacyRoot -WithLegacy
        foreach ($name in @('terraform.tf', 'main.telemetry.tf', 'outputs.tf')) {
            Copy-Item -LiteralPath (Join-Path $legacyRoot $name) -Destination (Join-Path $root $name)
        }
        Get-Content -LiteralPath $providerPath -Raw | Should -Match '(?m)^\s*random\s*='
        Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw |
            Should -Match 'resource "random_uuid" "telemetry"'

        Invoke-TelemetryProfiles -Root $root
        $providers = Get-Content -LiteralPath $providerPath -Raw
        $providers | Should -Match '(?m)^\s*azapi\s*='
        $providers | Should -Not -Match '(?m)^\s*(modtm|random)\s*='
        $telemetry = Get-Content -LiteralPath (Join-Path $root 'main.telemetry.tf') -Raw
        $telemetry | Should -Match 'resource "terraform_data" "telemetry"'
        $telemetry | Should -Match 'resource "azapi_resource" "telemetry"'
        $telemetry | Should -Match '(?s)removed \{\s*from\s*=\s*random_uuid\.telemetry\s*lifecycle \{\s*destroy\s*=\s*false'
        $telemetry | Should -Match '(?s)removed \{\s*from\s*=\s*modtm_telemetry\.telemetry\s*lifecycle \{\s*destroy\s*=\s*false'
        $telemetry | Should -Not -Match '(?m)^\s*tags\s*='
        Invoke-TelemetryProfiles -Root $root
        Get-Content -LiteralPath $providerPath -Raw | Should -BeExactly $providers
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
        $legacyInit.StdOut | Should -Match 'hashicorp/random'
        $plan = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('plan', '-refresh=false', '-input=false', '-lock=false', '-no-color', '-var=enable_telemetry=false', '-var=location=eastus') -Root $root
        $plan.StdOut | Should -Match 'modtm_telemetry\.telemetry\[0\] will no longer be managed'
        $plan.StdOut | Should -Match 'random_uuid\.telemetry\[0\] will no longer be managed'
        $apply = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('apply', '-refresh=false', '-input=false', '-auto-approve', '-no-color', '-var=enable_telemetry=false', '-var=location=eastus') -Root $root
        $apply.StdOut | Should -Match 'Apply complete! Resources: 0 added, 0 changed, 0 destroyed\.'
        $remaining = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('state', 'list') -Root $root
        $remaining.StdOut | Should -BeNullOrEmpty
        $cleanInit = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('init', '-backend=false', '-input=false', '-upgrade', '-no-color') -Root $root
        $cleanInit.StdOut | Should -Not -Match 'Finding Azure/modtm versions'
        $cleanInit.StdOut | Should -Not -Match 'Finding hashicorp/random versions'
        $currentProviders = Invoke-TelemetryProcess -FilePath $script:terraformPath `
            -ArgumentList @('providers', '-no-color') -Root $root
        $currentProviders.StdOut | Should -Not -Match 'Azure/modtm|hashicorp/random'
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
