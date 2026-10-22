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

It 'annotates only native-proven retained contracts and leaves unrelated warnings active' {
        $root = $script:target
        $path = Join-Path $root 'terraform.tf'
        Set-Content -LiteralPath $path -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
    random = {
      source = "hashicorp/random"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}
'@
        $before = [IO.File]::ReadAllText($path)
        InModuleScope Avm.Authoring -Parameters @{ Root = $root; Profiles = $script:profilesRoot; Before = $before } {
            param($Root, $Profiles, $Before)
            $options = [pscustomobject]@{
                ToolPath = (Resolve-AvmTool -Name mapotf).Path
                EnvVars = @{}
                ProfileDirs = @{ 'provider-contract' = Join-Path $Profiles 'provider-contract' }
            }
            $sources = @{ $Root = @('registry.terraform.io/azure/azapi', 'registry.terraform.io/hashicorp/random') }
            Set-AvmProviderContractLintDirective -ProviderSources $sources -ProviderBindings @{} -Options $options
            [IO.File]::ReadAllText((Join-Path $Root 'terraform.tf')) | Should -BeExactly $Before
            Set-AvmProviderContractLintDirective -ProviderSources $sources `
                -ProviderBindings @{ $Root = @('azapi', 'random', 'time') } -Options $options
        }
        $content = [IO.File]::ReadAllText($path)
        $content | Should -Match '# tflint-ignore: terraform_unused_required_providers\r?\n\s*azapi ='
        $content | Should -Match '# tflint-ignore: terraform_unused_required_providers\r?\n\s*random ='
        $content | Should -Not -Match '# tflint-ignore: terraform_unused_required_providers\r?\n\s*time ='
        $lint = Invoke-UnusedProviderLint -Root $root
        $issues = @(($lint.StdOut | ConvertFrom-Json).issues)
        $issues | Should -HaveCount 1
        $issues[0].message | Should -BeExactly "provider 'time' is declared in required_providers but not used by the module"
    }

It 'retires ordinary transitive-only declarations without ignores on both engine passes' {
        $root = $script:target
        $child = Join-Path $root 'dependencies' 'library'
        $null = New-Item -ItemType Directory -Path $child -Force
        Remove-Item -LiteralPath (Join-Path $root 'metadata.json')
        $null = Initialize-AvmModuleMetadata -Path $root -Ecosystem terraform -ModuleType utility -InputObject @{
            moduleDisplayName = 'Provider inheritance'
            moduleDescription = 'Verifies transitive-only provider inheritance without caller contracts.'
            canonicalType = 'provider-inheritance'
            owners = @()
        }
        $requirements = @'
terraform {
  required_providers {
    azapi = { source = "Azure/azapi" }
    modtm = { source = "Azure/modtm" }
    random = { source = "hashicorp/random" }
  }
}
'@
        Set-Content -LiteralPath (Join-Path $root 'terraform.tf') -Encoding utf8NoBOM -Value $requirements
        Set-Content -LiteralPath (Join-Path $child 'main.tf') -Encoding utf8NoBOM -Value ($requirements + @'

data "azapi_client_config" "this" {}
data "modtm_module_source" "this" {
  module_path = path.module
}
resource "random_uuid" "this" {}
'@)
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "library" {
  source = "./dependencies/library"
  providers = {
    azapi = azapi
    modtm = modtm
    random = random
  }
}
'@
        $childBefore = [IO.File]::ReadAllText((Join-Path $child 'main.tf'))
        $first = $null
        foreach ($pass in 1..2) {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                (Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })).Status |
                    Should -BeExactly 'pass'
                $requirements = Get-AvmTerraformUnitTestRequiredProvider -Path $Root -Options ([pscustomobject]@{
                        ToolPath = (Resolve-AvmTool -Name mapotf).Path
                        EnvVars = @{}
                        ProfileDirs = @{ module = Resolve-AvmMapotfConfigDir -Root $Root -ProfileName module }
                    })
                $requirements.Count | Should -Be 0
            }
            $content = Get-TerraformContent -Root $root
            $content | Should -Not -Match 'providers\s*=|tflint-ignore'
            if ($pass -eq 1) { $first = $content }
            else { $content | Should -BeExactly $first }
            [IO.File]::ReadAllText((Join-Path $child 'main.tf')) | Should -BeExactly $childBefore
            (Invoke-UnusedProviderLint -Root $root).ExitCode | Should -Be 0
        }
    }

It 'converges mixed local provider maps before loading test-selected examples: <RetainModtm>' -ForEach @(
        @{ RetainModtm = $false }
        @{ RetainModtm = $true }
    ) {
        $root = $script:target
        $library = Join-Path $root 'dependencies' 'library'
        $example = Join-Path $root 'examples' 'management'
        $tests = Join-Path $root 'tests'
        $null = New-Item -ItemType Directory -Path $library, $example, $tests -Force
        $requirements = @'
terraform {
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
  }
}
'@
        Set-Content -LiteralPath (Join-Path $root 'terraform.tf') -Value $requirements -Encoding utf8NoBOM
        $rootContent = @'
module "library" {
  source = "./dependencies/library"
  __PROVIDERS__
}
data "azurerm_client_config" "this" {}
'@
        $mapping = if ($RetainModtm) { 'providers = { modtm = modtm }' } else { '' }
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM `
            -Value $rootContent.Replace('__PROVIDERS__', $mapping)
        $libraryContent = if ($RetainModtm) {
            @'
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
        }
        else { 'locals { fixture = true }' }
        Set-Content -LiteralPath (Join-Path $library 'main.tf') -Value $libraryContent -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $example 'terraform.tf') -Value $requirements -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $example 'main.tf') -Encoding utf8NoBOM -Value @'
