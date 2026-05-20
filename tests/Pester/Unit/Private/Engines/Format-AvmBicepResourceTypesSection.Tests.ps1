#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Format-AvmBicepResourceTypesSection' {
    It 'returns _None_ for an ARM template with no resources' {
        $arm = [pscustomobject]@{ resources = @() }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepResourceTypesSection -Arm $A
        }
        $result | Should -Be @('_None_')
    }

    It 'returns _None_ when the only resource is in the default exclude list' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.Resources/deployments'; apiVersion = '2022-09-01' }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepResourceTypesSection -Arm $A
        }
        $result | Should -Be @('_None_')
    }

    It 'renders a 3-column table with AzAdvertizer and Template reference links' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2024-04-01-preview' }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepResourceTypesSection -Arm $A
        }
        $result[0]    | Should -Be '| Resource Type | API Version | References |'
        $result[1]    | Should -Be '| :-- | :-- | :-- |'
        $result.Count | Should -Be 3
        $result[2]    | Should -Match '\| `Microsoft\.KeyVault/vaults` \| 2024-04-01-preview \|'
        $result[2]    | Should -Match 'https://www\.azadvertizer\.net/azresourcetypes/microsoft\.keyvault_vaults\.html'
        $result[2]    | Should -Match 'https://learn\.microsoft\.com/en-us/azure/templates/Microsoft\.KeyVault/2024-04-01-preview/vaults'
        $result[2]    | Should -Match '<ul style="padding-left: 0px;">'
        $result[2]    | Should -Match '<li>\[AzAdvertizer\]\('
        $result[2]    | Should -Match '<li>\[Template reference\]\('
    }

    It 'sorts rows by Type with en-US culture' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2024-01-01' },
                [pscustomobject]@{ type = 'Microsoft.Authorization/roleAssignments'; apiVersion = '2022-04-01' },
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2024-04-01-preview' }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepResourceTypesSection -Arm $A
        }
        $result[2] | Should -Match '`Microsoft\.Authorization/roleAssignments`'
        $result[3] | Should -Match '`Microsoft\.KeyVault/vaults`'
        $result[4] | Should -Match '`Microsoft\.Storage/storageAccounts`'
    }

    It 'de-duplicates on (Type, ApiVersion) pairs but keeps the same type at two API versions' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2024-04-01-preview' },
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2024-04-01-preview' },
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2023-07-01' }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepResourceTypesSection -Arm $A
        }
        # 2 header rows + 2 data rows (one per distinct API version).
        $result.Count | Should -Be 4
        ($result[2..3] -join "`n") | Should -Match '2023-07-01'
        ($result[2..3] -join "`n") | Should -Match '2024-04-01-preview'
    }

    It 'excludes Microsoft.Resources/deployments by default but keeps nested children' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{
                    type       = 'Microsoft.Resources/deployments'
                    apiVersion = '2022-09-01'
                    properties = [pscustomobject]@{
                        template = [pscustomobject]@{
                            resources = @(
                                [pscustomobject]@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2024-01-01' }
                            )
                        }
                    }
                }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepResourceTypesSection -Arm $A
        }
        $body = $result -join "`n"
        $body | Should -Not -Match 'Microsoft\.Resources/deployments'
        $body | Should -Match     '`Microsoft\.Storage/storageAccounts`'
    }

    It 'honours a custom -ExcludeTypes list' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.Authorization/locks'; apiVersion = '2020-05-01' },
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2024-04-01-preview' }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepResourceTypesSection -Arm $A -ExcludeTypes @('Microsoft.Authorization/locks')
        }
        $body = $result -join "`n"
        $body | Should -Not -Match 'Microsoft\.Authorization/locks'
        $body | Should -Match     '`Microsoft\.KeyVault/vaults`'
    }

    It 'preserves namespace casing in the Template reference URL and lowercases the AzAdvertizer slug' {
        $arm = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.ApiManagement/service/portalsettings'; apiVersion = '2024-05-01' }
            )
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $arm } {
            param($A)
            Format-AvmBicepResourceTypesSection -Arm $A
        }
        $result[2] | Should -Match 'https://learn\.microsoft\.com/en-us/azure/templates/Microsoft\.ApiManagement/2024-05-01/service/portalsettings'
        $result[2] | Should -Match 'https://www\.azadvertizer\.net/azresourcetypes/microsoft\.apimanagement_service_portalsettings\.html'
    }
}
