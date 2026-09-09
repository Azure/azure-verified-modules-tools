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

Describe 'Test-AvmTerraformReadDeferred' {
    It 'reports a deferred read for resource, module and data references' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmTerraformReadDeferred -Body 'resource_id = azapi_resource.storage_account.id' |
                Should -BeTrue
            Test-AvmTerraformReadDeferred -Body 'key_vault_id = module.key_vault.resource_id' |
                Should -BeTrue
            Test-AvmTerraformReadDeferred -Body 'parent_id = data.azurerm_resource_group.rg.id' |
                Should -BeTrue
            Test-AvmTerraformReadDeferred -Body "  depends_on = [azurerm_network_watcher.this]" |
                Should -BeTrue
        }
    }

    It 'does not report a deferred read for known values' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmTerraformReadDeferred -Body 'name = var.resource_group_name' | Should -BeFalse
            Test-AvmTerraformReadDeferred -Body 'name = local.watcher_name' | Should -BeFalse
            Test-AvmTerraformReadDeferred -Body 'client_id = "f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875"' |
                Should -BeFalse
            Test-AvmTerraformReadDeferred -Body '' | Should -BeFalse
        }
    }

    It 'does not mistake each, self or count for a resource reference' {
        InModuleScope 'Avm.Authoring' {
            Test-AvmTerraformReadDeferred -Body 'name = each.value.name' | Should -BeFalse
            Test-AvmTerraformReadDeferred -Body 'name = count.index.name' | Should -BeFalse
        }
    }
}

Describe 'Get-AvmTerraformBlockBody' {
    It 'returns the body of a block, including nested braces' {
        $body = InModuleScope 'Avm.Authoring' {
            $source = 'data "x" "y" {' + "`n" + '  a = { b = 1 }' + "`n" + '}' + "`n" + 'trailing'
            Get-AvmTerraformBlockBody -Content $source -OpenBraceIndex $source.IndexOf('{')
        }

        $body | Should -Match 'a = \{ b = 1 \}'
        $body | Should -Not -Match 'trailing'
    }

    It 'ignores braces inside string literals' {
        $body = InModuleScope 'Avm.Authoring' {
            $source = 'data "x" "y" {' + "`n" + '  a = "not } a brace"' + "`n" + '}'
            Get-AvmTerraformBlockBody -Content $source -OpenBraceIndex $source.IndexOf('{')
        }

        $body | Should -Match 'not \} a brace'
    }

    It 'returns empty for an unterminated block' {
        $body = InModuleScope 'Avm.Authoring' {
            Get-AvmTerraformBlockBody -Content 'data "x" "y" {' -OpenBraceIndex 13
        }

        $body | Should -BeNullOrEmpty
    }
}

Describe 'Get-AvmTerraformCredentialledDataSource' {
    It 'reports data sources that read existing Azure resources' {        $path = New-TerraformFixture -Content @'
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

    It 'ignores data sources whose read is deferred to apply' {
        # Verified against Terraform 1.15: a data source whose arguments come
        # from a resource in the same configuration renders "will be read
        # during apply" and never executes during the plan, so it is not a
        # credential blocker.
        $path = New-TerraformFixture -Content @'
data "azapi_resource_action" "keys" {
  action      = "listKeys"
  resource_id = azapi_resource.storage_account.id
  type        = "Microsoft.Storage/storageAccounts@2025-01-01"
}

data "azurerm_key_vault_secret" "sql" {
  key_vault_id = module.key_vault.resource_id
  name         = var.secret_name
}

data "azapi_resource" "customlocation" {
  name      = var.custom_location_name
  parent_id = data.azurerm_resource_group.existing.id
  type      = "Microsoft.ExtendedLocation/customLocations@2021-08-15"
}

data "azurerm_network_watcher" "this" {
  name                = local.network_watcher_name
  resource_group_name = local.network_watcher_resource_group_name

  depends_on = [azurerm_network_watcher.this]
}
'@

        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 0
    }

    It 'still reports a deferred-looking type when every argument is known' {
        # Same type as the deferred case above, but nothing defers the read,
        # so this one does execute during plan.
        $path = New-TerraformFixture -Content @'
data "azapi_resource" "customlocation" {
  name      = var.custom_location_name
  parent_id = "/subscriptions/0000/resourceGroups/rg"
  type      = "Microsoft.ExtendedLocation/customLocations@2021-08-15"
}
'@

        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 1
        $found[0].DataSourceAddress | Should -Be 'data.azapi_resource.customlocation'
    }

    It 'treats variables and locals as known at plan time' {
        $path = New-TerraformFixture -Content @'
data "azurerm_resource_group" "existing" {
  name = var.resource_group_name
}

data "azurerm_key_vault" "existing" {
  name                = local.key_vault_name
  resource_group_name = var.resource_group_name
}
'@

        $found = InModuleScope 'Avm.Authoring' -Parameters @{ P = $path } {
            param($P)
            @(Get-AvmTerraformCredentialledDataSource -Path $P)
        }

        @($found).Count | Should -Be 2
    }

    It 'ignores azuread_application_published_app_ids, which calls no API' {
        # The provider returns a static map compiled into the binary.
        $path = New-TerraformFixture -Content @'
data "azuread_application_published_app_ids" "well_known" {}
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