provider "azapi" {
  alias = "management"
}
provider "azurerm" {
  alias = "management"
  features {}
}
module "example" {
  source = "../.."
  providers = {
    azapi   = azapi.management # Keep the management selection.
    azurerm = azurerm.management
    modtm   = modtm
  }
  location = "eastus"
}
'@
        $testPath = Join-Path $tests 'examples.tftest.hcl'
        Set-Content -LiteralPath $testPath -Encoding utf8NoBOM -Value @'
mock_provider "azapi" {}
mock_provider "azurerm" {}
mock_provider "modtm" {}
run "management" {
  command = plan
  module {
    source = "./examples/management"
  }
  providers = {
    azapi   = azapi
    azurerm = azurerm
    modtm   = modtm
  }
}
'@
        $testBytes = [IO.File]::ReadAllBytes($testPath)
        $libraryBytes = [IO.File]::ReadAllBytes((Join-Path $library 'main.tf'))
        $first = $null
        foreach ($pass in 1..3) {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root; Example = $example; RetainModtm = $RetainModtm } {
                param($Root, $Example, $RetainModtm)
                (Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })).Status |
                    Should -BeExactly 'pass'
                $tool = Resolve-AvmTool -Name mapotf
                $inspection = Invoke-AvmProcess -FilePath $tool.Path -WorkingDirectory $Example -ArgumentList @(
                    'debug', '--tf-dir', $Example,
                    '--mptf-dir', (Resolve-AvmMapotfConfigDir -Root $Root -ProfileName provider-inheritance),
                    '--eval', 'local.module_provider_entries')
                $entries = ($inspection.StdOut | ConvertFrom-Json -AsHashtable).example
                $entries.azapi | Should -BeExactly 'azapi.management'
                $entries.azurerm | Should -BeExactly 'azurerm.management'
                $entries.Contains('modtm') | Should -Be $RetainModtm
                foreach ($path in @($Root, $Example)) {
                    $requirements = Get-AvmTerraformUnitTestRequiredProvider -Path $path -Options ([pscustomobject]@{
                            ToolPath = $tool.Path
                            EnvVars = @{}
                            ProfileDirs = @{ module = Resolve-AvmMapotfConfigDir -Root $Root -ProfileName module }
                        })
                    $requirements.azapi.source | Should -BeExactly 'Azure/azapi'
                    $requirements.azapi.version | Should -BeExactly '~> 2.12'
                    $requirements.azurerm.source | Should -BeExactly 'hashicorp/azurerm'
                    $requirements.azurerm.version | Should -BeExactly '~> 4.0'
                    $requirements.Contains('modtm') | Should -Be $RetainModtm
                    if ($RetainModtm) {
                        $requirements.modtm.source | Should -BeExactly 'Azure/modtm'
                        $requirements.modtm.version | Should -BeExactly '~> 0.3'
                    }
                    $terraform = Resolve-AvmTool -Name terraform
                    $environment = @{ TF_DATA_DIR = Join-Path $path '.provider-proof' }
                    $null = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $path -EnvVars $environment `
                        -ArgumentList @('get', '-no-color')
                    $tree = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $path -EnvVars $environment `
                        -ArgumentList @('providers', '-no-color')
                    $null = ConvertFrom-AvmTerraformProviderTree -Text $tree.StdOut -Path $path
                }
            }
            [IO.File]::ReadAllBytes($testPath) | Should -Be $testBytes
            [IO.File]::ReadAllBytes((Join-Path $library 'main.tf')) | Should -Be $libraryBytes
            [IO.File]::ReadAllText((Join-Path $example 'main.tf')) | Should -Match '# Keep the management selection.'
            $content = (Get-TerraformContent -Root $root) + (Get-TerraformContent -Root $example)
            if ($pass -eq 1) { $first = $content }
            else { $content | Should -BeExactly $first }
        }
    }

