#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) 'scripts' 'Get-AvmReleaseNotes.ps1'

    function New-Changelog {
        param([Parameter(Mandatory)][string] $Body)
        $path = Join-Path $TestDrive 'CHANGELOG.md'
        # Force LF on disk so the parser exercises its CRLF tolerance via the
        # explicit CRLF test below, not via accidental Windows line endings.
        $normalised = $Body -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($path, $normalised, (New-Object System.Text.UTF8Encoding $false))
        return $path
    }
}

Describe 'Get-AvmReleaseNotes' {

    Context 'happy path' {

        It 'returns the section for an exact version match' {
            $changelog = New-Changelog @'
# Changelog

## [Unreleased]

Future work.

## [0.1.0] - 2026-05-18

### Added

- First real release.

## [0.0.1] - 2026-05-12

Initial placeholder.
'@
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog
            $notes | Should -Match '### Added'
            $notes | Should -Match 'First real release\.'
            $notes | Should -Not -Match 'Initial placeholder'
            $notes | Should -Not -Match 'Future work'
        }

        It 'trims leading and trailing blank lines from the section' {
            $changelog = New-Changelog @'
# Changelog

## [0.1.0] - 2026-05-18



First entry.

Last entry.



## [0.0.1] - 2026-05-12

Placeholder.
'@
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog
            $notes | Should -Be "First entry.`n`nLast entry."
        }

        It 'handles a version section at end of file (no following heading)' {
            $changelog = New-Changelog @'
# Changelog

## [0.1.0] - 2026-05-18

Only entry.
'@
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog
            $notes | Should -Be 'Only entry.'
        }

        It 'returns Unreleased when asked for it' {
            $changelog = New-Changelog @'
# Changelog

## [Unreleased]

Brewing.

## [0.1.0] - 2026-05-18

Released.
'@
            $notes = & $script:ScriptPath -Version 'Unreleased' -ChangelogPath $changelog
            $notes | Should -Be 'Brewing.'
        }

        It 'never matches a similarly-prefixed version' {
            $changelog = New-Changelog @'
# Changelog

## [0.1.0-preview.1] - 2026-05-17

Preview body.

## [0.1.0] - 2026-05-18

Stable body.
'@
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog
            $notes | Should -Be 'Stable body.'

            $previewNotes = & $script:ScriptPath -Version '0.1.0-preview.1' -ChangelogPath $changelog
            $previewNotes | Should -Be 'Preview body.'
        }

        It 'parses a CHANGELOG that was saved with CRLF line endings' {
            $path = Join-Path $TestDrive 'CHANGELOG.crlf.md'
            $body = "# Changelog`r`n`r`n## [0.1.0] - 2026-05-18`r`n`r`nCRLF entry.`r`n"
            [System.IO.File]::WriteAllText($path, $body, (New-Object System.Text.UTF8Encoding $false))
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $path
            $notes | Should -Be 'CRLF entry.'
        }
    }

    Context 'failure cases' {

        It 'throws when the CHANGELOG file is missing' {
            $missing = Join-Path $TestDrive 'does-not-exist.md'
            { & $script:ScriptPath -Version '0.1.0' -ChangelogPath $missing } |
                Should -Throw -ErrorId '*' -ExpectedMessage '*CHANGELOG not found*'
        }

        It 'throws when the requested version has no section' {
            $changelog = New-Changelog @'
# Changelog

## [0.1.0] - 2026-05-18

Something.
'@
            { & $script:ScriptPath -Version '9.9.9' -ChangelogPath $changelog } |
                Should -Throw -ExpectedMessage "*No CHANGELOG section found for version '9.9.9'*"
        }

        It 'throws when the matched section is empty' {
            $changelog = New-Changelog @'
# Changelog

## [0.1.0] - 2026-05-18

## [0.0.1] - 2026-05-12

Placeholder.
'@
            { & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog } |
                Should -Throw -ExpectedMessage "*section for version '0.1.0' is empty*"
        }

        It 'rejects an empty version string at parameter bind time' {
            { & $script:ScriptPath -Version '' -ChangelogPath (Join-Path $TestDrive 'x.md') } |
                Should -Throw
        }
    }

    Context 'repository CHANGELOG sanity' {

        BeforeAll {
            $script:RepoChangelog = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) 'CHANGELOG.md'
        }

        It 'finds the section for the current manifest version' {
            $manifestPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
            $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
            $version  = [string] $manifest.ModuleVersion

            $notes = & $script:ScriptPath -Version $version -ChangelogPath $script:RepoChangelog
            $notes | Should -Not -BeNullOrEmpty
        }
    }
}
