#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
    $script:catalogScripts = Join-Path $script:repoRoot 'repository-management' 'module-catalog' 'scripts'
    $script:manifestPath = Join-Path $script:catalogScripts '..' 'config.json'
    . (Join-Path $script:catalogScripts 'ModuleCatalog.ps1')

    function New-ManifestFixture {
        param([scriptblock] $Change)
        $value = Read-AvmCatalogJson -Path $script:manifestPath
        if ($Change) { & $Change $value }
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($path, (ConvertTo-AvmCatalogJson -Value $value))
        return $path
    }
}

Describe 'Component: module catalog artifact manifest' -Tag Component {
    It 'keeps the migration report and publication plan in the artifact only' {
        $configuration = Read-AvmCatalogConfiguration
        $configuration.outputs | Should -HaveCount 10
        @($configuration.outputs | Where-Object { $null -ne $_.destination }) | Should -HaveCount 8
        (Get-AvmCatalogOutput -Configuration $configuration -Kind catalog).file | Should -BeExactly 'v1/modules.json'
        (Get-AvmCatalogOutput -Configuration $configuration -Kind migration-report).file | Should -BeExactly 'v1/migration-report.json'
        (Get-AvmCatalogOutput -Configuration $configuration -Kind mar).file | Should -BeExactly 'BicepMARModules.json'
        $paths = Get-AvmCatalogPublicationPaths -Configuration $configuration
        $paths.docs.files.Count | Should -Be 8
        $report = Get-AvmCatalogOutput -Configuration $configuration -Kind migration-report
        $report.destination | Should -BeNullOrEmpty
        $report.targetPath | Should -BeNullOrEmpty
        $report.bundlePath | Should -BeExactly 'v1/migration-report.json'
        $paths.docs.files.Contains($report.bundlePath) | Should -BeFalse
        $paths.Contains('tools') | Should -BeFalse
        $paths.docs.files['docs/v1/modules.json'] | Should -BeExactly 'docs/static/module-indexes/v1/modules.json'
    }

    It 'publishes preview CSVs beside their canonical inputs without allowing writes to those inputs' {
        $configuration = Read-AvmCatalogConfiguration
        $paths = Get-AvmCatalogPublicationPaths -Configuration $configuration
        $csvs = @($configuration.outputs | Where-Object kind -eq 'csv')
        $csvs | Should -HaveCount 6
        foreach ($csv in $csvs) {
            $csv.sourceFile | Should -Not -Match '^test-'
            $csv.file | Should -BeExactly "test-$($csv.sourceFile)"
            $csv.sourcePath | Should -BeExactly "docs/static/module-indexes/$($csv.sourceFile)"
            $csv.targetPath | Should -BeExactly "docs/static/module-indexes/test-$($csv.sourceFile)"
            $paths.docs.files[$csv.bundlePath] | Should -BeExactly $csv.targetPath
            @($paths.docs.files.Values) | Should -Not -Contain $csv.sourcePath
            $paths.docs.basePaths | Should -Contain $csv.sourcePath
            $paths.docs.basePaths | Should -Contain $csv.targetPath
        }
        $paths.docs.basePaths | Should -HaveCount 14
    }

    It 'can switch a reviewed manifest to canonical CSV names later without duplicate base paths' {
        $path = New-ManifestFixture -Change {
            param($c)
            foreach ($csv in $c.outputs | Where-Object kind -eq 'csv') {
                $csv.file = $csv.sourceFile
            }
        }
        $configuration = Read-AvmCatalogConfiguration -Path $path
        (Get-AvmCatalogPublicationPaths -Configuration $configuration).docs.basePaths | Should -HaveCount 8
    }

    It 'rejects incomplete, ambiguous, unsafe, or unused configuration: <Case>' -TestCases @(
        @{ Case = 'missing catalog'; Change = { param($c) $c.outputs = @($c.outputs | Where-Object kind -ne 'catalog') } }
        @{ Case = 'duplicate artifact'; Change = { param($c) $c.outputs += $c.outputs[-2] } }
        @{ Case = 'duplicate CSV mapping'; Change = { param($c) $c.outputs[1].moduleType = 'resource' } }
        @{ Case = 'missing CSV source'; Change = { param($c) $c.outputs[0].Remove('sourceFile') } }
        @{ Case = 'duplicate CSV source'; Change = { param($c) $c.outputs[1].sourceFile = $c.outputs[0].sourceFile.ToLowerInvariant() } }
        @{ Case = 'unsafe CSV source'; Change = { param($c) $c.outputs[0].sourceFile = '../outside.csv' } }
        @{ Case = 'wrong CSV source extension'; Change = { param($c) $c.outputs[0].sourceFile = 'source.json' } }
        @{ Case = 'case-colliding filename'; Change = { param($c) $c.outputs[1].file = $c.outputs[0].file.ToLowerInvariant() } }
        @{ Case = 'traversal'; Change = { param($c) $c.outputs[0].file = '../outside.csv' } }
        @{ Case = 'absolute path'; Change = { param($c) $c.outputs[0].file = '/outside.csv' } }
        @{ Case = 'Windows stream'; Change = { param($c) $c.outputs[0].file = 'input.csv:secret' } }
        @{ Case = 'device name'; Change = { param($c) $c.outputs[0].file = 'NUL.csv' } }
        @{ Case = 'executable output'; Change = { param($c) $c.outputs[0].file = 'run.ps1' } }
        @{ Case = 'wrong destination'; Change = { param($c) $c.outputs[0].destination = 'tools' } }
        @{ Case = 'retired tier output'; Change = { param($c) $c.outputs += @{ kind = 'tier-configuration'; file = 'config.json'; destination = 'tools' } } }
        @{ Case = 'published control plan'; Change = { param($c) $c.outputs[-1].destination = 'docs' } }
        @{ Case = 'published migration report'; Change = { param($c) $c.outputs[-2].destination = 'docs' } }
        @{ Case = 'foreign owner'; Change = { param($c) $c.repositories.docs = 'Other/catalog' } }
        @{ Case = 'duplicate repository roles'; Change = { param($c) $c.repositories.docs = $c.repositories.tools } }
        @{ Case = 'unsafe publication root'; Change = { param($c) $c.destinations.docs.path = '.github/workflows' } }
        @{ Case = 'schema outside package'; Change = { param($c) $c.outputs[7].schema = 'untrusted/schema.json' } }
        @{ Case = 'unknown top-level field'; Change = { param($c) $c['ignored'] = 'not allowed' } }
        @{ Case = 'ignored output override'; Change = { param($c) $c.outputs[0]['bundlePath'] = 'unexpected.csv' } }
        @{ Case = 'file-directory collision'; Change = { param($c) $c.outputs[7].file = 'BicepResourceModules.csv/child.json' } }
    ) {
        param($Change)
        $path = New-ManifestFixture -Change $Change
        { Read-AvmCatalogConfiguration -Path $path } | Should -Throw
    }

    It 'exports configured repository choices for checkout and narrowly scoped publication' {
        $path = New-ManifestFixture -Change {
            param($c)
            $c.repositories.docs = 'Azure/catalog-fixture'
            $c.repositories.bicep = 'Azure/bicep-fixture'
        }
        $outputPath = Join-Path $TestDrive 'workflow-output'
        $result = & (Join-Path $script:catalogScripts 'Get-ModuleCatalogConfiguration.ps1') `
            -ConfigurationPath $path -GitHubOutputPath $outputPath -Confirm:$false
        $result.'documentation-repository' | Should -BeExactly 'Azure/catalog-fixture'
        $result.'bicep-repository' | Should -BeExactly 'Azure/bicep-fixture'
        $result.'publication-repositories' | Should -BeExactly 'catalog-fixture'
        $text = [System.IO.File]::ReadAllText($outputPath)
        $text | Should -Match 'documentation-repository=Azure/catalog-fixture'
        $text | Should -Not -Match "`r"
    }

    It 'uses the configured Bicep repository in discovered identities rather than the former literal' {
        $path = New-ManifestFixture -Change { param($c) $c.repositories.bicep = 'Azure/bicep-fixture' }
        $configuration = Read-AvmCatalogConfiguration -Path $path
        $identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-fixture' `
            -ModulePath 'avm/res/storage/storage-account' -Configuration $configuration
        $identity.RepoURL | Should -BeExactly 'https://github.com/Azure/bicep-fixture/tree/main/avm/res/storage/storage-account'
    }
}
