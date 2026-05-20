#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmBicepDocs' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ('bicep-docs-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        $script:templatePath = Join-Path $script:moduleDir 'main.bicep'
        Set-Content -LiteralPath $script:templatePath -Value "param x string`noutput x string = x" -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind = 'bicep-module'; Root = $script:moduleDir; Ecosystem = 'bicep'; Source = 'path-heuristic'
        }

        # Minimal ARM JSON returned by the mocked Convert-AvmBicepToArm.
        $script:armWithOutputs = [pscustomobject]@{
            resources = @(
                [pscustomobject]@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2024-04-01-preview' }
            )
            outputs   = [pscustomobject]@{
                x = [pscustomobject]@{ type = 'string'; value = "[parameters('x')]" }
            }
        }
        $script:armNoOutputs = [pscustomobject]@{ resources = @() }
    }

    It 'rejects a non-bicep context' {
        $tfCtx = [pscustomobject][ordered]@{
            Kind = 'terraform-module-repo'; Root = $script:moduleDir; Ecosystem = 'terraform'; Source = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $tfCtx } {
                param($C)
                Invoke-AvmBicepDocs -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'throws AvmConfigurationException when main.bicep is missing' {
        Remove-Item -LiteralPath $script:templatePath -Force
        $ctx = $script:context
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Invoke-AvmBicepDocs -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                 | Should -Not -BeNullOrEmpty
        $err.GetType().Name  | Should -Be 'AvmConfigurationException'
        $err.Message         | Should -Match 'not found'
    }

    It 'creates a README skeleton when none exists and injects an Outputs section' {
        $ctx = $script:context
        $arm = $script:armWithOutputs
        $compiled = [pscustomobject]@{
            ToolName = 'bicep'; ToolVersion = '0.30.3'; ToolPath = '/fake/bicep'; ToolSource = 'cache'; Arm = $arm
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $compiled } {
            param($C, $R)
            Mock Convert-AvmBicepToArm { $R }
            Invoke-AvmBicepDocs -Context $C
        }

        $result.Engine         | Should -Be 'bicep'
        $result.Tool           | Should -Be 'bicep/0.30.3'
        $result.ToolPath       | Should -Be '/fake/bicep'
        $result.ToolSource     | Should -Be 'cache'
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 1
        $result.Changed        | Should -Be @('README.md')

        $readmePath = Join-Path $script:moduleDir 'README.md'
        Test-Path -LiteralPath $readmePath | Should -BeTrue
        $content = Get-Content -LiteralPath $readmePath -Raw
        $content | Should -Match '^# '
        $content | Should -Match '## Resource Types'
        $content | Should -Match '`Microsoft\.KeyVault/vaults`'
        $content | Should -Match '## Outputs'
        $content | Should -Match '\| `x` \| string \|'
        # Resource Types must come before Outputs to match the legacy README layout.
        $rtIdx  = $content.IndexOf('## Resource Types')
        $outIdx = $content.IndexOf('## Outputs')
        $rtIdx | Should -BeGreaterThan -1
        $outIdx | Should -BeGreaterThan $rtIdx
    }

    It 'emits _None_ for templates with no outputs' {
        $ctx = $script:context
        $arm = $script:armNoOutputs
        $compiled = [pscustomobject]@{
            ToolName = 'bicep'; ToolVersion = '0.30.3'; ToolPath = '/fake/bicep'; ToolSource = 'cache'; Arm = $arm
        }

        $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $compiled } {
            param($C, $R)
            Mock Convert-AvmBicepToArm { $R }
            Invoke-AvmBicepDocs -Context $C
        }

        $content = Get-Content -LiteralPath (Join-Path $script:moduleDir 'README.md') -Raw
        $content | Should -Match '## Resource Types'
        $content | Should -Match '## Outputs'
        # Both sections should report _None_ when the ARM has no resources and no outputs.
        ($content -split '## Resource Types', 2)[1] | Should -Match '_None_'
        ($content -split '## Outputs', 2)[1]        | Should -Match '_None_'
    }

    It 'replaces an existing Outputs section without disturbing later content' {
        $readmePath = Join-Path $script:moduleDir 'README.md'
        Set-Content -LiteralPath $readmePath -Value @(
            '# my-module', '', '## Outputs', '', '| Output | Type |', '| :-- | :-- |',
            '| `old` | int |', '', '## Notes', '', 'Keep me intact.'
        ) -Encoding utf8

        $ctx = $script:context
        $arm = $script:armWithOutputs
        $compiled = [pscustomobject]@{
            ToolName = 'bicep'; ToolVersion = '0.30.3'; ToolPath = '/fake/bicep'; ToolSource = 'cache'; Arm = $arm
        }

        $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $compiled } {
            param($C, $R)
            Mock Convert-AvmBicepToArm { $R }
            Invoke-AvmBicepDocs -Context $C
        }

        $content = Get-Content -LiteralPath $readmePath -Raw
        $content | Should -Match '\| `x` \| string \|'
        $content | Should -Not -Match '`old`'
        $content | Should -Match '## Notes'
        $content | Should -Match 'Keep me intact\.'
    }

    It 'is idempotent (second run reports Changed=@())' {
        $ctx = $script:context
        $arm = $script:armWithOutputs
        $compiled = [pscustomobject]@{
            ToolName = 'bicep'; ToolVersion = '0.30.3'; ToolPath = '/fake/bicep'; ToolSource = 'cache'; Arm = $arm
        }

        $first = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $compiled } {
            param($C, $R)
            Mock Convert-AvmBicepToArm { $R }
            Invoke-AvmBicepDocs -Context $C
        }
        $second = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $compiled } {
            param($C, $R)
            Mock Convert-AvmBicepToArm { $R }
            Invoke-AvmBicepDocs -Context $C
        }

        $first.Changed  | Should -Be @('README.md')
        $second.Changed | Should -BeNullOrEmpty
    }

    It 'forwards -AllowPathFallback to Convert-AvmBicepToArm' {
        $ctx = $script:context
        $arm = $script:armWithOutputs
        $compiled = [pscustomobject]@{
            ToolName = 'bicep'; ToolVersion = '0.30.3'; ToolPath = '/fake/bicep'; ToolSource = 'path'; Arm = $arm
        }

        $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $compiled } {
            param($C, $R)
            Mock Convert-AvmBicepToArm { $R } -ParameterFilter { $AllowPathFallback -eq $true }
            Invoke-AvmBicepDocs -Context $C -AllowPathFallback
            Should -Invoke Convert-AvmBicepToArm -Exactly 1 -ParameterFilter { $AllowPathFallback -eq $true }
        }
    }

    It 'honours a custom -TemplateFile / -OutputFile pair' {
        $altTemplate = Join-Path $script:moduleDir 'alt.bicep'
        Set-Content -LiteralPath $altTemplate -Value "output y string = 'y'" -Encoding utf8

        $ctx = $script:context
        $arm = $script:armWithOutputs
        $compiled = [pscustomobject]@{
            ToolName = 'bicep'; ToolVersion = '0.30.3'; ToolPath = '/fake/bicep'; ToolSource = 'cache'; Arm = $arm
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $compiled } {
            param($C, $R)
            Mock Convert-AvmBicepToArm { $R }
            Invoke-AvmBicepDocs -Context $C -TemplateFile 'alt.bicep' -OutputFile 'NOTES.md'
        }
        $result.Changed | Should -Be @('NOTES.md')
        Test-Path -LiteralPath (Join-Path $script:moduleDir 'NOTES.md') | Should -BeTrue
    }

    It 'replaces an existing Resource Types section without disturbing Outputs or trailing sections' {
        $readmePath = Join-Path $script:moduleDir 'README.md'
        Set-Content -LiteralPath $readmePath -Value @(
            '# my-module', '',
            '## Resource Types', '',
            '| Resource Type | API Version | References |',
            '| :-- | :-- | :-- |',
            '| `Microsoft.Old/thing` | 2020-01-01 | x |', '',
            '## Outputs', '',
            '| Output | Type |',
            '| :-- | :-- |',
            '| `old` | int |', '',
            '## Notes', '', 'Keep me intact.'
        ) -Encoding utf8

        $ctx = $script:context
        $arm = $script:armWithOutputs
        $compiled = [pscustomobject]@{
            ToolName = 'bicep'; ToolVersion = '0.30.3'; ToolPath = '/fake/bicep'; ToolSource = 'cache'; Arm = $arm
        }

        $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; R = $compiled } {
            param($C, $R)
            Mock Convert-AvmBicepToArm { $R }
            Invoke-AvmBicepDocs -Context $C
        }

        $content = Get-Content -LiteralPath $readmePath -Raw
        $content | Should -Not -Match 'Microsoft\.Old/thing'
        $content | Should -Match     '`Microsoft\.KeyVault/vaults`'
        $content | Should -Match     '## Outputs'
        $content | Should -Match     '\| `x` \| string \|'
        $content | Should -Not -Match '`old`'
        $content | Should -Match     '## Notes'
        $content | Should -Match     'Keep me intact\.'
    }
}
