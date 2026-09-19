#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    $catalogScripts = Join-Path $repoRoot 'repository-management' 'module-catalog' 'scripts'
    . (Join-Path $catalogScripts 'ModuleCatalog.ps1')
    $scriptPath = Join-Path $catalogScripts 'New-ModuleCatalogCsvDiff.ps1'

    function New-CatalogCsvDiffFixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $root 'source'
        $generatedRoot = Join-Path $root 'generated'
        $configuration = Read-AvmCatalogConfiguration
        foreach ($output in $configuration.outputs | Where-Object kind -eq 'csv') {
            $sourcePath = Join-Path $sourceRoot $output.sourcePath
            $generatedPath = Join-Path $generatedRoot $output.bundlePath
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($sourcePath))
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($generatedPath))
            $content = "ModuleName,Description`navm/res/example,Original description`n"
            [System.IO.File]::WriteAllText($sourcePath, $content, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText($generatedPath, $content, [System.Text.UTF8Encoding]::new($false))
        }
        return [pscustomobject]@{
            Root = $root
            Source = $sourceRoot
            Generated = $generatedRoot
            Output = Join-Path $root 'diff'
            Summary = Join-Path $root 'job-summary.md'
            Configuration = $configuration
        }
    }
}

Describe 'Component: module catalog CSV diff' -Tag Component {
    It 'reports an empty diff when every generated CSV matches its source' {
        $fixture = New-CatalogCsvDiffFixture

        $result = & $scriptPath -SourceRoot $fixture.Source -GeneratedRoot $fixture.Generated `
            -OutputPath $fixture.Output -SummaryPath $fixture.Summary -Confirm:$false

        $result.FileCount | Should -Be 6
        $result.ChangedFileCount | Should -Be 0
        $result.AddedLineCount | Should -Be 0
        $result.DeletedLineCount | Should -Be 0
        $result.RowsChangedCount | Should -Be 0
        $result.RowsAddedCount | Should -Be 0
        $result.RowsRemovedCount | Should -Be 0
        [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'all-csv.diff')) |
            Should -BeNullOrEmpty
        $summary = [System.IO.File]::ReadAllText($fixture.Summary)
        $summary | Should -Match '0 of 6 CSV files changed'
        $summary | Should -Not -Match '<details>'
    }

    It 'writes complete per-file and combined diffs with before and after CSVs' {
        $fixture = New-CatalogCsvDiffFixture
        $output = @($fixture.Configuration.outputs | Where-Object {
                $_.kind -eq 'csv' -and $_.sourceFile -eq 'BicepResourceModules.csv'
            })[0]
        $generatedPath = Join-Path $fixture.Generated $output.bundlePath
        [System.IO.File]::WriteAllText(
            $generatedPath,
            "ModuleName,Description`navm/res/example,Generated description`navm/res/new,New module`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        $result = & $scriptPath -SourceRoot $fixture.Source -GeneratedRoot $fixture.Generated `
            -OutputPath $fixture.Output -SummaryPath $fixture.Summary -Confirm:$false

        $result.FileCount | Should -Be 6
        $result.ChangedFileCount | Should -Be 1
        $result.AddedLineCount | Should -Be 2
        $result.DeletedLineCount | Should -Be 1
        $result.RowsChangedCount | Should -Be 1
        $result.RowsAddedCount | Should -Be 1
        $result.RowsRemovedCount | Should -Be 0
        $paths = @(Get-ChildItem -LiteralPath $fixture.Output -File -Recurse |
                ForEach-Object { [System.IO.Path]::GetRelativePath($fixture.Output, $_.FullName).Replace('\', '/') })
        @($paths | Where-Object { $_ -like 'before/*.csv' }) | Should -HaveCount 6
        @($paths | Where-Object { $_ -like 'after/*.csv' }) | Should -HaveCount 6
        @($paths | Where-Object { $_ -like 'diff/*.diff' }) | Should -HaveCount 6
        @($paths | Where-Object { $_ -like 'diff/*.fields.md' }) | Should -HaveCount 1
        $paths | Should -Contain 'diff/BicepResourceModules.fields.md'
        $paths | Should -Contain 'all-csv.diff'
        $paths | Should -Contain 'summary.md'

        $diff = [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'all-csv.diff'))
        $diff | Should -Match ([regex]::Escape('-avm/res/example,Original description'))
        $diff | Should -Match ([regex]::Escape('+avm/res/example,Generated description'))
        $diff | Should -Match ([regex]::Escape('+avm/res/new,New module'))
        $diff | Should -Match 'a/before/BicepResourceModules.csv'
        $diff | Should -Match 'b/after/BicepResourceModules.csv'
        [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'before' 'BicepResourceModules.csv')) |
            Should -Match 'Original description'
        [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'after' 'BicepResourceModules.csv')) |
            Should -Match 'Generated description'
        $fields = [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'diff' 'BicepResourceModules.fields.md'))
        $fields | Should -Match ([regex]::Escape('**1 new row(s):** `avm/res/new`'))
        $fields | Should -Match '\| `avm/res/example` \| Description \| Original description \| Generated description \|'

        $artifactSummary = [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'summary.md'))
        $jobSummary = [System.IO.File]::ReadAllText($fixture.Summary)
        $artifactSummary | Should -BeExactly $jobSummary
        $artifactSummary | Should -Match '1 of 6 CSV files changed'
        $artifactSummary | Should -Match '<details><summary><code>BicepResourceModules.csv</code>'
        $artifactSummary | Should -Match ([regex]::Escape('**1 new row(s):** `avm/res/new`'))
        $artifactSummary | Should -Match '\| `avm/res/example` \| Description \| Original description \| Generated description \|'
        $artifactSummary | Should -Match '<summary>Raw line diff</summary>'
        $artifactSummary | Should -Match ([regex]::Escape('+avm/res/new,New module'))
    }

    It 'keeps the full artifact diff when the workflow summary exceeds its inline limit' {
        $fixture = New-CatalogCsvDiffFixture
        $output = @($fixture.Configuration.outputs | Where-Object {
                $_.kind -eq 'csv' -and $_.sourceFile -eq 'BicepResourceModules.csv'
            })[0]
        [System.IO.File]::AppendAllText(
            (Join-Path $fixture.Generated $output.bundlePath),
            "avm/res/new,New module`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        $result = & $scriptPath -SourceRoot $fixture.Source -GeneratedRoot $fixture.Generated `
            -OutputPath $fixture.Output -SummaryPath $fixture.Summary -MaxInlineDiffBytes 1 -Confirm:$false

        $result.ChangedFileCount | Should -Be 1
        [System.IO.File]::ReadAllText((Join-Path $fixture.Output 'all-csv.diff')) |
            Should -Match ([regex]::Escape('+avm/res/new,New module'))
        $summary = [System.IO.File]::ReadAllText($fixture.Summary)
        $summary | Should -Match 'exceeds the 1-byte inline limit'
        $summary | Should -Not -Match ([regex]::Escape('+avm/res/new,New module'))
    }

    It 'fails before writing output when a configured CSV is missing' {
        $fixture = New-CatalogCsvDiffFixture
        $output = @($fixture.Configuration.outputs | Where-Object kind -eq 'csv')[0]
        [System.IO.File]::Delete((Join-Path $fixture.Generated $output.bundlePath))

        { & $scriptPath -SourceRoot $fixture.Source -GeneratedRoot $fixture.Generated `
                -OutputPath $fixture.Output -Confirm:$false } | Should -Throw '*Generated CSV was not found*'
        Test-Path -LiteralPath $fixture.Output | Should -BeFalse
    }
}
