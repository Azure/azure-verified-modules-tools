#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    $script:ScriptPath = Join-Path $script:RepoRoot 'scripts' 'Set-AvmModuleVersion.ps1'

    function New-Manifest {
        param(
            [Parameter(Mandatory)][string] $Body,
            [string] $Name = 'Avm.Authoring.psd1'
        )
        $path = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllText($path, ($Body -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
        return $path
    }

    function New-SampleManifest {
        param([string] $Name = 'Avm.Authoring.psd1')
        return New-Manifest -Name $Name -Body @'
@{
    RootModule           = 'Avm.Authoring.psm1'
    ModuleVersion        = '0.1.0'
    Description          = 'Sample module. Mentions 0.1.0 in prose and ReleaseNotes as words.'
    PrivateData          = @{
        PSData = @{
            ProjectUri   = 'https://example.invalid/ModuleVersion/0.1.0'
            ReleaseNotes = 'Old notes.'
        }
    }
}
'@
    }
}

Describe 'Set-AvmModuleVersion' {

    Context 'version stamping' {

        It 'rewrites ModuleVersion and leaves the rest of the manifest intact' {
            $path = New-SampleManifest
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -Confirm:$false

            $data = Import-PowerShellDataFile -LiteralPath $path
            $data.ModuleVersion | Should -Be '1.2.3'
            $data.Description | Should -Match 'Mentions 0\.1\.0 in prose'
            $data.PrivateData.PSData.ProjectUri | Should -Be 'https://example.invalid/ModuleVersion/0.1.0'
            $data.PrivateData.PSData.ReleaseNotes | Should -Be 'Old notes.'
        }

        It 'is idempotent when re-stamped with the same version' {
            $path = New-SampleManifest
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -Confirm:$false
            $first = [System.IO.File]::ReadAllText($path)
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -Confirm:$false
            [System.IO.File]::ReadAllText($path) | Should -BeExactly $first
        }

        It 'can re-stamp a manifest whose ReleaseNotes are already a here-string' {
            $path = New-SampleManifest
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -ReleaseNotes "First`n`n- one" -Confirm:$false
            & $script:ScriptPath -ManifestPath $path -Version '1.2.4' -ReleaseNotes "Second`n`n- two" -Confirm:$false

            $data = Import-PowerShellDataFile -LiteralPath $path
            $data.ModuleVersion | Should -Be '1.2.4'
            $data.PrivateData.PSData.ReleaseNotes | Should -Be "Second`n`n- two"
        }

        It 'honours -WhatIf' {
            $path = New-SampleManifest
            $before = [System.IO.File]::ReadAllText($path)
            & $script:ScriptPath -ManifestPath $path -Version '9.9.9' -WhatIf
            [System.IO.File]::ReadAllText($path) | Should -BeExactly $before
        }
    }

    Context 'release notes stamping' {

        It 'writes markdown verbatim, including regex substitution tokens' {
            $path = New-SampleManifest
            $notes = "### Added`n`n- Handles `$ref, `$1, `$' and `$`$ safely.`n- Keeps ``code`` spans."
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -ReleaseNotes $notes -Confirm:$false

            $data = Import-PowerShellDataFile -LiteralPath $path
            $data.PrivateData.PSData.ReleaseNotes | Should -Be $notes
        }

        It 'preserves single quotes without doubling them' {
            $path = New-SampleManifest
            $notes = "Don't double the apostrophe."
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -ReleaseNotes $notes -Confirm:$false

            (Import-PowerShellDataFile -LiteralPath $path).PrivateData.PSData.ReleaseNotes |
                Should -Be $notes
        }

        It 'normalises CRLF in the supplied notes to LF' {
            $path = New-SampleManifest
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -ReleaseNotes "one`r`ntwo" -Confirm:$false

            (Import-PowerShellDataFile -LiteralPath $path).PrivateData.PSData.ReleaseNotes |
                Should -Be "one`ntwo"
        }

        It 'leaves ReleaseNotes untouched when none are supplied' {
            $path = New-SampleManifest
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -Confirm:$false

            (Import-PowerShellDataFile -LiteralPath $path).PrivateData.PSData.ReleaseNotes |
                Should -Be 'Old notes.'
        }

        It 'leaves ReleaseNotes untouched when an empty string is supplied' {
            $path = New-SampleManifest
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -ReleaseNotes '' -Confirm:$false

            (Import-PowerShellDataFile -LiteralPath $path).PrivateData.PSData.ReleaseNotes |
                Should -Be 'Old notes.'
        }

        It 'refuses notes that would truncate the here-string' {
            $path = New-SampleManifest
            { & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -ReleaseNotes "safe`n'@`nunsafe" -Confirm:$false } |
                Should -Throw -ExpectedMessage '*here-string terminator*'
        }
    }

    Context 'encoding' {

        It 'writes UTF-8 without a BOM and with LF line endings' {
            $path = New-Manifest -Body "@{`r`n    ModuleVersion = '0.1.0'`r`n}`r`n"
            & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -Confirm:$false

            $bytes = [System.IO.File]::ReadAllBytes($path)
            $text = [System.IO.File]::ReadAllText($path)
            # F47: a zero-byte manifest has no BOM and no CR, so both negatives
            # below pass on one. Pin the content first.
            $text | Should -Match "ModuleVersion += +'1\.2\.3'"
            $bytes[0..2] -join ',' | Should -Not -Be '239,187,191'
            $text | Should -Not -Match "`r"
        }
    }

    Context 'failure cases' {

        It 'throws when the manifest does not exist' {
            { & $script:ScriptPath -ManifestPath (Join-Path $TestDrive 'nope.psd1') -Version '1.2.3' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*Manifest not found*'
        }

        It 'throws when there is no ModuleVersion assignment' {
            $path = New-Manifest -Body "@{`n    RootModule = 'x.psm1'`n}`n"
            { & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -Confirm:$false } |
                Should -Throw -ExpectedMessage "*No 'ModuleVersion = <quoted value>' assignment*"
        }

        It 'throws when notes are requested but there is no ReleaseNotes assignment' {
            $path = New-Manifest -Body "@{`n    ModuleVersion = '0.1.0'`n}`n"
            { & $script:ScriptPath -ManifestPath $path -Version '1.2.3' -ReleaseNotes 'x' -Confirm:$false } |
                Should -Throw -ExpectedMessage "*No 'ReleaseNotes = <quoted value>' assignment*"
        }

        It 'rejects a non-semver version at parameter bind time' {
            $path = New-SampleManifest
            { & $script:ScriptPath -ManifestPath $path -Version 'v1.2.3' -Confirm:$false } | Should -Throw
            { & $script:ScriptPath -ManifestPath $path -Version '1.2' -Confirm:$false } | Should -Throw
        }
    }

    Context 'against the real manifest' {

        It 'produces a manifest that Test-ModuleManifest still accepts' {
            $stage = Join-Path $TestDrive 'stage'
            $null = New-Item -ItemType Directory -Path $stage -Force
            Copy-Item -Path (Join-Path $script:RepoRoot 'src' 'Avm.Authoring' '*') -Destination $stage -Recurse -Force

            $manifest = Join-Path $stage 'Avm.Authoring.psd1'
            & $script:ScriptPath -ManifestPath $manifest -Version '9.8.7' -ReleaseNotes "### Added`n`n- A thing." -Confirm:$false

            (Test-ModuleManifest -Path $manifest).Version.ToString() | Should -Be '9.8.7'
            (Import-PowerShellDataFile -LiteralPath $manifest).PrivateData.PSData.ReleaseNotes |
                Should -Be "### Added`n`n- A thing."
        }
    }
}
