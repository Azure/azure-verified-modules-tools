#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: Bicep existing-resource references' -Tag Integration -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'compiles existing Graph and Key Vault references and documents no deployed resources' {
        # Registry modules now forward an existing Graph service principal's id
        # instead of taking its object ID as a parameter. The compiled template
        # is symbolic (languageVersion 2.0) and its resources are a dictionary.
        $root = Join-Path $TestDrive 'graph-existing'
        $null = New-Item -ItemType Directory -Path $root -Force
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $root 'bicepconfig.json'), @'
{
  "extensions": {
    "microsoftGraphV1": "br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0"
  }
}
'@, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $root 'main.bicep'), @'
targetScope = 'subscription'

extension microsoftGraphV1

param vaultName string
param vaultResourceGroupName string

resource backupManagementService 'Microsoft.Graph/servicePrincipals@v1.0' existing = {
  appId: '262044b1-e2ce-469f-a196-69ab7ada62d3'
}

resource vault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  scope: resourceGroup(vaultResourceGroupName)
  name: vaultName
}

module forward './dependency.bicep' = {
  name: 'existing-reference-consumer'
  params: {
    principalId: backupManagementService.id
    vaultId: vault.id
  }
}
'@, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $root 'dependency.bicep'), @'
targetScope = 'subscription'

param principalId string
param vaultId string

output observedPrincipalId string = principalId
output observedVaultId string = vaultId
'@, $utf8)

        $compiled = InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            $tool = Resolve-AvmTool -Name bicep
            Get-AvmBicepCompiledJson -SourcePath (Join-Path $Root 'main.bicep') -ToolPath $tool.Path
        }
        $template = $compiled | ConvertFrom-Json -AsHashtable -Depth 100

        $template['languageVersion'] | Should -BeExactly '2.0'
        $template['resources'] | Should -BeOfType ([System.Collections.IDictionary])
        $template['parameters'].Keys | Should -Be @('vaultName', 'vaultResourceGroupName')
        $graph = @($template['resources'].Values | Where-Object { $_['type'] -like '*Graph/servicePrincipals*' })
        $graph.Count | Should -Be 1
        $graph[0]['existing'] | Should -BeTrue
        $vault = @($template['resources'].Values | Where-Object { $_['type'] -eq 'Microsoft.KeyVault/vaults' })
        $vault[0]['apiVersion'] | Should -BeExactly '2026-02-01'
        $vault[0]['existing'] | Should -BeTrue

        $documented = InModuleScope Avm.Authoring -Parameters @{ Template = $template } {
            param($Template)
            @(Get-AvmBicepDocsResourceType -Template $Template)
        }
        $documented.Count | Should -Be 0
    }
}
