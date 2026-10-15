#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: MAPOTF provider schema selection' -Tag 'Integration' -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $moduleRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
        $script:profilesRoot = Join-Path $moduleRoot 'Resources' 'mapotf'
        $script:originalAvmHome = $env:AVM_HOME
        $script:originalMapotfConfig = $env:AVM_MPTF_CONFIG_DIR
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:mapotfTool = InModuleScope Avm.Authoring {
            if ($env:AVM_MAPOTF_TEST_BINARY) {
                [pscustomobject]@{
                    Name = 'mapotf'
                    Version = 'development'
                    Source = 'AVM_MAPOTF_TEST_BINARY'
                    Path = (Get-Item -LiteralPath $env:AVM_MAPOTF_TEST_BINARY -ErrorAction Stop).FullName
                }
            }
            else {
                Resolve-AvmTool -Name mapotf
            }
        }
        $env:AVM_MPTF_CONFIG_DIR = $null
        $script:emptyPath = Join-Path $TestDrive 'empty-path'
        $null = New-Item -ItemType Directory -Path $script:emptyPath
        $script:requests = @{
            azurerm = @{ Source = 'registry.terraform.io/hashicorp/azurerm'; Version = '~> 4.0' }
            azapi = @{ Source = 'registry.terraform.io/azure/azapi'; Version = '~> 2.12' }
            random = @{ Source = 'registry.terraform.io/hashicorp/random'; Version = '~> 3.0' }
        }
        $script:unusedSchema = 'An unused provider schema must not be read.'
        $script:selectionExpression = @'
{
  for name in ["azurerm", "azapi", "random"] : name => {
    instances    = try(keys(data.provider_schema[name]), [])
    resources    = try(keys(data.provider_schema[name]["used"].resources), [])
    data_sources = try(keys(data.provider_schema[name]["used"].data_sources), [])
  }
}
'@

        function Get-SchemaCachePath {
            param([string] $Provider)

            $request = $script:requests[$Provider]
            $key = [System.Text.Encoding]::UTF8.GetBytes("$($request.Source)`0$($request.Version)")
            $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($key)).ToLowerInvariant()
            Join-Path $script:cacheRoot "$hash.json"
        }

        function Set-CachedSchema {
            param([string] $Provider)

            $attributes = @{
                a_required = @{ type = 'string'; required = $true }
                z_required = @{ type = 'string'; required = $true }
            }
            foreach ($name in @('a_optional', 'z_optional', 'action', 'location', 'method', 'name', 'parent_id', 'query_parameters', 'resource_id')) {
                $attributes[$name] = @{ type = 'string'; optional = $true }
            }
            $block = @{ version = 0; block = @{ attributes = $attributes } }
            $schema = @{
                resource_schemas = @{ "${Provider}_widget" = $block }
                data_source_schemas = @{ "${Provider}_lookup" = $block }
            }
            if ($Provider -eq 'azapi') {
                $schema.resource_schemas.azapi_resource = @{
                    version = 0
                    block = @{
                        attributes = @{
                            type = @{ type = 'string'; required = $true }
                            parent_id = @{ type = 'string'; required = $true }
                            name = @{ type = 'string'; optional = $true }
                            location = @{ type = 'string'; optional = $true }
                            body = @{ type = 'dynamic'; optional = $true }
                            response_export_values = @{ type = @('list', 'string'); optional = $true }
                        }
                    }
                }
                $schema.data_source_schemas.azapi_client_config = @{ version = 0; block = @{ attributes = @{} } }
            }
            $request = $script:requests[$Provider]
            $entry = @{
                format_version = 1
                provider_source = $request.Source
                version_constraint = $request.Version
                cached_at = [DateTime]::UtcNow.ToString('o')
                schema = $schema
            }
            [System.IO.File]::WriteAllText((Get-SchemaCachePath -Provider $Provider),
                ($entry | ConvertTo-Json -Depth 20 -Compress))
        }

        function Invoke-SchemaProcess {
            param([string[]] $ArgumentList, [switch] $IgnoreExitCode)

            InModuleScope Avm.Authoring -Parameters @{
                ToolPath = $script:mapotfTool.Path
                Arguments = $ArgumentList
                Root = $script:target
                Environment = $script:processEnvironment
                IgnoreExitCode = [bool]$IgnoreExitCode
            } {
                param($ToolPath, $Arguments, $Root, $Environment, $IgnoreExitCode)
                Invoke-AvmProcess -FilePath $ToolPath -ArgumentList $Arguments `
                    -WorkingDirectory $Root -EnvVars $Environment -IgnoreExitCode:$IgnoreExitCode
            }
        }

        function Invoke-SchemaTransform {
            $null = Invoke-SchemaProcess -ArgumentList @(
                'transform', '--tf-dir', $script:target, '--mptf-dir', (Join-Path $script:profilesRoot 'common')
            )
            $null = Invoke-SchemaProcess -ArgumentList @('clean-backup', '--tf-dir', $script:target)
        }

        function Assert-SelectedSchema {
            param([string[]] $Providers = @())

            $result = Invoke-SchemaProcess -ArgumentList @(
                'debug', '--tf-dir', $script:target, '--mptf-dir', (Join-Path $script:profilesRoot 'common'),
                '--eval', $script:selectionExpression
            )
            $selection = $result.StdOut | ConvertFrom-Json -AsHashtable
            foreach ($provider in $script:requests.Keys) {
                if ($provider -in $Providers) {
                    @($selection[$provider].instances) | Should -Be @('used')
                    @($selection[$provider].resources) | Should -Contain "${provider}_widget"
                    @($selection[$provider].data_sources) | Should -Contain "${provider}_lookup"
                }
                else {
                    @($selection[$provider].instances) | Should -HaveCount 0
                    @($selection[$provider].resources) | Should -HaveCount 0
                    @($selection[$provider].data_sources) | Should -HaveCount 0
                    [System.IO.File]::ReadAllText((Get-SchemaCachePath -Provider $provider)) |
                        Should -BeExactly $script:unusedSchema
                }
            }
        }

        function Set-OrderingFixture {
            param(
                [string] $Provider,
                [string] $BlockType = 'resource',
                [string] $Binding = 'default',
                [string] $Type
            )

            if (-not $Type) {
                $Type = if ($BlockType -eq 'data') { "${Provider}_lookup" } else { "${Provider}_widget" }
            }
            $localName = if ($Binding -eq 'custom') { 'custom' } else { $Provider }
            $providerReference = if ($Binding -eq 'default') { $localName } else { "$localName.secondary" }
            $iteration = if ($Binding -eq 'default') { 'count = 1' } else { 'for_each = {}' }
            $content = @"
$BlockType "$Type" "example" {
  z_optional = "z"
  z_unlisted = "z"
  parent_id = "parent"
  depends_on = []
  a_optional = "a"
  $iteration
  z_required = "z"
  name = "example"
  timeouts {
    create = "1m"
  }
  lifecycle {
    postcondition {
      condition = self.name != ""
      error_message = "A name is required."
    }
  }
  a_unlisted = "a"
  a_required = "a"
  location = "eastus"
  provider = $providerReference
  action = "read"
  method = "GET"
  resource_id = "resource"
  query_parameters = "query"
}
"@
            [System.IO.File]::WriteAllText((Join-Path $script:target 'main.tf'), $content.Replace("`r`n", "`n") + "`n")
            if ($Provider -in $script:requests.Keys) {
                $request = $script:requests[$Provider]
                $configuration = @"
terraform {
  required_providers {
    $localName = {
      source = "$($request.Source)"
      version = "$($request.Version)"
      configuration_aliases = [$localName.secondary]
    }
  }
}
"@
                [System.IO.File]::WriteAllText((Join-Path $script:target 'terraform.tf'), $configuration.Replace("`r`n", "`n") + "`n")
            }
        }

        function Get-OrderedElements {
            $content = [System.IO.File]::ReadAllText((Join-Path $script:target 'main.tf'))
            @([regex]::Matches($content, '(?m)^  ([a-z_]+)\s*(?:=|\{)') |
                ForEach-Object { $_.Groups[1].Value })
        }

        function Get-ScopeSnapshot {
            @(Get-ChildItem -LiteralPath $script:target -Filter '*.tf' -File | Sort-Object Name |
                ForEach-Object { '{0}:{1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n"
        }

        function Set-TelemetryFixture {
            [System.IO.File]::WriteAllText((Join-Path $script:target 'terraform.tf'), @'
terraform {
  required_version = ">= 1.9"
}
'@)
            [System.IO.File]::WriteAllText((Join-Path $script:target 'main.tf'), @'
locals {
  untouched = "preserved"
}
'@)
            [System.IO.File]::WriteAllText((Join-Path $script:target 'metadata.json'),
                '{"canonicalType":"Microsoft.Resources/resourceGroups","telemetryIdPrefix":"46d3xtrf.res.a1b2c3d"}')
        }

        function Invoke-SchemaEngine {
            param([switch] $CheckDrift)

            InModuleScope Avm.Authoring -Parameters @{
                Root = $script:target
                Tool = $script:mapotfTool
                Environment = $script:processEnvironment
                CheckDrift = [bool]$CheckDrift
            } {
                param($Root, $Tool, $Environment, $CheckDrift)
                Mock Resolve-AvmTool {
                    if ($Name -eq 'mapotf') { return $Tool }
                    if ($Name -eq 'terraform') {
                        return [pscustomobject]@{ Path = (Join-Path $Environment.PATH 'terraform'); Name = 'terraform' }
                    }
                    throw [System.InvalidOperationException]::new("Unexpected tool request: $Name")
                }
                Mock New-AvmToolPathEnvironment { $Environment.Clone() }
                Invoke-AvmTerraformTransform -Context ([pscustomobject]@{
                        Kind = 'terraform-module-repo'; Root = $Root; Ecosystem = 'terraform'
                    }) -CheckDrift:$CheckDrift
            }
        }
    }

    BeforeEach {
        $caseId = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:target = Join-Path $TestDrive "scope-$caseId"
        $env:AVM_HOME = Join-Path $TestDrive "avm-$caseId"
        $script:cacheRoot = Join-Path $env:AVM_HOME 'cache' 'mapotf-provider-schema'
        $null = New-Item -ItemType Directory -Path $script:target, $script:cacheRoot
        # Invalid unused entries prove they were not even decoded; an empty PATH forbids a Terraform fallback.
        foreach ($cacheProviderName in $script:requests.Keys) {
            [System.IO.File]::WriteAllText((Get-SchemaCachePath -Provider $cacheProviderName), $script:unusedSchema)
        }
        $script:processEnvironment = @{
            PATH = $script:emptyPath
            MAPOTF_PROVIDER_SCHEMA_CACHE = 'on'
            MAPOTF_PROVIDER_SCHEMA_CACHE_DIR = $script:cacheRoot
            MAPOTF_PROVIDER_SCHEMA_CACHE_TTL = '0'
            MAPOTF_MODULE_SOURCE_CACHE_DIR = Join-Path $env:AVM_HOME 'cache' 'mapotf-module-source'
            TF_PLUGIN_CACHE_DIR = $null
            TF_DATA_DIR = $null
        }
    }

    AfterAll {
        [Environment]::SetEnvironmentVariable('AVM_HOME',
            $(if ($null -eq $script:originalAvmHome) { [NullString]::Value } else { $script:originalAvmHome }), 'Process')
        [Environment]::SetEnvironmentVariable('AVM_MPTF_CONFIG_DIR',
            $(if ($null -eq $script:originalMapotfConfig) { [NullString]::Value } else { $script:originalMapotfConfig }), 'Process')
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'skips schemas for an empty module' {
        Invoke-SchemaTransform
        Assert-SelectedSchema
        @(Get-ChildItem -LiteralPath $script:target -Force) | Should -HaveCount 0
    }

    It 'does not materialize unused schemas even when all cache entries are valid' {
        foreach ($providerName in $script:requests.Keys) {
            Set-CachedSchema -Provider $providerName
        }
        Invoke-SchemaTransform
        $result = Invoke-SchemaProcess -ArgumentList @(
            'debug', '--tf-dir', $script:target, '--mptf-dir', (Join-Path $script:profilesRoot 'common'),
            '--eval', 'try(keys(data.provider_schema), [])'
        )
        @($result.StdOut | ConvertFrom-Json) | Should -HaveCount 0
    }

    It 'skips schemas for provider declarations without resources or data' {
        [System.IO.File]::WriteAllText((Join-Path $script:target 'terraform.tf'), @'
terraform {
  required_providers {
    custom = { source = "Azure/azapi", version = "~> 2.12" }
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}
provider "custom" {
  alias = "secondary"
}
'@)
        Invoke-SchemaTransform
        Assert-SelectedSchema
    }

    It 'skips schemas for resources in a called local module' {
        $child = Join-Path $script:target 'child'
        $null = New-Item -ItemType Directory -Path $child
        $childFile = Join-Path $child 'main.tf'
        $childContent = 'resource "azurerm_widget" "child" {}'
        [System.IO.File]::WriteAllText($childFile, $childContent)
        [System.IO.File]::WriteAllText((Join-Path $script:target 'main.tf'), @'
module "child" {
  source = "./child"
}
'@)
        Invoke-SchemaTransform
        Assert-SelectedSchema
        [System.IO.File]::ReadAllText($childFile) | Should -BeExactly $childContent
    }

    It 'keeps meta-only ordering without a schema for <BlockType> <Type>' -TestCases @(
        @{ BlockType = 'resource'; Type = 'custom_widget'; Provider = 'custom' }
        @{ BlockType = 'data'; Type = 'azurermish_lookup'; Provider = 'azurermish' }
        @{ BlockType = 'ephemeral'; Type = 'random_password'; Provider = 'random' }
    ) {
        param($BlockType, $Type, $Provider)

        Set-OrderingFixture -Provider $Provider -BlockType $BlockType -Type $Type
        Invoke-SchemaTransform
        Assert-SelectedSchema
        Get-OrderedElements | Should -Be @(
            'count', 'provider', 'z_optional', 'z_unlisted', 'parent_id', 'a_optional', 'z_required',
            'name', 'timeouts', 'a_unlisted', 'a_required', 'location', 'action', 'method',
            'resource_id', 'query_parameters', 'lifecycle', 'depends_on'
        )
        $first = Get-ScopeSnapshot
        Invoke-SchemaTransform
        Get-ScopeSnapshot | Should -BeExactly $first
    }

    It 'loads only <Provider> for <BlockType> with a <Binding> binding and preserves exact ordering' -TestCases @(
        foreach ($providerName in @('azurerm', 'azapi', 'random')) {
            foreach ($blockKind in @('resource', 'data')) {
                foreach ($bindingKind in @('default', 'alias', 'custom')) {
                    @{ Provider = $providerName; BlockType = $blockKind; Binding = $bindingKind }
                }
            }
        }
    ) {
        param($Provider, $BlockType, $Binding)

        Set-CachedSchema -Provider $Provider
        Set-OrderingFixture -Provider $Provider -BlockType $BlockType -Binding $Binding
        Invoke-SchemaTransform
        Assert-SelectedSchema -Providers @($Provider)
        $head = if ($Binding -eq 'default') { 'count' } else { 'for_each' }
        $body = if ($Provider -eq 'azapi') {
            @('a_required', 'action', 'location', 'method', 'name', 'parent_id', 'query_parameters',
                'resource_id', 'z_required', 'a_optional', 'z_optional')
        }
        else {
            @('a_required', 'z_required', 'a_optional', 'action', 'location', 'method', 'name',
                'parent_id', 'query_parameters', 'resource_id', 'z_optional')
        }
        Get-OrderedElements | Should -Be @(
            @($head, 'provider') + $body + @('z_unlisted', 'timeouts', 'a_unlisted', 'lifecycle', 'depends_on')
        )
        $first = Get-ScopeSnapshot
        Invoke-SchemaTransform
        Assert-SelectedSchema -Providers @($Provider)
        Get-ScopeSnapshot | Should -BeExactly $first
    }

    It 'loads every used schema in a mixed resource and data scope only once' {
        foreach ($providerName in $script:requests.Keys) {
            Set-CachedSchema -Provider $providerName
        }
        [System.IO.File]::WriteAllText((Join-Path $script:target 'main.tf'), @'
resource "azurerm_widget" "example" {
  z_required = "z"
  a_required = "a"
}
data "azapi_lookup" "example" {
  z_required = "z"
  a_required = "a"
}
resource "random_widget" "example" {
  z_required = "z"
  a_required = "a"
}
resource "random_widget" "another" {
  z_required = "z"
  a_required = "a"
}
'@)
        Invoke-SchemaTransform
        Assert-SelectedSchema -Providers @('azurerm', 'azapi', 'random')
        Get-OrderedElements | Should -Be @(
            'a_required', 'z_required', 'a_required', 'z_required',
            'a_required', 'z_required', 'a_required', 'z_required'
        )
        $first = Get-ScopeSnapshot
        Invoke-SchemaTransform
        Get-ScopeSnapshot | Should -BeExactly $first
    }

    It 'preserves the fallback ordering for an unlisted <Provider> type' -TestCases @(
        @{ Provider = 'azurerm' }
        @{ Provider = 'azapi' }
        @{ Provider = 'random' }
    ) {
        param($Provider)

        Set-CachedSchema -Provider $Provider
        Set-OrderingFixture -Provider $Provider -Type "${Provider}_future"
        Invoke-SchemaTransform
        Assert-SelectedSchema -Providers @($Provider)
        Get-OrderedElements | Should -Be @(
            'count', 'provider', 'z_optional', 'z_unlisted', 'parent_id', 'a_optional', 'z_required',
            'name', 'timeouts', 'a_unlisted', 'a_required', 'location', 'action', 'method',
            'resource_id', 'query_parameters', 'lifecycle', 'depends_on'
        )
    }

    It 'fails without a required <Provider> schema for <BlockType> and succeeds after recovery' -TestCases @(
        foreach ($providerName in @('azurerm', 'azapi', 'random')) {
            foreach ($blockKind in @('resource', 'data')) {
                @{ Provider = $providerName; BlockType = $blockKind }
            }
        }
    ) {
        param($Provider, $BlockType)

        Set-OrderingFixture -Provider $Provider -BlockType $BlockType
        $before = Get-ScopeSnapshot
        { Invoke-SchemaTransform } | Should -Throw '*cannot read *terraform providers schema*'
        Get-ScopeSnapshot | Should -BeExactly $before
        Set-CachedSchema -Provider $Provider
        Invoke-SchemaTransform
        Assert-SelectedSchema -Providers @($Provider)
    }

    It 're-evaluates schema selection when the same scope changes providers' {
        foreach ($provider in @('azurerm', 'azapi', 'random')) {
            foreach ($name in $script:requests.Keys) {
                [System.IO.File]::WriteAllText((Get-SchemaCachePath -Provider $name), $script:unusedSchema)
            }
            Set-CachedSchema -Provider $provider
            Set-OrderingFixture -Provider $provider -BlockType data
            Invoke-SchemaTransform
            Assert-SelectedSchema -Providers @($provider)
        }
        foreach ($providerName in $script:requests.Keys) {
            [System.IO.File]::WriteAllText((Get-SchemaCachePath -Provider $providerName), $script:unusedSchema)
        }
        [System.IO.File]::WriteAllText((Join-Path $script:target 'main.tf'), '')
        Invoke-SchemaTransform
        Assert-SelectedSchema
    }

    It 'selects generated AzAPI telemetry after root and module profiles with stable non-writing drift checks' {
        Set-TelemetryFixture
        Set-CachedSchema -Provider azapi
        $before = Get-ScopeSnapshot
        $drift = Invoke-SchemaEngine -CheckDrift
        $drift.Status | Should -Be 'fail'
        $drift.Changed | Should -Contain 'main.telemetry.tf'
        Get-ScopeSnapshot | Should -BeExactly $before
        (Invoke-SchemaEngine).Status | Should -Be 'pass'
        Assert-SelectedSchema -Providers @('azapi')
        $first = Get-ScopeSnapshot
        @((Invoke-SchemaEngine).Changed) | Should -HaveCount 0
        (Invoke-SchemaEngine -CheckDrift).Status | Should -Be 'pass'
        Get-ScopeSnapshot | Should -BeExactly $first
    }

    It 'restores drift-check source when the schema required by generated telemetry fails' {
        Set-TelemetryFixture
        $before = Get-ScopeSnapshot
        { Invoke-SchemaEngine -CheckDrift } | Should -Throw '*cannot read *terraform providers schema*'
        Get-ScopeSnapshot | Should -BeExactly $before
        Set-CachedSchema -Provider azapi
        (Invoke-SchemaEngine).Status | Should -Be 'pass'
        Assert-SelectedSchema -Providers @('azapi')
    }
}
