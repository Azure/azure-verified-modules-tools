#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# CHANGELOG.md is an input to the ADO release pipeline, which parses it with
# .pipelines/scripts/Get-AvmReleaseNotes.ps1 in the Azure-Verified-Modules repo
# to build the manifest ReleaseNotes and the GitHub release body. That parser
# lives in another repo, so these tests hold the format contract from this side:
# a heading change here would otherwise surface as empty release notes only
# after the tag was cut.

Describe 'CHANGELOG contract' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
        $script:changelogPath = Join-Path $script:repoRoot 'CHANGELOG.md'
        $script:manifestPath = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'

        # The gallery rejects a package whose manifest ReleaseNotes exceeds this
        # many characters, and it does so at publish time -- after the tag and
        # the GitHub release already exist. v0.1.7 was rejected at 23987. The
        # pipeline truncates to survive that, but a truncated section loses
        # content, so the current version is held to the limit here where it is
        # still cheap to fix.
        $script:galleryNotesLimit = 10600

        $script:lines = (Get-Content -LiteralPath $script:changelogPath -Raw) -split "`r?`n"

        # Released sections only. 'Unreleased' is deliberately excluded: it is
        # never stamped into a manifest.
        $script:headings = @(
            for ($i = 0; $i -lt $script:lines.Count; $i++) {
                if ($script:lines[$i] -match '^## \[(?<v>\d+\.\d+\.\d+)\]') {
                    [pscustomobject]@{ Version = $Matches['v']; Line = $i }
                }
            }
        )

        function script:Get-SectionBody {
            param([int] $Index)

            $start = $script:headings[$Index].Line + 1
            $end = if ($Index + 1 -lt $script:headings.Count) {
                $script:headings[$Index + 1].Line - 1
            }
            else { $script:lines.Count - 1 }

            ($script:lines[$start..$end] -join "`n").Trim()
        }

        # How the gallery counts: CRLF is two characters on the wire even though
        # the file is stored with LF.
        function script:Measure-GalleryLength {
            param([string] $Text)
            $Text.Length + ([regex]::Matches($Text, "`n")).Count
        }
    }

    It 'has at least one released section' {
        $script:headings.Count | Should -BeGreaterThan 0
    }

    It 'uses the "## [x.y.z] - yyyy-mm-dd" heading the release parser expects' {
        foreach ($heading in $script:headings) {
            $script:lines[$heading.Line] |
                Should -Match '^## \[\d+\.\d+\.\d+\] - \d{4}-\d{2}-\d{2}$' -Because 'the release pipeline matches this shape'
        }
    }

    It 'gives every released section a non-empty body' {
        for ($i = 0; $i -lt $script:headings.Count; $i++) {
            script:Get-SectionBody -Index $i |
                Should -Not -BeNullOrEmpty -Because "section $($script:headings[$i].Version) becomes the release notes for that tag"
        }
    }

    It 'lists versions newest first' {
        $versions = @($script:headings | ForEach-Object { [version] $_.Version })
        $sorted = @($versions | Sort-Object -Descending)
        ($versions -join ',') | Should -BeExactly ($sorted -join ',')
    }

    It 'has a section for the current manifest version that fits the gallery limit' {
        $version = [string] (Import-PowerShellDataFile -LiteralPath $script:manifestPath).ModuleVersion
        $index = -1
        for ($i = 0; $i -lt $script:headings.Count; $i++) {
            if ($script:headings[$i].Version -eq $version) { $index = $i; break }
        }

        $index | Should -BeGreaterOrEqual 0 -Because "CHANGELOG.md needs a [$version] section before that version is tagged"

        $length = script:Measure-GalleryLength (script:Get-SectionBody -Index $index)
        $length | Should -BeLessOrEqual $script:galleryNotesLimit -Because "the gallery rejects the package above $script:galleryNotesLimit characters, and the pipeline would have to truncate the notes to publish"
    }
}