It 'preserves an original version contract that constrains a real dependency without adding forwarding' {
        $root = $script:target
        Remove-Item -LiteralPath (Join-Path $root 'metadata.json')
        $null = Initialize-AvmModuleMetadata -Path $root -Ecosystem terraform -ModuleType utility -InputObject @{
            moduleDisplayName = 'Provider version contract'
            moduleDescription = 'Verifies an authored caller constraint on a real local dependency.'
            canonicalType = 'provider-version-contract'
            owners = @()
        }
        $child = Join-Path $root 'dependencies' 'library'
        $null = New-Item -ItemType Directory -Path $child -Force
        Set-Content -LiteralPath (Join-Path $child 'main.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
resource "random_uuid" "this" {}
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
      version = ">= 3.8.0"
    }
  }
}
module "library" {
  source = "./dependencies/library"
  providers = { random = random }
}
'@
        $first = $null
        foreach ($pass in 1..2) {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                (Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })).Status |
                    Should -BeExactly 'pass'
                $terraform = Resolve-AvmTool -Name terraform
                $environment = @{ TF_DATA_DIR = Join-Path $Root '.provider-version-proof' }
                $null = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $Root -EnvVars $environment `
                    -ArgumentList @('get', '-no-color')
                $tree = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $Root -EnvVars $environment `
                    -ArgumentList @('providers', '-no-color')
                $tree.StdOut | Should -Match 'provider\[registry\.terraform\.io/hashicorp/random\]\s+>= 3\.8\.0'
                $tree.StdOut | Should -Match 'provider\[registry\.terraform\.io/hashicorp/random\]\s+>= 3\.6'
            }
            $content = Get-TerraformContent -Root $root
            $content | Should -Match '# tflint-ignore: terraform_unused_required_providers\r?\n\s*random ='
            $content | Should -Not -Match 'providers\s*='
            if ($pass -eq 1) { $first = $content }
            else { $content | Should -BeExactly $first }
            (Invoke-UnusedProviderLint -Root $root).ExitCode | Should -Be 0
        }
        $profile = Join-Path $TestDrive 'remove-versioned-dependency'
        $null = New-Item -ItemType Directory -Path $profile
        Set-Content -LiteralPath (Join-Path $profile 'remove.mptf.hcl') -Encoding utf8NoBOM -Value @'
