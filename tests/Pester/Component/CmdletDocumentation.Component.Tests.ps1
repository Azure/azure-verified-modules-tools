BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $generator = Join-Path $repoRoot 'scripts' 'Generate-AvmCmdletDocumentation.ps1'
    $manifest = Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
}

Describe 'Cmdlet documentation generation' -Tag 'Component' {
    It 'generates one documented page per exported function' {
        $outputPath = Join-Path $TestDrive 'reference'

        & $generator -OutputPath $outputPath

        $expectedCount = @(Import-PowerShellDataFile -LiteralPath $manifest).FunctionsToExport.Count
        $pages = @(Get-ChildItem -LiteralPath $outputPath -Filter '*.md' -File)
        $pages.Count | Should -Be ($expectedCount + 1)

        $docsPage = Get-Content -LiteralPath (Join-Path $outputPath 'Invoke-AvmDocs.md') -Raw
        $docsPage | Should -Match '## Description'
        $docsPage | Should -Match '## CLI commands'
        $docsPage | Should -Match '`avm docs`'
        $docsPage | Should -Match '### -CheckDrift'
        $docsPage | Should -Match 'Report-only mode used by pr-check'
        $docsPage | Should -Match 'Bicep\s+0\.48 selects templates through bicepconfig\.json'
        $docsPage | Should -Match 'temporary source copy without changing caller configuration'
        $docsPage | Should -Match 'documentation.template.file'
        $docsPage | Should -Match 'valid explicit configurations render directly'
        $docsPage | Should -Match 'discovery does not search above it'
        $docsPage | Should -Match ([regex]::Escape(
                'Invoke-AvmDocs -Path C:\repos\my-bicep-module -Ecosystem bicep -CheckDrift'))

        $preCommitPage = Get-Content -LiteralPath (Join-Path $outputPath 'Invoke-AvmPreCommit.md') -Raw
        $preCommitPage | Should -Match '`avm pre-commit`'

        $prCheckPage = Get-Content -LiteralPath (Join-Path $outputPath 'Invoke-AvmPrCheck.md') -Raw
        $prCheckPage | Should -Match '### -ExcludeSteps'
        $prCheckPage | Should -Match '\| Type \| `String\[\]` \|'
        $prCheckPage | Should -Match ([regex]::Escape("avm pr-check -ExcludeSteps @('check policy', 'docs')"))
        $prCheckPage | Should -Match ([regex]::Escape("avm pr-check -Ecosystem terraform -ExcludeSteps 'check policy'"))
        $prCheckPage | Should -Match "Excluding every step returns overall Status='skipped', not 'pass'"
        $prCheckPage | Should -Match '## Notes'
        $prCheckPage | Should -Match 'no configured secrets are required'
        $prCheckPage | Should -Match 'Older releases fail with upgrade guidance'

        $index = Get-Content -LiteralPath (Join-Path $outputPath 'README.md') -Raw
        $index | Should -Match '\| Cmdlet \| CLI command\(s\) \| Purpose \|'
        $index | Should -Match '\| \[Invoke-AvmPreCommit\]\(Invoke-AvmPreCommit\.md\) \| `avm pre-commit` \|'
    }

    It 'reports <Problem> pages without rewriting the destination' -ForEach @(
        @{ Problem = 'stale'; PageName = 'Invoke-AvmDocs.md' }
        @{ Problem = 'missing'; PageName = 'Invoke-AvmDocs.md' }
        @{ Problem = 'unexpected'; PageName = 'Unexpected.md' }
    ) {
        $outputPath = Join-Path $TestDrive 'drift'
        & $generator -OutputPath $outputPath
        $page = Join-Path $outputPath $PageName
        switch ($Problem) {
            'stale' { [System.IO.File]::AppendAllText($page, 'stale') }
            'missing' { Remove-Item -LiteralPath $page }
            'unexpected' { [System.IO.File]::WriteAllText($page, 'unexpected') }
        }
        $before = @{}
        foreach ($file in Get-ChildItem -LiteralPath $outputPath -File) {
            $before[$file.Name] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName))
        }

        { & $generator -OutputPath $outputPath -Check } |
            Should -Throw "*Run './build.ps1 docs'*$($Problem): $PageName*"

        $after = @(Get-ChildItem -LiteralPath $outputPath -File)
        $after.Count | Should -Be $before.Count
        foreach ($file in $after) {
            $before.ContainsKey($file.Name) | Should -BeTrue
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file.FullName)) |
                Should -BeExactly $before[$file.Name]
        }
    }
}
