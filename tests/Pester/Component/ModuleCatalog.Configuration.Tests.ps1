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
    It 'declares every published artifact and the internal publication plan' {
        $configuration = Read-AvmCatalogConfiguration
        $configuration.outputs | Should -HaveCount 11
        @($configuration.outputs | Where-Object { $null -ne $_.destination }) | Should -HaveCount 10
        (Get-AvmCatalogOutput -Configuration $configuration -Kind catalog).file | Should -BeExactly 'v1/modules.json'
        (Get-AvmCatalogOutput -Configuration $configuration -Kind migration-report).file | Should -BeExactly 'v1/migration-report.json'
        (Get-AvmCatalogOutput -Configuration $configuration -Kind mar).file | Should -BeExactly 'BicepMARModules.json'
        $paths = Get-AvmCatalogPublicationPaths -Configuration $configuration
        $paths.docs.files.Count | Should -Be 9
        $paths.tools.files.Count | Should -Be 1
        $paths.docs.files['docs/v1/modules.json'] | Should -BeExactly 'docs/static/module-indexes/v1/modules.json'
    }

    It 'rejects incomplete, ambiguous, unsafe, or unused configuration: <Case>' -TestCases @(
        @{ Case = 'missing catalog'; Change = { param($c) $c.outputs = @($c.outputs | Where-Object kind -ne 'catalog') } }
        @{ Case = 'duplicate artifact'; Change = { param($c) $c.outputs += $c.outputs[-2] } }
        @{ Case = 'duplicate CSV mapping'; Change = { param($c) $c.outputs[1].moduleType = 'resource' } }
        @{ Case = 'case-colliding filename'; Change = { param($c) $c.outputs[1].file = $c.outputs[0].file.ToLowerInvariant() } }
        @{ Case = 'traversal'; Change = { param($c) $c.outputs[0].file = '../outside.csv' } }
        @{ Case = 'absolute path'; Change = { param($c) $c.outputs[0].file = '/outside.csv' } }
        @{ Case = 'Windows stream'; Change = { param($c) $c.outputs[0].file = 'input.csv:secret' } }
        @{ Case = 'device name'; Change = { param($c) $c.outputs[0].file = 'NUL.csv' } }
        @{ Case = 'executable output'; Change = { param($c) $c.outputs[0].file = 'run.ps1' } }
        @{ Case = 'wrong destination'; Change = { param($c) $c.outputs[0].destination = 'tools' } }
        @{ Case = 'published control plan'; Change = { param($c) $c.outputs[-1].destination = 'docs' } }
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
        $result.'publication-repositories' | Should -BeExactly 'catalog-fixture,azure-verified-modules-tools'
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
