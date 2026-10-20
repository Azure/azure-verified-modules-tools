#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: MAPOTF provider requirements' -Tag Qualification {
BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $moduleRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
        $script:profilesRoot = Join-Path $moduleRoot 'Resources' 'mapotf'
        $script:originalAvmHome = $env:AVM_HOME
        if (-not $env:AVM_HOME) {
            $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        }
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        Install-AvmTool -Name @('terraform', 'tflint', 'mapotf') -ErrorAction Stop
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
  "telemetryIdPrefix": "46d3xtrf.res.d4e5f6a",
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

It 'renders retained ModTM requirements without JSON encoding for <State>' -TestCases (@(
        @{ State = 'an authored requirement'; Source = 'azure/modtm'; Version = '~> 0.3' }
        @{ State = 'an example without a requirement'; Source = 'registry.terraform.io/azure/modtm'; Version = '>= 0.3.0, < 0.4.0' }
        @{ State = 'no terraform block'; Source = 'Azure/modtm'; Version = '~> 0.3' }
        @{ State = 'an existing inline requirement'; Source = 'azure/modtm'; Version = '~> 0.3' }
        @{ State = 'an authored versionless requirement'; Source = 'Azure/modtm'; Version = $null }
        @{ State = 'an example with an authored location'; Source = 'Azure/modtm'; Version = '~> 0.3' }
    ) | Where-Object { $_.State -cin @('an example without a requirement', 'an example with an authored location') }) {
        param($State, $Source, $Version)

        $root = $script:target
        $dependency = Join-Path $root 'dependency'
        $null = New-Item -ItemType Directory -Path $dependency
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "dependency" {
  source = "./dependency"
}
'@
        $terraformFile = Join-Path $root 'terraform.tf'
        $requirement = [ordered]@{ source = $Source }
        $expected = "    modtm = {`n      source = `"$Source`"`n    }"
        if ($Version) {
            $requirement.version = $Version
            $expected = "    modtm = {`n      source  = `"$Source`"`n      version = `"$Version`"`n    }"
        }
        $existing = $State -in @('an authored requirement', 'an existing inline requirement', 'an authored versionless requirement')
        if ($existing) {
            if ($State -eq 'an existing inline requirement') {
                $expected = '    modtm = { source = "azure/modtm", version = "~> 0.3" }'
            }
            Set-Content -LiteralPath $terraformFile -Encoding utf8NoBOM -Value "terraform {`n  required_providers {`n$expected`n  }`n}"
        }
        elseif ($State -eq 'no terraform block') {
            Remove-Item -LiteralPath $terraformFile
        }
        if ($State -eq 'an example with an authored location') {
            Add-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
locals {
  location = "westeurope"
}
resource "azapi_resource" "authored" {
  type      = "Microsoft.Resources/resourceGroups@2025-04-01"
  name      = "authored"
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
  location  = local.location
  body      = {}
}
'@
            Set-Content -LiteralPath $terraformFile -Encoding utf8NoBOM -Value @'
terraform {
  required_version = "~> 1.9"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
  }
}
'@
        }
        Set-Content -LiteralPath (Join-Path $dependency 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
  }
}
'@

        InModuleScope Avm.Authoring -Parameters @{
            Root = $root; Dependency = $dependency; Profiles = $script:profilesRoot
            Requirement = $requirement; Existing = $existing; Expected = $expected
        } {
            param($Root, $Dependency, $Profiles, $Requirement, $Existing, $Expected)

            $mapotf = Resolve-AvmTool -Name mapotf
            $source = 'registry.terraform.io/azure/modtm'
            $required = @{
                $Root = @{}
                $Dependency = @{ modtm = $Requirement }
            }
            if ($Existing) { $required[$Root].modtm = $Requirement }
            $plan = Get-AvmTerraformUnitTestModtmRequirementPlan -Path $Root `
                -ModuleTargets @([pscustomobject]@{ Path = $Root }) `
                -Options ([pscustomobject]@{
                    ToolPath = $mapotf.Path
                    ProfileDirs = @{
                        module = Join-Path $Profiles 'module'
                        'provider-restore' = Join-Path $Profiles 'provider-restore'
                    }
                    EnvVars = @{}
                }) `
                -RequiredProviders $required -ProviderSources @{ $Root = @($source) } `
                -ModuleProviderSources @{ $Root = @{ dependency = @($source) } } `
                -ModuleManifests @{
                    $Root = ConvertTo-Json -Depth 5 -Compress -InputObject @{
                        Modules = @(@{ Key = ''; Dir = '.' }, @{ Key = 'dependency'; Dir = $Dependency })
                    }
                } `
                -OriginalRequirements @{ $Root = @{ modtm = $Requirement } } `
                -Plans @{} -PlanningPaths ([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)) `
                -BindDependencies
            $inspection = @('debug') + $plan.Arguments[1..($plan.Arguments.Count - 1)] + @('--eval', $plan.Capabilities)
            $capabilities = Invoke-AvmProcess -FilePath $mapotf.Path -ArgumentList $inspection -WorkingDirectory $Root
            ($capabilities.StdOut | ConvertFrom-Json) | Should -BeTrue
            $null = Invoke-AvmProcess -FilePath $mapotf.Path -ArgumentList $plan.Arguments -WorkingDirectory $Root
            $null = Invoke-AvmProcess -FilePath $mapotf.Path -ArgumentList @('clean-backup', '--tf-dir', $Root) -WorkingDirectory $Root

            $terraformFile = Join-Path $Root 'terraform.tf'
            $first = [System.IO.File]::ReadAllText($terraformFile)
            $first | Should -Match ([regex]::Escape($Expected)) -Because 'generated provider requirements should use multiline HCL and preserve authored formatting'
            $first | Should -Not -Match '\\u003[ce]'
            $terraform = Resolve-AvmTool -Name terraform
            $null = Invoke-AvmProcess -FilePath $terraform.Path -ArgumentList @('fmt', '-check', '-diff') -WorkingDirectory $Root
            $requirements = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $Root -ArgumentList @(
                'debug', '--tf-dir', $Root, '--mptf-dir', (Join-Path $Profiles 'module'),
                '--eval', 'data.terraform.this.required_providers.modtm'
            )
            $actual = ConvertFrom-Json -InputObject $requirements.StdOut -AsHashtable
            $actual.source | Should -BeExactly $Requirement.source
            $actual['version'] | Should -BeExactly $Requirement['version']

            $null = Invoke-AvmProcess -FilePath $mapotf.Path -ArgumentList $plan.Arguments -WorkingDirectory $Root
            $null = Invoke-AvmProcess -FilePath $mapotf.Path -ArgumentList @('clean-backup', '--tf-dir', $Root) -WorkingDirectory $Root
            [System.IO.File]::ReadAllText($terraformFile) | Should -BeExactly $first
        }
        if ($State -eq 'an example with an authored location') {
            Join-Path $root 'variables.tf' | Should -Not -Exist
            Get-Content -LiteralPath $terraformFile -Raw | Should -Match 'required_version\s*=\s*"~> 1\.9"'
            Get-Content -LiteralPath $terraformFile -Raw | Should -Match 'version\s*=\s*"~> 2\.4"'
            Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw | Should -Match 'location\s*=\s*local\.location'
        }
    }

