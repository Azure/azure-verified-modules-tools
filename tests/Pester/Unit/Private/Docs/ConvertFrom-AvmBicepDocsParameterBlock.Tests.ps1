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
    It 'renders formatted ternaries exactly like their single-line equivalents' {
        $singleLine = @'
  name: 'example'
  customLocationResourceId: preparedHciEnvironment != null ? preparedHciEnvironment.customLocationResourceId : customLocation!.id
  vmSwitchName: preparedHciEnvironment != null ? preparedHciEnvironment.vSwitchName : azlocal!.outputs.vSwitchName
  enabled: true
'@
        $multiline = @'
  name: 'example'
  customLocationResourceId: preparedHciEnvironment != null
    ? preparedHciEnvironment.customLocationResourceId
    : customLocation!.id
  vmSwitchName: preparedHciEnvironment != null
    ? preparedHciEnvironment.vSwitchName
    : azlocal!.outputs.vSwitchName
  enabled: true
'@
        InModuleScope 'Avm.Authoring' -Parameters @{ S = $singleLine; M = $multiline } {
            param($S, $M)
            $expected = ConvertFrom-AvmBicepDocsParameterBlock -Block $S -SourcePath 'single.bicep'
            $actual = ConvertFrom-AvmBicepDocsParameterBlock -Block $M -SourcePath 'formatted.bicep'
            $actual.Count | Should -Be 4
            $actual.customLocationResourceId.value | Should -BeExactly '<customLocationResourceId>'
            $actual.vmSwitchName.value | Should -BeExactly '<vmSwitchName>'
            $actual.name.value | Should -BeExactly 'example'
            $actual.enabled.value | Should -BeTrue
            $expectedExamples = ConvertTo-AvmBicepDocsExampleParameter -Parameters $expected
            $actualExamples = ConvertTo-AvmBicepDocsExampleParameter -Parameters $actual
            foreach ($format in @('BicepParameters', 'JsonParameters', 'BicepParameterFile')) {
                $actualExamples.$format | Should -BeExactly $expectedExamples.$format
            }
        }
    }

    It 'keeps nested conditional branches and comments inside their property boundary' {
        $block = @'
  settings: {
    network: preparedHciEnvironment != null // choose prepared dependencies
      // The branches contain nested objects, arrays, functions, and conditionals.
      ? {
          routes: [
            {
              name: 'https://example.test/a?b:c' // punctuation is not a branch delimiter
              enabled: true
            }
          ]
        }
      /* otherwise */
      : fallbackEnabled
        ? union(
            {
              name: 'fallback'
            },
            {}
          )
        : {}
    label: 'Keep ?: and https://example.test/foo'
    resourceIds: [
      nestedDependencies.outputs.resourceId // Keep reference comment
    ]
  }
  location: 'eastus'
'@
        $parameters = InModuleScope 'Avm.Authoring' -Parameters @{ B = $block } {
            param($B)
            ConvertFrom-AvmBicepDocsParameterBlock -Block $B -SourcePath 'nested.bicep'
        }
        $parameters.Count | Should -Be 2
        $parameters.settings.value.Count | Should -Be 3
        $parameters.settings.value.network | Should -BeExactly '<network>'
        $parameters.settings.value.label | Should -BeExactly 'Keep ?: and https://example.test/foo'
        $parameters.settings.value.resourceIds[0] |
            Should -BeExactly '<resourceId // Keep reference comment>'
        $parameters.location.value | Should -BeExactly 'eastus'
    }

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
