#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Coverage for the detector that decides whether an example can be planned
# with the synthetic credential. A false negative here surfaces as a raw
# provider authentication error deep inside terraform plan, and a false
# positive skips policy coverage the contributor could have had, so both
# directions are asserted.

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function New-TerraformFixture {
        param([string] $Content)
        $path = Join-Path $TestDrive ('tf-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $path -Force
        [System.IO.File]::WriteAllText(
            (Join-Path $path 'main.tf'),
            $Content,
            [System.Text.UTF8Encoding]::new($false))
        return $path
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Remove-AvmHclComment' {
    It 'blanks line, block, and heredoc content without moving any offset' {
        $probe = InModuleScope 'Avm.Authoring' {
            $source = @'
# data "azurerm_key_vault" "hash" {}
// data "azurerm_key_vault" "slash" {}
/* data "azurerm_key_vault" "block" {} */
resource "azapi_resource" "keep" {
  body = <<-EOT
    data "azurerm_key_vault" "heredoc" {}
  EOT
}
data "azurerm_key_vault" "real" {}
'@
            $stripped = Remove-AvmHclComment -Content $source
            [pscustomobject]@{
                SameLength = $stripped.Length -eq $source.Length
                SameLines  = ($stripped -split "`n").Count -eq ($source -split "`n").Count
                Stripped   = $stripped
            }
        }

        # Offsets and line numbers must survive so callers can report them.
        $probe.SameLength | Should -BeTrue
        $probe.SameLines | Should -BeTrue
        $probe.Stripped | Should -Not -Match 'hash'
        $probe.Stripped | Should -Not -Match 'slash'
        $probe.Stripped | Should -Not -Match 'block'
        $probe.Stripped | Should -Not -Match 'heredoc'
        $probe.Stripped | Should -Match '"real"'
        $probe.Stripped | Should -Match 'resource "azapi_resource" "keep"'
    }

    It 'tolerates an unterminated comment or heredoc' {
        {
            InModuleScope 'Avm.Authoring' {
                $null = Remove-AvmHclComment -Content "/* never closed"
                $null = Remove-AvmHclComment -Content "body = <<-EOT`n  no terminator"
                $null = Remove-AvmHclComment -Content ''
            }
        } | Should -Not -Throw
    }
}

Describe 'Get-AvmTerraformCredentialledDataSource' {
    It 'reports data sources that read existing Azure resources' {
        $path = New-TerraformFixture -Content @'
data "azurerm_resource_group" "existing" {
  name = "rg-existing"
}

data "azapi_resource_action" "keys" {
  action = "listKeys"
}

data "azuread_service_principal" "spn" {
  client_id = "f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875"
}
'@

        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 3
        $found.DataSourceAddress | Should -Contain 'data.azurerm_resource_group.existing'
        $found.DataSourceAddress | Should -Contain 'data.azapi_resource_action.keys'
        $found.DataSourceAddress | Should -Contain 'data.azuread_service_principal.spn'
    }

    It 'ignores data sources that resolve locally' {
        # These come from the token claims or are pure parsers, so they work
        # against the synthetic credential and must not cost an example its
        # policy coverage.
        $path = New-TerraformFixture -Content @'
data "azurerm_client_config" "current" {}
data "azapi_client_config" "current" {}
data "azapi_resource_id" "parsed" {
  type = "Microsoft.Storage/storageAccounts@2023-01-01"
}
data "random_id" "suffix" {
  byte_length = 4
}
data "local_file" "config" {
  filename = "config.json"
}
'@

        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 0
    }

    It 'ignores commented-out declarations' {
        # AVM examples routinely leave alternatives commented out; treating
        # those as blockers would skip coverage for no reason.
        $path = New-TerraformFixture -Content @'
# data "azurerm_key_vault" "hash" {
#   name = "kv"
# }

// data "azurerm_subscription" "slash" {}

/*
data "azapi_resource" "block" {
  type = "Microsoft.Storage/storageAccounts@2023-01-01"
}
*/
'@

        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 0
    }

    It 'ignores declarations embedded in a heredoc' {
        $path = New-TerraformFixture -Content @'
resource "azapi_resource" "policy" {
  type = "Microsoft.Authorization/policyDefinitions@2021-06-01"
  body = <<-EOT
    data "azurerm_key_vault" "inside" {
      name = "not-real"
    }
  EOT
}
'@

        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 0
    }

    It 'does not confuse a managed resource with a data source' {
        $path = New-TerraformFixture -Content @'
resource "azurerm_resource_group" "this" {
  location = "eastus"
  name     = "rg"
}
'@

        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 0
    }

    It 'treats an unknown Azure data source as needing a credential' {
        # Failing closed keeps the failure mode a clear message instead of a
        # provider authentication error from inside terraform plan.
        $path = New-TerraformFixture -Content @'
data "azurerm_some_future_type" "this" {
  name = "whatever"
}
'@

        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 1
        $found[0].Type | Should -Be 'azurerm_some_future_type'
    }

    It 'returns nothing for a directory that does not exist' {
        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = (Join-Path $TestDrive 'missing') } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 0
    }
}
