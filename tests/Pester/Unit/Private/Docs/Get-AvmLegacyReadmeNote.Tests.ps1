#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmLegacyReadmeNote' {
    It 'returns null when an existing README has no top-level Notes' {
        InModuleScope 'Avm.Authoring' {
            $content = "# Module`n`n" + '```powershell' + "`n## Notes`n" +
            '```' + "`n## Data Collection"
            Get-AvmLegacyReadmeNote -Content $content | Should -BeNullOrEmpty
        }
    }

    It 'preserves the complete Notes body and reconstructs the original section with normalized newlines' {
        InModuleScope 'Avm.Authoring' {
            $body = "`n### Configuration`n`n" + '```powershell' +
            "`n## Data Collection`n" + '```' + "`n`n" + '~~~text' +
            "`n## Other heading`n" + '~~~' + "`n`nLast line.`n`n"
            $content = "# Module`r`n## Notes`r`n" +
            $body.ReplaceLineEndings("`r`n") + "## Data Collection`r`n"
            $notes = Get-AvmLegacyReadmeNote -Content $content
            $notes.Body | Should -BeExactly $body
            $normalized = $content.ReplaceLineEndings("`n")
            $normalized | Should -BeExactly ("# Module`n## Notes`n" + $notes.Body + "## Data Collection`n")
        }
    }

    It 'preserves large authored Notes without truncation or command-line length limits' {
        InModuleScope 'Avm.Authoring' {
            $body = "`n" + ("A long Note with Unicode: `u{03B1} and a fenced heading.`n" * 800)
            $content = "# Module`n## Notes`n$body" + "## Data Collection`n"
            $notes = Get-AvmLegacyReadmeNote -Content $content
            $notes.Body | Should -BeExactly $body
            [Text.Encoding]::UTF8.GetByteCount($notes.Body) | Should -BeGreaterThan 22000
        }
    }

    It 'does not treat an indented Notes heading or a longer heading as the module Notes section' {
        InModuleScope 'Avm.Authoring' {
            Get-AvmLegacyReadmeNote -Content "## Notes for maintainers`nBody`n" |
                Should -BeNullOrEmpty
            Get-AvmLegacyReadmeNote -Content "    ## Notes`nBody`n" |
                Should -BeNullOrEmpty
        }
    }
}