transform "remove_block" "dependency" {
  target_block_address = "module.library"
}
'@
        InModuleScope Avm.Authoring -Parameters @{ Root = $root; Profile = $profile } {
            param($Root, $Profile)
            $tool = Resolve-AvmTool -Name mapotf
            $null = Invoke-AvmProcess -FilePath $tool.Path -WorkingDirectory $Root `
                -ArgumentList @('transform', '--tf-dir', $Root, '--mptf-dir', $Profile)
            foreach ($pass in 1..2) {
                (Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })).Status |
                    Should -BeExactly 'pass'
                $requirements = Get-AvmTerraformUnitTestRequiredProvider -Path $Root -Options ([pscustomobject]@{
                        ToolPath = $tool.Path
                        EnvVars = @{}
                        ProfileDirs = @{ module = Resolve-AvmMapotfConfigDir -Root $Root -ProfileName module }
                    })
                $requirements.Count | Should -Be 0
            }
        }
    }

It 'retains an authored custom provider configuration on both engine passes: <Header>' -ForEach @(
        @{ Header = 'provider "custom"' }
        @{ Header = 'provider /* preserve the authored configuration */ "custom"' }
    ) {
        $root = $script:target
        Remove-Item -LiteralPath (Join-Path $root 'metadata.json')
        $null = Initialize-AvmModuleMetadata -Path $root -Ecosystem terraform -ModuleType utility -InputObject @{
            moduleDisplayName = 'Configured provider'
            moduleDescription = 'Verifies an authored configuration with a nonstandard provider local name.'
            canonicalType = 'configured-provider'
            owners = @()
        }
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    custom = {
      source = "Azure/azapi"
      version = "= 2.12.0"
    }
  }
}
'@
        Add-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value "$Header {}"
        $first = $null
        foreach ($pass in 1..2) {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                (Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })).Status |
                    Should -BeExactly 'pass'
            }
            $content = Get-TerraformContent -Root $root
            $content | Should -Match 'source\s*=\s*"Azure/azapi"'
            $content | Should -Match 'version\s*=\s*"= 2.12.0"'
            $content | Should -Match 'provider(?:\s|/\*[^*]*\*/)+"custom"\s*\{'
            $content | Should -Not -Match 'tflint-ignore'
            if ($pass -eq 1) { $first = $content }
            else { $content | Should -BeExactly $first }
        }
    }

It 'inherits whole default module maps for every provider without changing explicit selections or test bindings' {
        $root = $script:target
        $dependency = Join-Path $root 'dependency'
        $unit = Join-Path $root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $dependency, $unit
        Set-Content -LiteralPath (Join-Path $dependency 'main.tf') -Value 'locals { fixture = true }' -Encoding utf8NoBOM
        $main = Join-Path $root 'main.tf'
        Set-Content -LiteralPath $main -Encoding utf8NoBOM -Value @'
provider "azapi" {
  alias = "owner"
}
module "defaults" {
  source = "./dependency"
  providers = {
    azapi   = azapi
    azurerm = azurerm
    modtm   = modtm
    random  = random
    custom  = custom
  }
}
module "quoted" {
  source = "./dependency"
  providers = ({
    # These are literal keys, not evaluated strings or aliases.
    "m\u006fdtm" = modtm
    "azapi"     = azapi
  })
}
module "alias" {
  source = "./dependency"
  providers = {
    azapi = azapi.owner # Keep this selection.
  }
}
module "mixed" {
  source = "./dependency"
  providers = {
    azapi = azapi.owner
    modtm = modtm # Required while the explicit map remains.
  }
}
module "local_name" {
  source = "./dependency"
  providers = { child = azapi }
}
module "alias_key" {
  source = "./dependency"
  providers = { azapi.owner = azapi.owner }
}
module "empty" {
  source = "./dependency"
  providers = {}
}
module "implicit" {
  source = "./dependency"
}
'@
        $test = Join-Path $unit 'bindings.tftest.hcl'
        Set-Content -LiteralPath $test -Encoding utf8NoBOM -Value @'
mock_provider "modtm" {}
mock_provider "azapi" {
  alias = "unit"
}
run "explicit" {
  command = plan
  providers = {
    azapi = azapi.unit
    modtm = modtm
  }
  assert {
    condition     = true
    error_message = "Preserve the original assertion and native run bindings."
  }
}
'@
        $testBytes = [IO.File]::ReadAllBytes($test)
        InModuleScope Avm.Authoring -Parameters @{ Root = $root; Profiles = $script:profilesRoot } {
            param($Root, $Profiles)
            $mapotf = Resolve-AvmTool -Name mapotf
            $profile = Join-Path $Profiles 'provider-inheritance'
            $inspect = @('debug', '--tf-dir', $Root, '--mptf-dir', $profile,
                '--eval', 'data.module.provider_inheritance.result')
            $before = (Invoke-AvmProcess -FilePath $mapotf.Path -ArgumentList $inspect -WorkingDirectory $Root).
                StdOut | ConvertFrom-Json -AsHashtable
            $null = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $Root -ArgumentList @(
                'transform', '--tf-dir', $Root, '--mptf-dir', (Join-Path $Profiles 'common'))
            $null = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $Root -ArgumentList @(
                'transform', '--tf-dir', $Root, '--mptf-dir', $profile)
            $after = (Invoke-AvmProcess -FilePath $mapotf.Path -ArgumentList $inspect -WorkingDirectory $Root).
                StdOut | ConvertFrom-Json -AsHashtable
            foreach ($name in @('defaults', 'quoted', 'implicit')) {
                $after[$name].Contains('providers') | Should -BeFalse
            }
            foreach ($name in @('alias', 'mixed', 'local_name', 'alias_key', 'empty')) {
                ($after[$name].providers | ConvertTo-Json -Depth 5 -Compress) |
                    Should -BeExactly ($before[$name].providers | ConvertTo-Json -Depth 5 -Compress)
            }
            $first = [IO.File]::ReadAllBytes((Join-Path $Root 'main.tf'))
            $null = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $Root -ArgumentList @(
                'transform', '--tf-dir', $Root, '--mptf-dir', $profile)
            [IO.File]::ReadAllBytes((Join-Path $Root 'main.tf')) | Should -Be $first
        }
        [IO.File]::ReadAllBytes($test) | Should -Be $testBytes
        [IO.File]::ReadAllText($main) | Should -Match 'provider "azapi" \{\s+alias = "owner"'
    }

It 'removes only unsupported same-default ModTM entries without rewriting non-default maps' {
        $root = $script:target
        $main = Join-Path $root 'main.tf'
        Set-Content -LiteralPath $main -Encoding utf8NoBOM -Value @'
provider "modtm" {
  alias = "owner"
}
module "retired" {
  source = "./dependency"
  providers = {
    azapi = azapi.management # Keep this selection.
    modtm = modtm
  }
}
module "selected" {
  source = "./dependency"
  providers = {
    azapi = azapi.management
    modtm = modtm.owner # Never erase an authored non-default binding.
  }
}
module "renamed" {
  source = "./dependency"
  providers = { modtm = custom }
}
module "alias_key" {
  source = "./dependency"
  providers = { modtm.owner = modtm.owner }
}
module "required" {
  source = "./dependency"
  providers = {
    azapi = azapi.management
    modtm = modtm
  }
}
'@
        InModuleScope Avm.Authoring -Parameters @{ Root = $root; Profiles = $script:profilesRoot } {
            param($Root, $Profiles)
            $tool = Resolve-AvmTool -Name mapotf
            $profile = Join-Path $Profiles 'utility-module'
            $facts = 'provider_source_facts={retired=[],selected=[],renamed=[],alias_key=[],required=["registry.terraform.io/azure/modtm"]}'
            $first = $null
            foreach ($pass in 1..2) {
                $null = Invoke-AvmProcess -FilePath $tool.Path -WorkingDirectory $Root -ArgumentList @(
                    'transform', '--tf-dir', $Root, '--mptf-dir', $profile,
                    '--mptf-var', $facts, '--mptf-var', 'apply_utility_migration=false')
                $inspection = Invoke-AvmProcess -FilePath $tool.Path -WorkingDirectory $Root -ArgumentList @(
                    'debug', '--tf-dir', $Root, '--mptf-dir', $profile,
                    '--eval', '{ entries = local.provider_mapping_entries, calls = data.module.utility.result }')
                $inspection = $inspection.StdOut | ConvertFrom-Json -AsHashtable
                $entries = $inspection.entries
                $entries.retired.Contains('modtm') | Should -BeFalse
                $entries.retired.azapi | Should -BeExactly 'azapi.management'
                $entries.selected.modtm | Should -BeExactly 'modtm.owner'
                $entries.renamed.modtm | Should -BeExactly 'custom'
                $inspection.calls.alias_key.providers | Should -Match 'modtm[.]owner\s*=\s*modtm[.]owner'
                $entries.required.modtm | Should -BeExactly 'modtm'
                $content = [IO.File]::ReadAllText((Join-Path $Root 'main.tf'))
                if ($pass -eq 1) { $first = $content }
                else { $content | Should -BeExactly $first }
            }
        }
        [IO.File]::ReadAllText($main) | Should -Match '# Keep this selection.'
        [IO.File]::ReadAllText($main) | Should -Match '# Never erase an authored non-default binding.'
        [IO.File]::ReadAllText($main) | Should -Match 'provider "modtm" \{\s+alias = "owner"'
    }

It 'restores ModTM only into retained explicit maps and never creates an implicit forwarding map' {
        $root = $script:target
        $dependency = Join-Path $root 'dependency'
        $null = New-Item -ItemType Directory -Path $dependency
        Set-Content -LiteralPath (Join-Path $dependency 'main.tf') -Value 'locals { fixture = true }' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "implicit" {
  source = "./dependency"
}
module "defaults" {
  source = "./dependency"
  providers = { azapi = azapi }
}
module "mixed" {
  source = "./dependency"
  providers = {
    azapi = azapi.owner # Preserve the genuine selection.
  }
}
module "modtm_alias" {
  source = "./dependency"
  providers = {
    modtm = modtm.owner # Never replace an authored alias.
    azapi = azapi
  }
}
module "unrelated" {
  source = "./dependency"
  providers = { azapi = azapi.owner }
}
'@
        InModuleScope Avm.Authoring -Parameters @{ Root = $root; Profiles = $script:profilesRoot } {
            param($Root, $Profiles)
            $mapotf = Resolve-AvmTool -Name mapotf
            $arguments = @(
                'transform', '--tf-dir', $Root,
                '--mptf-dir', (Join-Path $Profiles 'provider-restore'),
                '--mptf-var', 'unit_test_modtm_dependencies=["implicit","defaults","mixed","modtm_alias"]'
            )
            $first = $null
            foreach ($pass in 1..2) {
                $null = Invoke-AvmProcess -FilePath $mapotf.Path -ArgumentList $arguments -WorkingDirectory $Root
                $null = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $Root -ArgumentList @(
                    'transform', '--tf-dir', $Root, '--mptf-dir', (Join-Path $Profiles 'provider-inheritance'))
                $inspection = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $Root -ArgumentList @(
                    'debug', '--tf-dir', $Root, '--mptf-dir', (Join-Path $Profiles 'provider-inheritance'),
                    '--eval', 'local.module_provider_entries'
                )
                $entries = $inspection.StdOut | ConvertFrom-Json -AsHashtable
                $entries.Contains('implicit') | Should -BeFalse
                $entries.Contains('defaults') | Should -BeFalse
                $entries.mixed.azapi | Should -BeExactly 'azapi.owner'
                $entries.mixed.modtm | Should -BeExactly 'modtm'
                $entries.modtm_alias.modtm | Should -BeExactly 'modtm.owner'
                $entries.modtm_alias.azapi | Should -BeExactly 'azapi'
                $entries.unrelated.Contains('modtm') | Should -BeFalse
                $content = [IO.File]::ReadAllText((Join-Path $Root 'main.tf'))
                $content | Should -Match '# Preserve the genuine selection.'
                $content | Should -Match '# Never replace an authored alias.'
                if ($pass -eq 1) { $first = $content }
                else { $content | Should -BeExactly $first }
            }
        }
    }

It 'preserves authored provider configurations through two full transforms after <Dependency>' -ForEach @(
        @{ Dependency = 'local dependency inheritance'; Utility = $false }
        @{ Dependency = 'the last legacy utility migration'; Utility = $true }
    ) {
        $root = $script:target
        $requirement = @'
terraform {
  required_providers {
    modtm = {
      source  = "Azure/modtm"
      version = "= 0.3.5"
    }
  }
}
'@
        if ($Utility) {
            $call = @'
module "regions" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.12.0"
  location = "eastus"
  providers = { modtm = modtm }
}
'@
        }
        else {
            $dependency = Join-Path $root 'modules' 'dependency'
            $null = New-Item -ItemType Directory -Path $dependency -Force
            Set-Content -LiteralPath (Join-Path $dependency 'metadata.json') -Value '{}' -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $dependency 'terraform.tf') -Value $requirement -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $dependency 'main.tf') -Encoding utf8NoBOM -Value @'
data "modtm_module_source" "authored" {
  module_path = path.module
}
'@
            $call = @'
module "dependency" {
  source = "./modules/dependency"
  providers = { modtm = modtm }
}
'@
        }
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value ("provider `"modtm`" {}`n" + $call)
        $callers = @($root)
        foreach ($scope in @('examples', 'tests') | Where-Object { -not $Utility }) {
            $caller = Join-Path $root $scope 'default'
            $null = New-Item -ItemType Directory -Path $caller -Force
            $callers += $caller
            Set-Content -LiteralPath (Join-Path $caller 'main.tf') -Encoding utf8NoBOM -Value @'
provider "modtm" {}
module "subject" {
  source = "../.."
  providers = { modtm = modtm }
}
'@
        }
        foreach ($caller in $callers) {
            Set-Content -LiteralPath (Join-Path $caller 'terraform.tf') -Value $requirement -Encoding utf8NoBOM
        }
        InModuleScope Avm.Authoring -Parameters @{ Root = $root; Profiles = $script:profilesRoot; Callers = $callers; Utility = $Utility } {
            param($Root, $Profiles, $Callers, $Utility)
            $mapotf = Resolve-AvmTool -Name mapotf
            $first = @{}
            foreach ($pass in 1..2) {
                $result = Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
                $result.Status | Should -BeExactly 'pass'
                foreach ($caller in $Callers) {
                    $inspection = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $caller -ArgumentList @(
                        'debug', '--tf-dir', $caller, '--mptf-dir', (Join-Path $Profiles 'module'),
                        '--eval', 'data.terraform.this.required_providers'
                    )
                    $requirements = $inspection.StdOut | ConvertFrom-Json -AsHashtable
                    $requirements.Contains('modtm') | Should -BeTrue -Because "pass $pass must preserve the authored provider's source in $caller"
                    $requirements.modtm.source | Should -BeExactly 'Azure/modtm'
                    $requirements.modtm.version | Should -BeExactly '= 0.3.5'
                    $content = Get-ChildItem -LiteralPath $caller -File -Filter '*.tf' | Sort-Object Name |
                        ForEach-Object { [IO.File]::ReadAllText($_.FullName) }
                    $content -join "`n" | Should -Not -Match '(?m)^\s*providers\s*='
                    $content -join "`n" | Should -Match 'provider "modtm" \{\}'
                    if ($Utility -and $caller -ceq $Root) {
                        $content -join "`n" | Should -Match 'version\s*=\s*"0\.13\.0"'
                    }
                    if ($pass -eq 1) { $first[$caller] = $content -join "`n" }
                    else { $content -join "`n" | Should -BeExactly $first[$caller] }
                }
            }
        }
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

