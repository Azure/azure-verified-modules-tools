#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmTerraformMissingModuleFile' {
    It 'reports nothing for a complete module' {
        $root = @(
            @{ path = 'terraform.tf'; type = 'blob'; size = 20 }
            @{ path = '_header.md'; type = 'blob'; size = 5 }
            @{ path = 'examples'; type = 'tree' }
            @{ path = 'tests'; type = 'tree' }
        )
        $examples = @(@{ path = 'README.md'; type = 'blob'; size = 5 }, @{ path = 'default'; type = 'tree' })
        $missing = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root; Examples = $examples } {
            param($Root, $Examples)
            @(Get-AvmTerraformMissingModuleFile -Root $Root -Examples $Examples) -join ','
        }
        $missing | Should -BeExactly ''
    }

    It 'reports <Case>' -TestCases @(
        @{
            Case     = 'every missing item for a metadata-only main'
            Root     = @(@{ path = 'metadata.json'; type = 'blob'; size = 5 }, @{ path = 'README.md'; type = 'blob'; size = 5 })
            Examples = @()
            Expected = 'terraform.tf,_header.md,examples/<name>/,tests/'
        }
        @{
            Case     = 'an empty terraform.tf and an examples folder without examples'
            Root     = @(
                @{ path = 'terraform.tf'; type = 'blob'; size = 0 }
                @{ path = '_header.md'; type = 'blob'; size = 5 }
                @{ path = 'tests'; type = 'tree' }
            )
            Examples = @(@{ path = 'README.md'; type = 'blob'; size = 5 })
            Expected = 'terraform.tf,examples/<name>/'
        }
        @{
            Case     = 'names that are the wrong kind of entry'
            Root     = @(
                @{ path = 'terraform.tf'; type = 'tree' }
                @{ path = '_header.md'; type = 'tree' }
                @{ path = 'tests'; type = 'blob'; size = 5 }
            )
            Examples = @()
            Expected = 'terraform.tf,_header.md,examples/<name>/,tests/'
        }
    ) {
        param($Case, $Root, $Examples, $Expected)
        $missing = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $Root; Examples = $Examples } {
            param($Root, $Examples)
            @(Get-AvmTerraformMissingModuleFile -Root $Root -Examples $Examples) -join ','
        }
        $missing | Should -BeExactly $Expected
    }
}