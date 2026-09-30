#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-AvmBicepDocsParameterBlock' {
    It 'replaces computed output references and multi-line functions with copy-ready placeholders' {
        $block = @'
  name: 'example'
  roleAssignments: [
    {
      roleDefinitionIdOrName: subscriptionResourceId(
        'Microsoft.Authorization/roleDefinitions',
        'acdd72a7-3385-48ef-bd42-f606fba81ae7'
      )
      principalId: identity.outputs.principalId
    }
  ]
'@
        $parameters = InModuleScope 'Avm.Authoring' -Parameters @{ B = $block } {
            param($B)
            ConvertFrom-AvmBicepDocsParameterBlock -Block $B -SourcePath 'synthetic/main.test.bicep'
        }
        $parameters.name.value | Should -BeExactly 'example'
        $parameters.roleAssignments.value[0].roleDefinitionIdOrName |
            Should -BeExactly '<roleDefinitionIdOrName>'
        $parameters.roleAssignments.value[0].principalId | Should -BeExactly '<principalId>'
    }

    It 'ignores Bicep comments without removing slashes from quoted values' {
        $block = @'
  name: 'https://example.test/foo' // module name
  backends: [
    {
      credentials: {
        authorization: {
          parameter: 'dXNlcm5hbWU6c2VjcmV0cGFzc3dvcmQ=' // encoded test value
          scheme: 'Basic'
        }
      }
    }
  ]
  enablePurgeProtection: false // Only for testing
  // Another test-only comment
'@
        $parameters = InModuleScope 'Avm.Authoring' -Parameters @{ B = $block } {
            param($B)
            ConvertFrom-AvmBicepDocsParameterBlock -Block $B -SourcePath 'synthetic/main.test.bicep'
        }
        $parameters.name.value | Should -BeExactly 'https://example.test/foo'
        $parameters.backends.value[0].credentials.authorization.parameter |
            Should -BeExactly 'dXNlcm5hbWU6c2VjcmV0cGFzc3dvcmQ='
        $parameters.enablePurgeProtection.value | Should -BeFalse
    }

    It 'detects parameter indentation after a leading comment' {
        $block = @'
  // You parameters go here
  name: 'hub'
  settings: {
    regions: [
      'eastus'
    ]
  }
'@
        $parameters = InModuleScope 'Avm.Authoring' -Parameters @{ B = $block } {
            param($B)
            ConvertFrom-AvmBicepDocsParameterBlock -Block $B -SourcePath 'synthetic/main.test.bicep'
        }
        $parameters.Count | Should -Be 2
        $parameters.name.value | Should -BeExactly 'hub'
        $parameters.settings.value.regions[0] | Should -BeExactly 'eastus'
    }

    It 'renders referenced test values as copy-ready placeholders in all three example formats' {
        $block = @'
  imageReference: {
    sku: sku
  }
'@
        $example = InModuleScope 'Avm.Authoring' -Parameters @{ B = $block } {
            param($B)
            $parameters = ConvertFrom-AvmBicepDocsParameterBlock `
                -Block $B -SourcePath 'synthetic/main.test.bicep'
            $parameters.imageReference.value.sku | Should -BeExactly '<sku>'
            ConvertTo-AvmBicepDocsExampleParameter -Parameters $parameters `
                -RequiredParameters @('imageReference')
        }
        $example.BicepParameters | Should -Match "sku: '<sku>'"
        $example.JsonParameters | Should -Match '"sku": "<sku>"'
        $example.BicepParameterFile | Should -Match "sku: '<sku>'"
    }

    It 'retains inline comments in bare dotted array-reference placeholders only' {
        $block = @'
  roleDefinitions: [
    nestedDependencies.outputs.roleDefinitionId // Custom role
    'https://example.test/foo' // literal URL comment
    // Whole-line comment
  ]
'@
        $example = InModuleScope 'Avm.Authoring' -Parameters @{ B = $block } {
            param($B)
            $parameters = ConvertFrom-AvmBicepDocsParameterBlock `
                -Block $B -SourcePath 'synthetic/main.test.bicep'
            $parameters.roleDefinitions.value[0] |
                Should -BeExactly '<roleDefinitionId // Custom role>'
            $parameters.roleDefinitions.value[1] |
                Should -BeExactly 'https://example.test/foo'
            ConvertTo-AvmBicepDocsExampleParameter -Parameters $parameters `
                -RequiredParameters @('roleDefinitions')
        }
        $example.BicepParameters | Should -Match "'<roleDefinitionId // Custom role>'"
        $example.JsonParameters | Should -Match '"<roleDefinitionId // Custom role>"'
        $example.BicepParameterFile | Should -Match "'<roleDefinitionId // Custom role>'"
    }
}
