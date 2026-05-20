#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Merge-AvmReadmeSection' {
    It 'appends the heading and body to an empty document' {
        $result = InModuleScope 'Avm.Authoring' {
            Merge-AvmReadmeSection -Content @() -Heading '## Outputs' -NewBody @('_None_')
        }
        $result -join "`n" | Should -Be "## Outputs`n`n_None_"
    }

    It 'appends the heading and body to a document that has no matching heading' {
        $existing = @('# my-module', '', 'Some description.')
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $existing } {
            param($E)
            Merge-AvmReadmeSection -Content $E -Heading '## Outputs' -NewBody @('| Output | Type |', '| :-- | :-- |', '| `x` | string |')
        }
        $joined = $result -join "`n"
        $joined | Should -Match '# my-module'
        $joined | Should -Match 'Some description\.'
        $joined | Should -Match '## Outputs'
        $joined | Should -Match '\| `x` \| string \|'
        $joined.IndexOf('Some description.') | Should -BeLessThan $joined.IndexOf('## Outputs')
    }

    It 'replaces the existing body when the heading is present and a next heading exists' {
        $existing = @(
            '# my-module',
            '',
            '## Outputs',
            '',
            '| Output | Type |',
            '| :-- | :-- |',
            '| `old` | string |',
            '',
            '## Notes',
            '',
            'Keep me intact.'
        )
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $existing } {
            param($E)
            Merge-AvmReadmeSection -Content $E -Heading '## Outputs' -NewBody @('| Output | Type |', '| :-- | :-- |', '| `new` | int |')
        }
        $joined = $result -join "`n"
        $joined | Should -Match '\| `new` \| int \|'
        $joined | Should -Not -Match 'old'
        $joined | Should -Match '## Notes'
        $joined | Should -Match 'Keep me intact\.'
    }

    It 'replaces the existing body when the heading is present and is the last section in the file' {
        $existing = @(
            '# my-module',
            '',
            '## Outputs',
            '',
            '_old body_'
        )
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $existing } {
            param($E)
            Merge-AvmReadmeSection -Content $E -Heading '## Outputs' -NewBody @('_None_')
        }
        $joined = $result -join "`n"
        $joined | Should -Match '_None_'
        $joined | Should -Not -Match '_old body_'
    }

    It 'is idempotent when called twice with the same input' {
        $existing = @('# my-module', '')
        $body = @('| Output | Type |', '| :-- | :-- |', '| `x` | string |')

        $first = InModuleScope 'Avm.Authoring' -Parameters @{ E = $existing; B = $body } {
            param($E, $B)
            Merge-AvmReadmeSection -Content $E -Heading '## Outputs' -NewBody $B
        }
        $second = InModuleScope 'Avm.Authoring' -Parameters @{ E = $first; B = $body } {
            param($E, $B)
            Merge-AvmReadmeSection -Content $E -Heading '## Outputs' -NewBody $B
        }

        ($first -join "`n") | Should -Be ($second -join "`n")
    }

    It 'strips trailing blank lines from NewBody before emitting' {
        $result = InModuleScope 'Avm.Authoring' {
            Merge-AvmReadmeSection -Content @() -Heading '## Outputs' -NewBody @('_None_', '', '')
        }
        # No double-blank tail; final char (after join) is the body, not a blank.
        $joined = $result -join "`n"
        $joined.TrimEnd("`n") | Should -Be "## Outputs`n`n_None_"
    }

    It 'preserves content above and below the replaced section' {
        $existing = @(
            'preamble line 1',
            'preamble line 2',
            '',
            '## Outputs',
            '',
            'old body',
            '',
            '## After',
            '',
            'tail line 1',
            'tail line 2'
        )
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $existing } {
            param($E)
            Merge-AvmReadmeSection -Content $E -Heading '## Outputs' -NewBody @('new body')
        }
        $joined = $result -join "`n"
        $joined | Should -Match 'preamble line 1'
        $joined | Should -Match 'preamble line 2'
        $joined | Should -Match 'new body'
        $joined | Should -Not -Match 'old body'
        $joined | Should -Match '## After'
        $joined | Should -Match 'tail line 1'
        $joined | Should -Match 'tail line 2'
    }

    It 'accepts $null content as an empty document' {
        $result = InModuleScope 'Avm.Authoring' {
            Merge-AvmReadmeSection -Content $null -Heading '## Outputs' -NewBody @('_None_')
        }
        $result -join "`n" | Should -Be "## Outputs`n`n_None_"
    }

    It 'does not treat heading-prefix matches as the heading' {
        $existing = @(
            '# my-module',
            '',
            '## Outputs (legacy notes section)',
            '',
            'this is NOT the outputs heading'
        )
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ E = $existing } {
            param($E)
            Merge-AvmReadmeSection -Content $E -Heading '## Outputs' -NewBody @('_None_')
        }
        $joined = $result -join "`n"
        $joined | Should -Match '## Outputs \(legacy notes section\)'
        $joined | Should -Match 'this is NOT the outputs heading'
        $joined | Should -Match '## Outputs'
    }
}
