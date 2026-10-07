#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: Bicep existing-resource references' -Tag Integration -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $script:fixtureRoot = Join-Path $repoRoot 'tests' 'fixtures' 'modules' 'bicep-existing-references'
        Import-Module (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'compiles existing Graph and Key Vault references and documents no deployed resources' {
        $root = Join-Path $TestDrive 'graph-existing'
        Copy-Item -LiteralPath $script:fixtureRoot -Destination $root -Recurse

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

        $documented = @(InModuleScope Avm.Authoring -Parameters @{ Template = $template } {
            param($Template)
            Get-AvmBicepDocsResourceType -Template $Template
        })
        $documented.Count | Should -Be 0
    }
}
