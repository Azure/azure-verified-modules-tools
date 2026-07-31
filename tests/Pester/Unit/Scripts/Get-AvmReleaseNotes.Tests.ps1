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

    Context '-AllowMissing' {

        It 'returns nothing instead of throwing when the CHANGELOG file is missing' {
            $missing = Join-Path $TestDrive 'does-not-exist.md'
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $missing -AllowMissing
            $notes | Should -BeNullOrEmpty
        }

        It 'returns nothing instead of throwing when the version has no section' {
            $changelog = New-Changelog @'
# Changelog

## [0.1.0] - 2026-05-18

Something.
'@
            $notes = & $script:ScriptPath -Version '9.9.9' -ChangelogPath $changelog -AllowMissing
            $notes | Should -BeNullOrEmpty
        }

        It 'returns nothing instead of throwing when the matched section is empty' {
            $changelog = New-Changelog @'
# Changelog

## [0.1.0] - 2026-05-18

## [0.0.1] - 2026-05-12

Placeholder.
'@
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog -AllowMissing
            $notes | Should -BeNullOrEmpty
        }

        It 'still returns the section when one exists' {
            $changelog = New-Changelog @'
# Changelog

## [0.1.0] - 2026-05-18

Present and correct.
'@
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog -AllowMissing
            $notes | Should -Be 'Present and correct.'
        }
    }

    Context '-MaxLength' {

        BeforeAll {
            # Mirrors the worst case the gallery can see: NuGet may rewrite LF
            # as CRLF when it lifts the value out of the manifest.
            $script:Measure = { param([string] $Text) $Text.Length + ([regex]::Matches($Text, "`n")).Count }

            function New-LongChangelog {
                param([int] $BodyLines = 400)
                $body = @('### Breaking', '', '- The one thing a consumer must not miss.', '')
                $body += 1..$BodyLines | ForEach-Object { "- Filler entry number $_ padded out to a realistic changelog width." }
                $text = "# Changelog`n`n## [0.1.0] - 2026-05-18`n`n" + ($body -join "`n") + "`n`n## [0.0.1] - 2026-05-12`n`nPlaceholder.`n"
                return (New-Changelog $text)
            }
        }

        It 'returns the section unchanged when it already fits' {
            $changelog = New-Changelog @'
# Changelog

## [0.1.0] - 2026-05-18

Short body.
'@
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog -MaxLength 10600
            $notes | Should -Be 'Short body.'
            $notes | Should -Not -Match 'truncated'
        }

        It 'treats the default of 0 as unlimited' {
            $changelog = New-LongChangelog
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog
            (& $script:Measure $notes) | Should -BeGreaterThan 10600
            $notes | Should -Match 'Filler entry number 400'
        }

        It 'truncates to within the cap, counting newlines at their CRLF worst case' {
            $changelog = New-LongChangelog
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog -MaxLength 2000

            $notes | Should -Not -BeNullOrEmpty
            (& $script:Measure $notes) | Should -BeLessOrEqual 2000
            # Positive anchor: proves the cap did not simply empty the value.
            (& $script:Measure $notes) | Should -BeGreaterThan 1000
        }

        It 'keeps the head of the section and drops the tail' {
            $changelog = New-LongChangelog
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog -MaxLength 2000

            $notes | Should -Match '### Breaking'
            $notes | Should -Match 'must not miss'
            $notes | Should -Not -Match 'Filler entry number 400\b'
        }

        It 'appends a footer linking the full notes for the tag' {
            $changelog = New-LongChangelog
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog -MaxLength 2000

            $notes | Should -Match 'truncated to fit the PowerShell Gallery'
            $notes | Should -Match 'releases/tag/v0\.1\.0'
        }

        It 'cuts on a line boundary, never mid-line' {
            $changelog = New-LongChangelog
            $notes = & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog -MaxLength 2000

            $sourceLines = (& $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog) -split "`n"
            # Everything before the footer separator must be a whole source line.
            $kept = ($notes -split "`n---`n")[0] -split "`n"
            $kept.Count | Should -BeGreaterThan 1
            foreach ($line in $kept) {
                if ($line -eq '') { continue }
                $sourceLines | Should -Contain $line
            }
        }

        It 'throws when the cap cannot even hold the footer' {
            $changelog = New-LongChangelog
            { & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog -MaxLength 20 } |
                Should -Throw -ExpectedMessage '*too small to hold the truncation footer*'
        }

        It 'rejects a negative cap at parameter bind time' {
            $changelog = New-Changelog "# Changelog`n`n## [0.1.0] - 2026-05-18`n`nBody.`n"
            { & $script:ScriptPath -Version '0.1.0' -ChangelogPath $changelog -MaxLength -1 } |
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

        It 'caps every released section under the gallery limit the release workflow uses' {
            # The build stamps each tag's section into the manifest, and the
            # gallery rejects the package over 10600 characters at publish time
            # -- after the tag exists. Every section must survive that path, not
            # just the one that happens to be current.
            $limit   = 10600
            $measure = { param([string] $Text) $Text.Length + ([regex]::Matches($Text, "`n")).Count }

            $versions = Select-String -Path $script:RepoChangelog -Pattern '^## \[(?<v>\d+\.\d+\.\d+)\]' |
                ForEach-Object { $_.Matches[0].Groups['v'].Value }

            $versions.Count | Should -BeGreaterThan 0

            foreach ($v in $versions) {
                $capped = & $script:ScriptPath -Version $v -ChangelogPath $script:RepoChangelog -MaxLength $limit
                $capped | Should -Not -BeNullOrEmpty -Because "section $v must produce notes"
                (& $measure $capped) | Should -BeLessOrEqual $limit -Because "section $v must fit the gallery limit"
            }
        }
    }
}
