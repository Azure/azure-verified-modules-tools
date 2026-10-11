#Requires -Version 7.4

Describe 'Integration: Terraform policy provider registration safeguards' -Tag 'Integration' {
    BeforeAll {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $repo 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
        $script:tools = InModuleScope Avm.Authoring {
            @{ Terraform = Resolve-AvmTool -Name terraform; Conftest = Resolve-AvmTool -Name conftest }
        }
        $script:tools.Terraform.Version | Should -Be '1.16.5'
        $script:providerCache = Join-Path $TestDrive 'providers'
        $null = New-Item -ItemType Directory -Path $script:providerCache
    }

    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'uses native HCL parsing, schemas and validation for AzureRM <Version> plus AzAPI, including downloaded providers' -ForEach @(
        @{ Version = '3.117.1'; Mode = 'legacy' }
        @{ Version = '4.81.0'; Mode = 'modern' }
    ) {
        $case = Join-Path $TestDrive $Mode
        $source = Join-Path $case 'source'
        $local = Join-Path $source 'local'
        $remote = Join-Path $case 'remote repository'
        $stage = Join-Path $case 'stage'
        $working = Join-Path $stage 'module'
        $null = New-Item -ItemType Directory -Path $local, $remote -Force
        $requirements = @"
terraform {
  required_providers {
    azure = {
      source = "hashicorp/azurerm"
      version = "$Version"
    }
    azapi = {
      source = "Azure/azapi"
      version = "2.13.0"
    }
  }
}
"@
        Set-Content -LiteralPath (Join-Path $source 'terraform.tf') -Value $requirements.ReplaceLineEndings("`n") -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $remote 'terraform.tf') -Value $requirements.ReplaceLineEndings("`n") -Encoding utf8NoBOM
        $provider = @'
provider "azure" {
  features {}
  skip_provider_registration = "invalid-boolean"
  use_cli = false
  use_msi = false
  use_oidc = false
}
resource "azurerm_resource_group" "example" {
  provider = azure
  name = "not-deployed"
  location = "westus2"
}
'@
        Set-Content -LiteralPath (Join-Path $remote 'main.tf') -Value $provider.ReplaceLineEndings("`n") -Encoding utf8NoBOM
        & git -C $remote init --quiet
        & git -C $remote -c user.name='AVM Tests' -c user.email='tests@example.invalid' add -A
        & git -C $remote -c user.name='AVM Tests' -c user.email='tests@example.invalid' commit --quiet -m fixture
        $LASTEXITCODE | Should -Be 0
        $remoteUri = [System.UriBuilder]::new([System.Uri]::UriSchemeFile, '')
        $remoteUri.Path = [System.IO.Path]::GetFullPath($remote)
        $remoteUri.Uri.IsAbsoluteUri | Should -BeTrue
        $remoteUri.Uri.IsFile | Should -BeTrue
        $remoteUri.Uri.AbsoluteUri | Should -Not -BeNullOrEmpty
        $remoteUri.Uri.LocalPath | Should -Be ([System.IO.Path]::GetFullPath($remote))
        $remoteSource = 'git::' + $remoteUri.Uri.AbsoluteUri
        $main = $provider + @"

provider "azure" {
  alias = "east"
  features {}
  skip_provider_registration = "invalid-boolean"
  use_cli = false
  use_msi = false
  use_oidc = false
}
provider "azapi" {
  skip_provider_registration = "invalid-boolean"
  use_cli = false
  use_msi = false
  use_oidc = false
}
resource "azurerm_resource_group" "aliased" {
  provider = azure.east
  name = "not-deployed-aliased"
  location = "westus2"
}
resource "azapi_resource" "example" {
  type = "Microsoft.Resources/resourceGroups@2024-03-01"
  name = "not-deployed-azapi"
  location = "westus2"
  parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
  body = {}
}
module "local" {
  source = "./local"
  providers = { azapi = azapi }
}
module "downloaded" {
  source = "$remoteSource"
}
"@
        Set-Content -LiteralPath (Join-Path $source 'main.tf') -Value $main.ReplaceLineEndings("`n") -Encoding utf8NoBOM
        @'
provider "azure" {
  alias = "hash"
  features {}
  skip_provider_registration = "invalid-boolean"
  use_cli = false
  use_msi = false
  use_oidc = false
}
resource "azurerm_resource_group" "hash" {
  provider = azure.hash
  name = "not-deployed-hash"
  location = "westus2"
}
'@ | Set-Content -LiteralPath (Join-Path $source '#provider.tf') -Encoding utf8NoBOM
        @'
terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
      version = "2.13.0"
    }
  }
}
provider "azapi" {}
'@ | Set-Content -LiteralPath (Join-Path $local 'main.tf') -Encoding utf8NoBOM
        $authoredSettings = @{ skip_provider_registration = $false }
        if ($Mode -eq 'modern') {
            $authoredSettings.resource_provider_registrations = 'all'
            $authoredSettings.resource_providers_to_register = @('Microsoft.Test')
        }
        @{ provider = @{ azure = $authoredSettings } } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $source 'zz_override.tf.json') -Encoding utf8NoBOM
        $before = @(Get-ChildItem -LiteralPath $source -File -Recurse | Get-FileHash | Select-Object Path, Hash)

        $probe = InModuleScope Avm.Authoring -Parameters @{
            FixtureSource = $source; FixtureWorking = $working; FixtureStage = $stage
            Terraform = $script:tools.Terraform.Path; Conftest = $script:tools.Conftest.Path; ProviderCache = $script:providerCache
        } {
            param($FixtureSource, $FixtureWorking, $FixtureStage, $Terraform, $Conftest, $ProviderCache)
            Copy-AvmTerraformModuleTree -SourceRoot $FixtureSource -DestinationRoot $FixtureWorking
            $isolated = @{ TF_PLUGIN_CACHE_DIR = $ProviderCache }
            foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -match '^(ARM_|AZURE_|TF_CLI_ARGS)' }) {
                $isolated[$item.Name] = $null
            }
            $isolated.ARM_USE_CLI = 'false'
            $isolated.ARM_USE_MSI = 'false'
            $isolated.ARM_USE_OIDC = 'false'
            $environment = Get-AvmTerraformPolicyEnvironment -StageRoot $FixtureStage -Environment $isolated
            $null = Invoke-AvmTerraformInit -TerraformPath $Terraform -WorkingDirectory $FixtureWorking -EnvVars $environment -NoColor
            $negative = Invoke-AvmProcess -FilePath $Terraform -ArgumentList @('validate', '-json') `
                -WorkingDirectory $FixtureWorking -EnvVars $environment -IgnoreExitCode
            $negative.ExitCode | Should -Not -Be 0

            Initialize-AvmTerraformPolicyStage -WorkingDirectory $FixtureWorking -StageRoot $FixtureStage `
                -TerraformPath $Terraform -ConftestPath $Conftest -EnvVars $environment
            $manifest = Get-Content -LiteralPath (Join-Path $environment.TF_DATA_DIR 'modules' 'modules.json') -Raw
            $installed = @(ConvertFrom-AvmTerraformModuleManifest -Payload $manifest -WorkingDirectory $FixtureWorking)
            [pscustomobject]@{ Environment = $environment; Installed = $installed }
        }

        $probe.Environment.ARM_SKIP_PROVIDER_REGISTRATION | Should -Be 'true'
        $probe.Environment.ARM_RESOURCE_PROVIDER_REGISTRATIONS | Should -Be 'legacy'
        $rootGuard = Get-Content -LiteralPath (Join-Path $working 'zz_override.tf.json.avm_override.tf.json') -Raw | ConvertFrom-Json -AsHashtable
        $rootGuard.provider.azure | Should -HaveCount 3
        $rootGuard.provider.azapi[0].skip_provider_registration | Should -BeTrue
        foreach ($configuration in $rootGuard.provider.azure) {
            if ($Mode -eq 'modern') {
                $configuration.resource_provider_registrations | Should -Be 'none'
                $configuration.resource_providers_to_register | Should -HaveCount 0
                $configuration.skip_provider_registration | Should -BeFalse
            }
            else {
                $configuration.skip_provider_registration | Should -BeTrue
            }
        }
        @(Get-ChildItem -LiteralPath (Join-Path $working 'local') -Filter '*_override.tf.json').Count | Should -Be 0
        $downloaded = @($probe.Installed | Where-Object { $_ -like '*modules*downloaded' })
        $downloaded | Should -HaveCount 1
        Test-Path -LiteralPath (Join-Path $downloaded[0] 'avm_provider_safety_override.tf.json') | Should -BeTrue
        $after = @(Get-ChildItem -LiteralPath $source -File -Recurse | Get-FileHash | Select-Object Path, Hash)
        Compare-Object $before $after -Property Path, Hash | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $working 'tfplan') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $remote -Filter '*_override.tf.json').Count | Should -Be 0
    }
}
