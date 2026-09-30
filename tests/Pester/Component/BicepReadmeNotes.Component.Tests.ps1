#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep README Notes extraction' -Tag Component {
    It 'exports body-only UTF-8 Notes and preserves README bytes, then leaves a sidecar untouched' {
        $root = Join-Path $TestDrive 'module'
        $null = New-Item -ItemType Directory -Path $root
        $readme = Join-Path $root 'README.md'
        $sidecar = Join-Path $root 'README.notes.md'
        $body = "`r`n### Setup`r`n`r`n" + '```powershell' + "`r`n" +
        "## Data Collection`r`n" + '```' + "`r`n`r`n"
        $original = "# Example`r`n## Notes`r`n$body" + "## Data Collection`r`n"
        [System.IO.File]::WriteAllText($readme, $original)
        $originalBytes = [System.IO.File]::ReadAllBytes($readme)

        $preview = Export-AvmReadmeNote -Path $root -SkipModuleVersionCheck -WhatIf
        $preview.Changed | Should -BeFalse
        $preview.PlannedFiles | Should -Be @('README.notes.md')
        Test-Path -LiteralPath $sidecar | Should -BeFalse

        $result = Export-AvmReadmeNote -Path $root -SkipModuleVersionCheck
        $result.Changed | Should -BeTrue
        $result.PlannedFiles | Should -Be @('README.notes.md')
        [System.IO.File]::ReadAllText($sidecar) |
            Should -BeExactly ($body.ReplaceLineEndings("`n"))
        [System.Linq.Enumerable]::SequenceEqual(
            [byte[]][System.IO.File]::ReadAllBytes($readme), [byte[]]$originalBytes) |
            Should -BeTrue

        [System.IO.File]::WriteAllText($sidecar, "Author's updated Notes`n")
        $again = Export-AvmReadmeNote -Path $root -SkipModuleVersionCheck
        $again.Changed | Should -BeFalse
        [System.IO.File]::ReadAllText($sidecar) | Should -BeExactly "Author's updated Notes`n"
    }

    It 'does not create a sidecar for a README without Notes' {
        $root = Join-Path $TestDrive 'without-notes'
        $null = New-Item -ItemType Directory -Path $root
        [System.IO.File]::WriteAllText((Join-Path $root 'README.md'), "# Module`n## Outputs`n")
        (Export-AvmReadmeNote -Path $root -SkipModuleVersionCheck).Changed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'README.notes.md') | Should -BeFalse
    }

    It 'is discoverable under the avm docs export-notes route' {
        $registry = InModuleScope 'Avm.Authoring' { Get-AvmVerbRegistry }
        $entry = $registry | Where-Object {
            $_.Path.Count -eq 2 -and $_.Path[0] -eq 'docs' -and $_.Path[1] -eq 'export-notes'
        }
        $entry.Cmdlet | Should -BeExactly 'Export-AvmReadmeNote'
    }
}