It 'preserves aliases for <Scenario> with <Syntax> syntax' -TestCases (@(
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
    ) | Where-Object { $_.Syntax -ceq 'comments' -and $_.Scenario -ceq 'both upgrades' }) {
        param($Scenario, $Syntax, $AzapiVersion, $RandomVersion, $ExpectedAzapiVersion, $ExpectedRandomVersion)

        $source = New-AliasedProviderConfiguration -Syntax $Syntax -AzapiVersion $AzapiVersion -RandomVersion $RandomVersion
        Set-Content -LiteralPath (Join-Path $script:target 'terraform.tf') -Value $source -Encoding utf8NoBOM -NoNewline
        $expected = New-AliasedProviderConfiguration -Syntax $Syntax -AzapiVersion $ExpectedAzapiVersion -RandomVersion $ExpectedRandomVersion
        Assert-ProviderRequirements -Root $script:target -ExpectedConfiguration $expected
    }

It 'reconciles explicit-map callers of a shared utility dependency without changing selections' {
        $root = $script:target
        $dependency = Join-Path $root 'dependencies' 'legacy'
        $null = New-Item -ItemType Directory -Path $dependency -Force
        Set-Content -LiteralPath (Join-Path $dependency 'main.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
  }
}
data "modtm_module_source" "this" {
  module_path = path.module
}
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "legacy" {
  source = "./dependencies/legacy"
}
data "azapi_client_config" "current" {}
'@
        $requirements = @'
terraform {
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
  }
}
'@
        Set-Content -LiteralPath (Join-Path $root 'terraform.tf') -Encoding utf8NoBOM -Value $requirements
        foreach ($name in @('default', 'complete', 'custom')) {
            $example = Join-Path $root 'examples' $name
            $null = New-Item -ItemType Directory -Path $example -Force
            Set-Content -LiteralPath (Join-Path $example 'terraform.tf') -Encoding utf8NoBOM -Value $requirements
            Set-Content -LiteralPath (Join-Path $example 'main.tf') -Encoding utf8NoBOM -Value @'
provider "azapi" {
  alias           = "management"
  subscription_id = "00000000-0000-0000-0000-000000000000"
}
module "parent" {
  source = "../.."
  providers = {
    azapi = azapi.management # keep the management subscription
  }
}
'@
        }
        $default = Join-Path $root 'examples' 'default'
        Add-Content -LiteralPath (Join-Path $default 'main.tf') -Encoding utf8NoBOM -Value @'