It 'inherits child-only AzAPI after migrating <Binding> utility bindings' -ForEach @(
        @{ Binding = 'implicit' }
        @{ Binding = 'retired ModTM-only' }
    ) {
        $root = $script:target
        $providers = ''
        if ($Binding -eq 'retired ModTM-only') {
            $providers = '  providers = { modtm = modtm }'
            Set-Content -LiteralPath (Join-Path $root 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_version = "~> 1.9"
  required_providers {
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
  }
}
'@
        }
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @"
module "regions" {
  source           = "Azure/avm-utl-regions/azurerm"
  version          = "0.12.0"
  location         = "eastus"
  enable_telemetry = true
$providers
}
"@
        InModuleScope Avm.Authoring -Parameters @{
            Root = $root; Profiles = $script:profilesRoot; LintConfig = $script:lintConfig
            InspectionRoot = (Join-Path $TestDrive 'inheritance-inspection')
        } {
            param($Root, $Profiles, $LintConfig, $InspectionRoot)
            $terraform = Resolve-AvmTool -Name terraform
            $mapotf = Resolve-AvmTool -Name mapotf
            $tflint = Resolve-AvmTool -Name tflint
            $environment = New-AvmToolPathEnvironment -ToolPath $terraform.Path -ToolName terraform
            $profilesByName = @{}
            foreach ($name in @('utility-module', 'module', 'provider-restore', 'provider-contract', 'unit-test-inspect', 'variable-order', 'common')) {
                $profilesByName[$name] = Join-Path $Profiles $name
            }
            $options = [pscustomobject]@{
                ToolPath = $mapotf.Path; TerraformPath = $terraform.Path; EnvVars = $environment
                InspectionRoot = $InspectionRoot; ProfileDirs = $profilesByName; UtilityProviderSources = @{}
            }
            $targets = @([pscustomobject]@{ Path = $Root; Scope = 'example'; Profiles = @('example') })
            $first = $null
            foreach ($pass in 1..2) {
                $plans = @(Get-AvmTerraformUtilityMigrationPlan -Targets $targets -Options $options)
                Invoke-AvmTerraformUtilityMigration -Plans $plans -Options $options
                Invoke-AvmTerraformUtilityProviderCleanup -Plans $plans -ModuleTargets $targets -Options $options
                $inspection = Get-AvmTerraformUtilityInspection -Path $Root -Options $options
                $inspection.requirements.Count | Should -Be 0
                $inspection.calls.regions.Contains('providers') | Should -BeFalse
                $inspection.calls.regions.version | Should -BeExactly '0.13.0'
                $content = [IO.File]::ReadAllText((Join-Path $Root 'main.tf')) +
                [IO.File]::ReadAllText((Join-Path $Root 'terraform.tf'))
                if ($pass -eq 1) { $first = $content }
                else { $content | Should -BeExactly $first }
            }
            $null = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $Root -EnvVars $environment `
                -ArgumentList @('init', '-backend=false', '-input=false', '-no-color')
            $null = Invoke-AvmProcess -FilePath $terraform.Path -WorkingDirectory $Root -EnvVars $environment `
                -ArgumentList @('validate', '-no-color')
            $lint = Invoke-AvmProcess -FilePath $tflint.Path -WorkingDirectory $Root -EnvVars $environment -ArgumentList @(
                '--config', $LintConfig, '--only=terraform_required_providers',
                '--only=terraform_unused_required_providers', '--format=json'
            )
            $lint.ExitCode | Should -Be 0
            @((ConvertFrom-Json $lint.StdOut).issues) | Should -HaveCount 0
        }
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
            foreach ($name in @('utility-module', 'module', 'provider-restore', 'provider-contract', 'unit-test-inspect', 'variable-order', 'common')) {
                $profilesByName[$name] = Join-Path $Profiles $name
            }
            $options = [pscustomobject]@{
                ToolPath = $mapotf.Path; TerraformPath = $terraform.Path; EnvVars = $environment
                InspectionRoot = $InspectionRoot; ProfileDirs = $profilesByName; UtilityProviderSources = @{}
                Root = $Root
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
                $retainedProviderSources = @{}
                Invoke-AvmTerraformUtilityProviderCleanup -Plans $plans -ModuleTargets $targets -Options $options `
                    -RetainedProviderSources $retainedProviderSources
                $bindings = Get-AvmTerraformProviderContractBinding -Targets $targets -Snapshots @() -Options $options
                Set-AvmProviderContractLintDirective -ProviderSources $retainedProviderSources -ProviderBindings $bindings -Options $options
                foreach ($target in $targets) {
                    $path = $target.Path
                    $null = Invoke-AvmProcess -FilePath $mapotf.Path -WorkingDirectory $path -EnvVars $environment `
                        -ArgumentList @('clean-backup', '--tf-dir', $path)
                    $inspection = Get-AvmTerraformUtilityInspection -Path $path -Options $options
                    $inspection.requirements.modtm.source | Should -BeExactly 'registry.terraform.io/azure/modtm'
                    $inspection.requirements.modtm.version | Should -BeExactly '~> 0.3'
                    $inspection.requirements.azapi.version | Should -BeExactly '~> 2.12'
                    if ($path -ceq $Root) {
                        $inspection.calls.legacy.Contains('providers') | Should -BeFalse
                        [IO.File]::ReadAllText((Join-Path $path 'terraform.tf')) |
                            Should -Match '(?m)^\s*# tflint-ignore: terraform_unused_required_providers\r?\n\s*modtm ='
                    }
                    else {
                        $mapping = ConvertFrom-AvmTerraformUnitTestProviderMapping -Expression $inspection.calls.parent.providers `
                            -ProviderNames @() -AllowUnlistedProviders
                        $mapping.Bindings.modtm | Should -BeExactly 'modtm'
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
