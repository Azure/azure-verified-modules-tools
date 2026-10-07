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

        $preCommitPage = Get-Content -LiteralPath (Join-Path $outputPath 'Invoke-AvmPreCommit.md') -Raw
        $preCommitPage | Should -Match '`avm pre-commit`'

        $index = Get-Content -LiteralPath (Join-Path $outputPath 'README.md') -Raw
        $index | Should -Match '\| Cmdlet \| CLI command\(s\) \| Purpose \|'
        $index | Should -Match '\| \[Invoke-AvmPreCommit\]\(Invoke-AvmPreCommit\.md\) \| `avm pre-commit` \|'
    }

    It 'reports drift without rewriting the destination' {
        $outputPath = Join-Path $TestDrive 'drift'
        & $generator -OutputPath $outputPath
        $page = Join-Path $outputPath 'Invoke-AvmDocs.md'
        [System.IO.File]::AppendAllText($page, 'stale')

        { & $generator -OutputPath $outputPath -Check } |
            Should -Throw "*Run './build.ps1 docs'*stale: Invoke-AvmDocs.md*"

        (Get-Content -LiteralPath $page -Raw) | Should -Match 'stale$'
    }
}