module "names" {
  source  = "Azure/naming/azurerm"
  version = "0.4.4"
}
'@
        InModuleScope Avm.Authoring -Parameters @{
            Root = $root; Dependency = $dependency; Profiles = $script:profilesRoot; LintConfig = $script:lintConfig
            InspectionRoot = (Join-Path $TestDrive 'caller-inspection')
        } {
            param($Root, $Dependency, $Profiles, $LintConfig, $InspectionRoot)
            $terraform = Resolve-AvmTool -Name terraform
            $mapotf = Resolve-AvmTool -Name mapotf
            $tflint = Resolve-AvmTool -Name tflint
            $environment = New-AvmToolPathEnvironment -ToolPath $terraform.Path -ToolName terraform
            foreach ($name in @('TF_DATA_DIR', 'TF_PLUGIN_CACHE_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_get',
                    'TF_CLI_ARGS_init', 'TF_CLI_ARGS_validate')) {
                $environment[$name] = $null
            }
            $environment.MODTM_ENDPOINT = 'http://127.0.0.1:1'
            $profilesByName = @{}
            foreach ($name in @('utility-module', 'module', 'provider-restore', 'unit-test-inspect', 'variable-order', 'common')) {
                $profilesByName[$name] = Join-Path $Profiles $name
            }
            $options = [pscustomobject]@{
                ToolPath = $mapotf.Path; TerraformPath = $terraform.Path; EnvVars = $environment
                InspectionRoot = $InspectionRoot; ProfileDirs = $profilesByName; UtilityProviderSources = @{}
            }
            $targets = @([pscustomobject]@{ Path = $Root; Scope = 'root' })
            foreach ($name in @('default', 'complete', 'custom')) {
                $targets += [pscustomobject]@{ Path = Join-Path $Root 'examples' $name; Scope = 'example' }
            }
            $snapshots = @{}
            foreach ($target in $targets) {
                $path = $target.Path
                $null = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $path -EnvVars $environment `
                    -ArgumentList @('init', '-backend=false', '-input=false', '-no-color')
                $null = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $path -EnvVars $environment `
                    -ArgumentList @('validate', '-no-color')
                foreach ($name in @('.terraform.lock.hcl', (Join-Path '.terraform' 'modules' 'modules.json'))) {
                    $file = Join-Path $path $name
                    $snapshots[$file] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
                }
            }
            $dependencyBefore = [IO.File]::ReadAllText((Join-Path $Dependency 'main.tf'))
            $first = @{}
            foreach ($pass in 1..2) {
                $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $options)
                $plans | Should -HaveCount 4
                Invoke-AvmTerraformUtilityProviderCleanup -Plans $plans -ModuleTargets $targets -Options $options
                foreach ($target in $targets) {
                    $path = $target.Path
                    $null = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $path -EnvVars $environment `
                        -ArgumentList @('clean-backup', '--tf-dir', $path)
                    $inspection = Get-AvmTerraformUtilityInspection -Path $path -Options $options
                    $inspection.requirements.modtm.source | Should -BeExactly 'registry.terraform.io/azure/modtm'
                    $inspection.requirements.modtm.version | Should -BeExactly '~> 0.3'
                    $inspection.requirements.azapi.version | Should -BeExactly '~> 2.12'
                    $call = if ($path -ceq $Root) { 'legacy' } else { 'parent' }
                    $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $inspection.calls[$call].providers `
                        -ProviderNames @() -AllowUnlistedProviders
                    $mapping.Bindings.modtm | Should -BeExactly 'modtm'
                    if ($path -cne $Root) {
                        $mapping.Bindings.azapi | Should -BeExactly 'azapi.management'
                        $inspection.calls.parent.providers | Should -Match '# keep the management subscription'
                    }
                    $null = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $path -EnvVars $environment `
                        -ArgumentList @('init', '-backend=false', '-input=false', '-lockfile=readonly', '-no-color')
                    $null = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $path -EnvVars $environment `
                        -ArgumentList @('validate', '-no-color')
                    $null = Invoke-AvmProcess -FilePath $tflint.Path -WorkingDirectory $path -EnvVars $environment -ArgumentList @(
                        '--config', $LintConfig, '--only=terraform_required_providers', '--only=terraform_unused_required_providers'
                    )
                    foreach ($file in Get-ChildItem -LiteralPath $path -Filter '*.tf' -File) {
                        $content = [IO.File]::ReadAllText($file.FullName)
                        if ($pass -eq 1) { $first[$file.FullName] = $content }
                        else { $content | Should -BeExactly $first[$file.FullName] }
                    }
                }
                foreach ($file in $snapshots.Keys) {
                    [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) | Should -BeExactly $snapshots[$file]
                }
                [IO.File]::ReadAllText((Join-Path $Dependency 'main.tf')) | Should -BeExactly $dependencyBefore
                $default = Get-AvmTerraformUtilityInspection -Path (Join-Path $Root 'examples' 'default') -Options $options
                $default.calls.names.source | Should -BeExactly 'Azure/naming/azurerm'
                $default.calls.names.version | Should -BeExactly '0.4.4'
            }
        }
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
