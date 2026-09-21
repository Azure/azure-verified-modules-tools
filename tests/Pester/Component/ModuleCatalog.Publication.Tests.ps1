#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    $catalogScripts = Join-Path $repoRoot 'repository-management' 'module-catalog' 'scripts'
    . (Join-Path $catalogScripts 'ModuleCatalog.ps1')
    . (Join-Path $catalogScripts 'ModuleCatalog.Collection.ps1')
    . (Join-Path $catalogScripts 'ModuleCatalog.Publication.ps1')
    $schemaPath = Join-Path $repoRoot 'src' 'Avm.Authoring' 'Resources' 'Schemas' 'v1' 'avm-modules-catalog.schema.json'
    $catalogSchemaId = (Read-AvmCatalogJson -Path $schemaPath)['$id']
    $workflow = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.github' 'workflows' 'module-metadata-sync.yml'))

    function New-CatalogPublicationFixture {
        param([System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration))
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory($root)
        $paths = Get-AvmCatalogPublicationPaths -Configuration $Configuration
        $sourceCsvRows = [ordered]@{}
        foreach ($output in $Configuration.outputs | Where-Object kind -eq 'csv') {
            $sourceCsvRows[$output.sourceFile] = @()
        }
        $plan = [ordered]@{ schemaVersion = 1; manifestHash = $Configuration.hash; docs = $null; outputHashes = [ordered]@{} }
        foreach ($role in $paths.Keys) {
            $plan[$role] = [ordered]@{ repository = $paths[$role].repository; baseFiles = [ordered]@{} }
            foreach ($target in $paths[$role].basePaths) {
                $plan[$role].baseFiles[$target] = '1' * 64
            }
            foreach ($output in $Configuration.outputs | Where-Object { $_.kind -ne 'publication-plan' }) {
                $relative = $output.bundlePath
                $file = Join-Path $root $relative
                $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
                $text = if ($relative.EndsWith('.csv')) {
                    "ModuleName,ModuleDisplayName,RepoURL,ModuleStatus,Description`n"
                }
                elseif ($relative -eq (Get-AvmCatalogOutput -Configuration $Configuration -Kind catalog).bundlePath) {
                    ConvertTo-AvmCatalogJson -Value ([ordered]@{ '$schema' = $catalogSchemaId; schemaVersion = 1; modules = [ordered]@{} })
                }
                elseif ($relative -eq (Get-AvmCatalogOutput -Configuration $Configuration -Kind mar).bundlePath) {
                    "[]`n"
                }
                else {
                    ConvertTo-AvmCatalogJson -Value ([ordered]@{
                            schemaVersion = 1
                            sourceCsvRows = $sourceCsvRows
                            csvRowRemovals = @()
                            csvRowRemovalsForced = $false
                        })
                }
                [System.IO.File]::WriteAllText($file, $text, [System.Text.UTF8Encoding]::new($false))
                $plan.outputHashes[$relative] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        $planPath = Join-Path $root (Get-AvmCatalogOutput -Configuration $Configuration -Kind publication-plan).bundlePath
        $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($planPath))
        [System.IO.File]::WriteAllText($planPath, (ConvertTo-AvmCatalogJson -Value $plan))
        return $root
    }

    function Save-CatalogPublicationFixtureFile {
        param([string] $Root, [string] $RelativePath, [string] $Text, [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration))
        $path = Join-Path $Root $RelativePath
        [System.IO.File]::WriteAllText($path, $Text, [System.Text.UTF8Encoding]::new($false))
        $planPath = Join-Path $Root (Get-AvmCatalogOutput -Configuration $Configuration -Kind publication-plan).bundlePath
        $plan = Read-AvmCatalogJson -Path $planPath
        $plan.outputHashes[$RelativePath] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText($planPath, (ConvertTo-AvmCatalogJson -Value $plan))
    }

    function Set-CatalogPublicationFixtureRows {
        param(
            [string] $Root,
            [AllowEmptyCollection()][object[]] $SourceRows,
            [AllowEmptyCollection()][object[]] $OutputRows,
            [switch] $Force,
            [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
        )
        $output = @($Configuration.outputs | Where-Object { $_.kind -eq 'csv' -and $_.sourceFile -eq 'BicepResourceModules.csv' })[0]
        $headers = @('ModuleName', 'ModuleDisplayName', 'RepoURL', 'ModuleStatus', 'Description')
        Save-CatalogPublicationFixtureFile -Root $Root -RelativePath $output.bundlePath `
            -Text (ConvertTo-AvmCatalogCsv -Headers $headers -Rows $OutputRows) -Configuration $Configuration
        $reportOutput = Get-AvmCatalogOutput -Configuration $Configuration -Kind migration-report
        $report = Read-AvmCatalogJson -Path (Join-Path $Root $reportOutput.bundlePath)
        $report.sourceCsvRows[$output.sourceFile] = Get-AvmCatalogCsvRowSnapshot -Rows $SourceRows
        $report.csvRowRemovals = Get-AvmCatalogCsvRowRemovals -SourceRows $report.sourceCsvRows[$output.sourceFile] `
            -OutputRows (Get-AvmCatalogCsvRowSnapshot -Rows $OutputRows) -Output $output -Configuration $Configuration
        $report.csvRowRemovalsForced = [bool]$Force
        Save-CatalogPublicationFixtureFile -Root $Root -RelativePath $reportOutput.bundlePath `
            -Text (ConvertTo-AvmCatalogJson -Value $report) -Configuration $Configuration
    }

    function New-CatalogPublicationSourceFixture {
        param([System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration))
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($output in $Configuration.outputs | Where-Object kind -eq 'csv') {
            $path = Join-Path $root $output.sourcePath
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
            [System.IO.File]::WriteAllText($path, "ModuleName,ModuleDisplayName,RepoURL,ModuleStatus,Description`n")
        }
        return $root
    }

    $sourceRow = [ordered]@{
        ModuleName = 'avm/res/storage/storage-account'
        ModuleDisplayName = 'Storage account'
        RepoURL = 'https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/storage/storage-account'
        ModuleStatus = 'Available'
        Description = 'Storage account module.'
    }
}

Describe 'Component: module catalog publication boundaries' -Tag Component {
    It 'validates a complete fixed-path hashed bundle without network or remote changes' {
        $root = New-CatalogPublicationFixture
        $plan = Test-AvmCatalogPublicationBundle -Path $root
        $plan.docs.repository | Should -BeExactly 'Azure/Azure-Verified-Modules'
        $plan.Contains('tools') | Should -BeFalse
        $plan.outputHashes.Count | Should -Be 9
    }

    It 'rejects altered output bytes before preparing any remote update' {
        $root = New-CatalogPublicationFixture
        [System.IO.File]::AppendAllText((Join-Path $root 'docs' 'BicepResourceModules.csv'), 'tampered')
        foreach ($force in @($false, $true)) {
            { Test-AvmCatalogPublicationBundle -Path $root -Force:$force } | Should -Throw '*hash mismatch*'
        }
    }

    It 'hash-validates the artifact-only migration report and refuses a published copy' {
        $root = New-CatalogPublicationFixture
        $reportPath = Join-Path $root 'v1' 'migration-report.json'
        Copy-Item -LiteralPath $reportPath -Destination (Join-Path $root 'docs' 'v1' 'migration-report.json')
        { Test-AvmCatalogPublicationBundle -Path $root } | Should -Throw '*Unexpected file*'
        $root = New-CatalogPublicationFixture
        [System.IO.File]::AppendAllText((Join-Path $root 'v1' 'migration-report.json'), ' ')
        { Test-AvmCatalogPublicationBundle -Path $root } | Should -Throw '*hash mismatch*v1/migration-report.json*'
    }

    It 'rejects a bundle collected under a different artifact manifest' {
        $root = New-CatalogPublicationFixture
        $configuration = Read-AvmCatalogConfiguration
        $configuration.hash = '0' * 64
        { Test-AvmCatalogPublicationBundle -Path $root -Configuration $configuration } |
            Should -Throw '*stale catalog publication manifest*'
    }

    It 'refuses non-catalog files and paths outside the output allow-list' {
        $root = New-CatalogPublicationFixture
        [System.IO.File]::WriteAllText((Join-Path $root 'unexpected.ps1'), 'throw "must not execute"')
        { Test-AvmCatalogPublicationBundle -Path $root } | Should -Throw '*Unexpected file*'
        { Assert-AvmCatalogSafePath -Root $root -RelativePath '../outside.json' } | Should -Throw '*fixed relative file paths*'
    }

    It 'rejects a preview CSV included as an output during canonical publication' {
        $root = New-CatalogPublicationFixture
        Copy-Item -LiteralPath (Join-Path $root 'docs' 'BicepResourceModules.csv') `
            -Destination (Join-Path $root 'docs' 'test-BicepResourceModules.csv')
        { Test-AvmCatalogPublicationBundle -Path $root } | Should -Throw '*Unexpected file*'
    }

    It 'requires a base hash for each canonical input and output' {
        $root = New-CatalogPublicationFixture
        $planPath = Join-Path $root 'plan.json'
        $plan = Read-AvmCatalogJson -Path $planPath
        $plan.docs.baseFiles.Remove('docs/static/module-indexes/BicepResourceModules.csv')
        $plan.docs.baseFiles['docs/static/module-indexes/unrelated.csv'] = '1' * 64
        [System.IO.File]::WriteAllText($planPath, (ConvertTo-AvmCatalogJson -Value $plan))
        { Test-AvmCatalogPublicationBundle -Path $root } | Should -Throw '*no valid base hash*BicepResourceModules.csv*'
    }

    It 'permits a trusted main-branch publication preview without an enable variable or remote calls' {
        $root = New-CatalogPublicationFixture
        $environment = @{
            GITHUB_ACTIONS = 'true'
            GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
            GITHUB_REF = 'refs/heads/main'
            GITHUB_RUN_ID = '123'
            GITHUB_RUN_ATTEMPT = '1'
            AVM_APP_SLUG = 'azure-verified-modules'
            GH_TOKEN = 'offline-test-token'
            AVM_METADATA_SYNC_ENABLED = $null
        }
        $saved = @{}
        Mock Invoke-AvmCatalogProcess { throw 'A publication preview must not run external commands.' }
        try {
            foreach ($name in $environment.Keys) {
                $saved[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, $environment[$name])
            }
            { & (Join-Path $catalogScripts 'Publish-ModuleCatalog.ps1') -BundlePath $root -Publish -WhatIf } |
                Should -Not -Throw
            Should -Invoke Invoke-AvmCatalogProcess -Times 0 -Exactly
        }
        finally {
            foreach ($name in $saved.Keys) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
    }

    It 'blocks a stale base rather than overwriting new main-branch input' {
        $root = Join-Path $TestDrive 'base'
        $null = [System.IO.Directory]::CreateDirectory($root)
        $file = Join-Path $root 'input.json'
        [System.IO.File]::WriteAllText($file, '{"value":1}')
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        { Assert-AvmCatalogPublicationBase -Root $root -BaseFiles @{ 'input.json' = $hash; 'new.json' = $null } } | Should -Not -Throw
        [System.IO.File]::WriteAllText($file, '{"value":2}')
        { Assert-AvmCatalogPublicationBase -Root $root -BaseFiles @{ 'input.json' = $hash } } | Should -Throw '*base changed*'
    }

    It 'rejects retired tools configuration publication instead of broadening the write scope' {
        $root = New-CatalogPublicationFixture
        $planPath = Join-Path $root 'plan.json'
        $plan = Read-AvmCatalogJson -Path $planPath
        $plan['tools'] = @{ repository = 'Azure/azure-verified-modules-tools'; baseFiles = @{} }
        [System.IO.File]::WriteAllText($planPath, (ConvertTo-AvmCatalogJson -Value $plan))
        { Test-AvmCatalogPublicationBundle -Path $root } | Should -Throw '*manifest fields*'
    }

    It 'parses every catalog script without executing fetched module code' {
        foreach ($file in @(Get-ChildItem -LiteralPath $catalogScripts -Filter '*.ps1' -File)) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            @($errors) | Should -HaveCount 0 -Because $file.Name
            $forbidden = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -in @('Invoke-Expression', 'Start-Process', 'Install-Module', 'Install-PSResource', 'terraform', 'bicep')
                    }, $true))
            $forbidden | Should -HaveCount 0 -Because $file.Name
        }
    }
}

Describe 'Component: module catalog publication row retention' -Tag Component {
    It 'requires an explicit publication override even for a bundle generated with force' {
        $root = New-CatalogPublicationFixture
        Set-CatalogPublicationFixtureRows -Root $root -SourceRows @($sourceRow) -OutputRows @() -Force
        foreach ($force in @($null, $false)) {
            $arguments = @{ Path = $root }
            if ($null -ne $force) { $arguments.Force = $force }
            { Test-AvmCatalogPublicationBundle @arguments } | Should -Throw '*CSV row removals are blocked*'
        }
        { Test-AvmCatalogPublicationBundle -Path $root -Force } | Should -Not -Throw
        $report = Read-AvmCatalogJson -Path (Join-Path $root 'v1' 'migration-report.json')
        $report.csvRowRemovals | Should -HaveCount 1
        $report.csvRowRemovals[0].sourceFile | Should -BeExactly 'BicepResourceModules.csv'
        $report.csvRowRemovals[0].moduleName | Should -BeExactly $sourceRow.ModuleName
    }

    It 'blocks row removals at the publication entry point before any remote commands' {
        $root = New-CatalogPublicationFixture
        Set-CatalogPublicationFixtureRows -Root $root -SourceRows @($sourceRow) -OutputRows @() -Force
        Mock Invoke-AvmCatalogProcess { throw 'No remote command is allowed during bundle validation.' }
        $scriptPath = Join-Path $catalogScripts 'Publish-ModuleCatalog.ps1'
        { & $scriptPath -BundlePath $root } | Should -Throw '*CSV row removals are blocked*'
        & $scriptPath -BundlePath $root -Force | Should -BeExactly 'Catalog publication plan validated; no remote changes requested.'
        Should -Invoke Invoke-AvmCatalogProcess -Times 0 -Exactly
    }

    It 'does not allow force to bypass missing or inconsistent removal evidence: <Case>' -TestCases @(
        @{ Case = 'missing source snapshot'; Change = { param($report) $report.Remove('sourceCsvRows') } }
        @{ Case = 'non-array source snapshot'; Change = { param($report) $report.sourceCsvRows['BicepResourceModules.csv'] = @{} } }
        @{ Case = 'missing source identity'; Change = { param($report) $report.sourceCsvRows['BicepResourceModules.csv'][0].Remove('repoURL') } }
        @{ Case = 'hidden removal'; Change = { param($report) $report.csvRowRemovals = @() } }
        @{ Case = 'unapproved generation'; Change = { param($report) $report.csvRowRemovalsForced = $false } }
        @{ Case = 'non-boolean override'; Change = { param($report) $report.csvRowRemovalsForced = 'true' } }
    ) {
        param($Change)
        $root = New-CatalogPublicationFixture
        Set-CatalogPublicationFixtureRows -Root $root -SourceRows @($sourceRow) -OutputRows @() -Force
        $relative = 'v1/migration-report.json'
        $report = Read-AvmCatalogJson -Path (Join-Path $root $relative)
        & $Change $report
        Save-CatalogPublicationFixtureFile -Root $root -RelativePath $relative -Text (ConvertTo-AvmCatalogJson -Value $report)
        { Test-AvmCatalogPublicationBundle -Path $root -Force } | Should -Throw
    }

    It 'checks actual source rows rather than existing previews before publication' {
        $configuration = Read-AvmCatalogConfiguration
        $root = New-CatalogPublicationFixture
        $source = New-CatalogPublicationSourceFixture
        $output = @($configuration.outputs | Where-Object { $_.kind -eq 'csv' -and $_.sourceFile -eq 'BicepResourceModules.csv' })[0]
        $headers = @('ModuleName', 'ModuleDisplayName', 'RepoURL', 'ModuleStatus', 'Description')
        [System.IO.File]::WriteAllText((Join-Path $source "docs/static/module-indexes/test-$($output.file)"),
            (ConvertTo-AvmCatalogCsv -Headers $headers -Rows @($sourceRow)))
        $removals = Get-AvmCatalogPublicationRowRemovals -BundlePath $root -Configuration $configuration -SourceRoot $source
        $removals | Should -HaveCount 0
        [System.IO.File]::WriteAllText((Join-Path $source $output.sourcePath),
            (ConvertTo-AvmCatalogCsv -Headers $headers -Rows @($sourceRow)))
        { Get-AvmCatalogPublicationRowRemovals -BundlePath $root -Configuration $configuration -SourceRoot $source } |
            Should -Throw '*source CSV row evidence does not match*'
        Set-CatalogPublicationFixtureRows -Root $root -SourceRows @($sourceRow) -OutputRows @() -Force
        $removals = Get-AvmCatalogPublicationRowRemovals -BundlePath $root -Configuration $configuration -SourceRoot $source
        $removals | Should -HaveCount 1
        { Assert-AvmCatalogCsvRowRetention -Removals $removals } | Should -Throw '*CSV row removals are blocked*'
        { Assert-AvmCatalogCsvRowRetention -Removals $removals -Force } | Should -Not -Throw
    }

    It 'keeps the source guard when the default manifest overwrites the canonical CSV' {
        $configuration = Read-AvmCatalogConfiguration
        $root = New-CatalogPublicationFixture -Configuration $configuration
        Set-CatalogPublicationFixtureRows -Root $root -SourceRows @($sourceRow) -OutputRows @() -Force -Configuration $configuration
        { Test-AvmCatalogPublicationBundle -Path $root -Configuration $configuration } | Should -Throw '*CSV row removals are blocked*'
        { Test-AvmCatalogPublicationBundle -Path $root -Configuration $configuration -Force } | Should -Not -Throw
        $source = New-CatalogPublicationSourceFixture -Configuration $configuration
        $output = @($configuration.outputs | Where-Object { $_.kind -eq 'csv' -and $_.sourceFile -eq 'BicepResourceModules.csv' })[0]
        $output.targetPath | Should -BeExactly $output.sourcePath
        $headers = @('ModuleName', 'ModuleDisplayName', 'RepoURL', 'ModuleStatus', 'Description')
        $sourcePath = Join-Path $source $output.sourcePath
        [System.IO.File]::WriteAllText($sourcePath, (ConvertTo-AvmCatalogCsv -Headers $headers -Rows @($sourceRow)))
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath).Hash
        $removals = Get-AvmCatalogPublicationRowRemovals -BundlePath $root -Configuration $configuration -SourceRoot $source
        $removals | Should -HaveCount 1
        { Assert-AvmCatalogCsvRowRetention -Removals $removals } | Should -Throw '*CSV row removals are blocked*'
        { Assert-AvmCatalogCsvRowRetention -Removals $removals -Force } | Should -Not -Throw
        (Get-FileHash -LiteralPath $sourcePath).Hash | Should -BeExactly $sourceHash
    }
}

Describe 'Component: module catalog publication merging' -Tag Component {
    BeforeAll {
        Import-Module (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
        $processCommand = & (Get-Module Avm.Authoring) { Get-Command Invoke-AvmProcess }
        $gitPath = (Get-Command git -CommandType Application | Select-Object -First 1).Source

        function Invoke-CatalogFixtureGit {
            param([string] $Root, [string[]] $Arguments)
            $output = & $gitPath -c core.autocrlf=false -c commit.gpgsign=false `
                -c safe.bareRepository=all `
                -c user.name=fixture -c user.email=41898282+github-actions[bot]@users.noreply.github.com `
                -C $Root @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Fixture git failed: $output" }
            return ($output -join "`n")
        }
    }

    BeforeEach {
        $environment = @{
            GITHUB_ACTIONS = 'true'; GITHUB_REPOSITORY = 'Azure/azure-verified-modules-tools'
            GITHUB_REF = 'refs/heads/main'; GITHUB_RUN_ID = '123'; GITHUB_RUN_ATTEMPT = '1'
            AVM_APP_SLUG = 'azure-verified-modules'; GH_TOKEN = 'offline-test-token'
        }
        $saved = @{}
        foreach ($name in $environment.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $environment[$name])
        }
        Mock Import-Module {}
        Mock Get-Command { [pscustomobject]@{ Source = 'fixture-gh' } } -ParameterFilter { $Name -eq 'gh' }
        $mockedGit = $gitPath
        Mock Get-Command ({ [pscustomobject]@{ Source = $mockedGit } }.GetNewClosure()) -ParameterFilter { $Name -eq 'git' }
    }

    AfterEach {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }

    It 'publishes the intended tree and verifies the merge: <Case>' -TestCases @(
        @{ Case = 'new candidate'; Existing = $false; LegacyReport = $false; BaseReport = $false; Failure = '' }
        @{ Case = 'unchanged pending candidate'; Existing = $true; LegacyReport = $false; BaseReport = $false; Failure = '' }
        @{ Case = 'removes previously added report'; Existing = $true; LegacyReport = $true; BaseReport = $false; Failure = '' }
        @{ Case = 'preserves report already on main'; Existing = $true; LegacyReport = $true; BaseReport = $true; Failure = '' }
        @{ Case = 'merge command fails'; Existing = $false; LegacyReport = $false; BaseReport = $false; Failure = 'denied' }
        @{ Case = 'merge remains pending'; Existing = $true; LegacyReport = $false; BaseReport = $false; Failure = 'pending' }
        @{ Case = 'merged head differs'; Existing = $true; LegacyReport = $false; BaseReport = $false; Failure = 'head' }
        @{ Case = 'no changes without a pending candidate'; Existing = $false; LegacyReport = $false; BaseReport = $false; Failure = ''; NoChange = $true }
        @{ Case = 'human edits remain protected'; Existing = $true; LegacyReport = $false; BaseReport = $false; Failure = 'human' }
        @{ Case = 'unrelated files remain protected'; Existing = $true; LegacyReport = $false; BaseReport = $false; Failure = 'unrelated' }
    ) {
        param($Existing, $LegacyReport, $BaseReport, $Failure, $NoChange = $false)

        $configuration = Read-AvmCatalogConfiguration
        $bundle = New-CatalogPublicationFixture
        Set-CatalogPublicationFixtureRows -Root $bundle -SourceRows @() -OutputRows @($sourceRow)
        $source = New-CatalogPublicationSourceFixture
        $paths = Get-AvmCatalogPublicationPaths -Configuration $configuration
        $reportTarget = 'docs/static/module-indexes/v1/migration-report.json'
        if ($BaseReport) {
            $file = Join-Path $source $reportTarget
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
            [System.IO.File]::WriteAllText($file, '{"original":true}')
        }
        if ($NoChange) {
            foreach ($relative in $paths.docs.files.Keys) {
                $file = Join-Path $source $paths.docs.files[$relative]
                $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
                [System.IO.File]::Copy((Join-Path $bundle $relative), $file, $true)
            }
            Set-CatalogPublicationFixtureRows -Root $bundle -SourceRows @($sourceRow) -OutputRows @($sourceRow)
        }
        $null = Invoke-CatalogFixtureGit $source @('init', '-b', 'main')
        $null = Invoke-CatalogFixtureGit $source @('add', '.')
        $null = Invoke-CatalogFixtureGit $source @('commit', '-m', 'base')
        $planPath = Join-Path $bundle 'plan.json'
        $plan = Read-AvmCatalogJson -Path $planPath
        foreach ($path in $paths.docs.basePaths) {
            $file = Join-Path $source $path
            $plan.docs.baseFiles[$path] = if (Test-Path -LiteralPath $file) {
                (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()
            } else { $null }
        }
        [System.IO.File]::WriteAllText($planPath, (ConvertTo-AvmCatalogJson -Value $plan))
        $branch = if ($Existing) { 'automation/module-metadata-sync-existing' } else { 'automation/module-metadata-sync-123-1' }
        if ($Existing) {
            $null = Invoke-CatalogFixtureGit $source @('checkout', '-b', $branch)
            foreach ($relative in $paths.docs.files.Keys) {
                $file = Join-Path $source $paths.docs.files[$relative]
                $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
                [System.IO.File]::Copy((Join-Path $bundle $relative), $file, $true)
            }
            if ($LegacyReport) { [System.IO.File]::WriteAllText((Join-Path $source $reportTarget), '{"unwanted":true}') }
            $null = Invoke-CatalogFixtureGit $source @('add', '.')
            $null = Invoke-CatalogFixtureGit $source @('commit', '-m', 'pending catalog')
            if ($Failure -in @('human', 'unrelated')) {
                [System.IO.File]::WriteAllText((Join-Path $source 'unrelated.txt'), 'not generated')
                $null = Invoke-CatalogFixtureGit $source @('add', '.')
                $arguments = @('commit', '-m', 'unexpected edit')
                if ($Failure -eq 'human') { $arguments += @('--author', 'Human <human@example.invalid>') }
                $null = Invoke-CatalogFixtureGit $source $arguments
            }
        }
        $remote = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.git')
        $null = Invoke-CatalogFixtureGit $source @('clone', '--bare', $source, $remote)
        $state = @{
            Remote = $remote; Branch = $branch; Failure = $Failure; Existing = $Existing
            ProcessCommand = $processCommand
            Head = ''; Calls = [System.Collections.Generic.List[string]]::new()
            PullRequest = @{
                number = 42; html_url = 'https://github.com/Azure/Azure-Verified-Modules/pull/42'
                user = @{ login = 'azure-verified-modules[bot]' }
                head = @{ ref = $branch; repo = @{ full_name = 'Azure/Azure-Verified-Modules' } }
                base = @{ ref = 'main' }
            }
        }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith ({
            param($FilePath, $ArgumentList, $WorkingDirectory, $EnvVars, $IgnoreExitCode)
            if ($FilePath -ne 'fixture-gh') {
                $arguments = @($ArgumentList)
                if ($arguments[0] -eq 'clone') { $arguments[-2] = $state.Remote }
                if ($arguments[0] -eq 'push') { $state.Calls.Add('push') }
                $result = & $state.ProcessCommand -FilePath $FilePath -ArgumentList $arguments -WorkingDirectory $WorkingDirectory `
                    -EnvVars $EnvVars -IgnoreExitCode:$IgnoreExitCode
                if ($arguments[0] -eq 'rev-parse') { $state.Head = $result.StdOut.Trim() }
                return $result
            }
            $response = ''
            if ($ArgumentList[0] -eq 'pr' -and $ArgumentList[1] -eq 'merge') {
                $ArgumentList | Should -Contain '--squash'
                $ArgumentList | Should -Contain '--admin'
                $ArgumentList[[array]::IndexOf($ArgumentList, '--match-head-commit') + 1] | Should -BeExactly $state.Head
                $state.Calls[-1] | Should -BeIn @('POST', 'PATCH')
                $state.Calls.Add('merge')
                if ($state.Failure -eq 'denied') { throw 'fixture merge denied' }
            }
            elseif ($ArgumentList[0] -eq 'api' -and $ArgumentList -contains '--paginate') {
                $response = if ($state.Existing) { '[[' + ($state.PullRequest | ConvertTo-Json -Depth 10 -Compress) + ']]' } else { '[[]]' }
            }
            elseif ($ArgumentList[0] -eq 'api' -and $ArgumentList[2] -in @('POST', 'PATCH')) {
                $state.Calls[-1] | Should -BeExactly 'push'
                $state.Calls.Add($ArgumentList[2])
                $response = $state.PullRequest | ConvertTo-Json -Depth 10 -Compress
            }
            elseif ($ArgumentList[0] -eq 'api' -and $ArgumentList[2] -eq 'GET') {
                $state.Calls.Add('verify')
                $response = @{
                    merged = $state.Failure -ne 'pending'
                    head = @{ sha = if ($state.Failure -eq 'head') { '0' * 40 } else { $state.Head } }
                } | ConvertTo-Json -Depth 10 -Compress
            }
            else { throw "Unexpected GitHub call: $ArgumentList" }
            return [pscustomobject]@{ ExitCode = 0; StdOut = $response; StdErr = '' }
        }.GetNewClosure())

        $invoke = { & (Join-Path $catalogScripts 'Publish-ModuleCatalog.ps1') -BundlePath $bundle -Publish -Confirm:$false }
        if ($Failure -in @('human', 'unrelated')) {
            $expectedError = if ($Failure -eq 'human') { '*contains human commits*' } else { '*outside the publication allow-list*' }
            $invoke | Should -Throw $expectedError
            $state.Calls | Should -Not -Contain 'push'
            $state.Calls | Should -Not -Contain 'merge'
            return
        }
        if ($NoChange) {
            & $invoke
            $state.Calls | Should -HaveCount 0
            return
        }
        if ($Failure -eq 'denied') {
            $invoke | Should -Throw '*fixture merge denied*'
        }
        elseif ($Failure) {
            $invoke | Should -Throw '*not merged at the expected head*'
        }
        else {
            & $invoke
            $state.Calls[-1] | Should -BeExactly 'verify'
        }
        $state.Calls | Should -Contain 'merge'
        $changes = Invoke-CatalogFixtureGit $remote @('diff', '--name-only', 'main', $branch)
        $changes | Should -Not -Match 'migration-report'
        $changes | Should -Match '(?m)^docs/static/module-indexes/BicepResourceModules\.csv$'
        $changes | Should -Not -Match 'test-.*Modules\.csv'
        $changes | Should -Match 'v1/modules.json'
        foreach ($output in $configuration.outputs | Where-Object kind -eq 'csv') {
            $published = Invoke-CatalogFixtureGit $remote @('show', "${branch}:$($output.targetPath)")
            $published.TrimEnd() | Should -BeExactly ([System.IO.File]::ReadAllText((Join-Path $bundle $output.bundlePath)).TrimEnd())
        }
        $state.Calls | Should -Contain $(if ($Existing) { 'PATCH' } else { 'POST' })
    }
}

Describe 'Component: module catalog workflow safety' -Tag Component {
    It 'uses pinned actions, read-only workflow permissions, protected app credentials and no persisted checkout token' {
        $actions = [regex]::Matches($workflow, '(?m)^\s+uses:\s+([^\r\n]+)')
        $actions.Count | Should -BeGreaterThan 0
        foreach ($action in $actions) {
            $action.Groups[1].Value | Should -Match '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+@[0-9a-f]{40}\s+# v[0-9.]+$'
        }
        $workflow | Should -Match '(?m)^permissions:\n  contents: read\n'
        $checkoutCount = [regex]::Matches($workflow, 'uses: actions/checkout@').Count
        [regex]::Matches($workflow, 'persist-credentials: false').Count | Should -Be $checkoutCount
        [regex]::Matches($workflow, 'environment: avm').Count | Should -Be 2
        $workflow | Should -Match 'vars.AVM_APP_CLIENT_ID'
        $workflow | Should -Match 'secrets.AVM_APP_PRIVATE_KEY'
        $workflow | Should -Not -Match '(?m)^\s+(id-token|contents|pull-requests): write'
    }

    It 'defaults manual runs to plan-only and publishes from main without an enable variable' {
        $workflow | Should -Match "(?s)plan_only:.*?type: boolean\s+default: true"
        $workflow | Should -Match "cron: '33 1-23/4 \* \* \*'"
        $publication = $workflow.Substring($workflow.IndexOf("  publish:`n"))
        $workflow | Should -Not -Match 'AVM_METADATA_SYNC_ENABLED'
        $publication | Should -Match "github.ref == 'refs/heads/main'"
        $publication | Should -Match 'inputs.plan_only == false'
        $publication | Should -Match "github.event_name == 'schedule'"
        $workflow | Should -Not -Match 'pull_request_target|repository_dispatch|workflow_run'
        $publication | Should -Match '(?s)repositories: \$\{\{ steps.manifest.outputs.publication-repositories \}\}\s+permission-contents: write\s+permission-pull-requests: write'
        $workflow | Should -Not -Match 'azure-cloud-native/Azure-Verified-Modules-Docs'
    }

    It 'keeps four-hour catalog starts between the repository sync schedules without cancelling active runs' {
        $workflow | Should -Match "(?m)^    - cron: '33 1-23/4 \* \* \*'$"
        $workflow | Should -Match "(?m)^concurrency:\n  group: module-metadata-sync\n  cancel-in-progress: false$"
        $terraform = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.github' 'workflows' 'repository-management-sync.yml'))
        $bicep = [System.IO.File]::ReadAllText((Join-Path $repoRoot '.github' 'workflows' 'repository-management-bicep-sync.yml'))
        $terraform | Should -Match "(?m)^    - cron: '33 \*/4 \* \* 1-5'$"
        $bicep | Should -Match "(?m)^    - cron: '33 2-23/4 \* \* \*'$"
    }

    It 'routes scheduled events directly to publication and merging independently of manual plan-only defaults' {
        $publication = $workflow.Substring($workflow.IndexOf("  publish:`n"))
        $condition = [regex]::Match($publication, '(?s)\n    if: >-\n(.*?)\n    runs-on:').Groups[1].Value
        ($condition.Trim() -replace '\s+', ' ') | Should -BeExactly (
            "github.repository == 'Azure/azure-verified-modules-tools' && " +
            "github.ref == 'refs/heads/main' && " +
            "(github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && inputs.plan_only == false))")
        $step = [regex]::Match($publication,
            '(?s)      - name: Create or update and merge catalog changes\n(.*?)(?=\n  report:)').Groups[1].Value
        $step | Should -Not -BeNullOrEmpty
        $step | Should -Not -Match '(?m)^\s+if:|plan_only|WhatIf'
        $step | Should -Match "'Publish-ModuleCatalog.ps1'"
        $step | Should -Match "-BundlePath \(Join-Path .* 'module-catalog'\) -Publish"
        $step | Should -Match '-Confirm:\$false'
    }

    It 'publishes a complete CSV diff artifact and run summary only for manual plan-only runs' {
        $condition = "github.event_name == 'workflow_dispatch' && inputs.plan_only == true"
        [regex]::Matches($workflow, [regex]::Escape($condition)).Count | Should -Be 2
        $workflow | Should -Match "name: module-metadata-csv-diff"
        $workflow | Should -Match "path: \$\{\{ runner.temp \}\}/catalog-csv-diff"
        $workflow | Should -Match "'New-ModuleCatalogCsvDiff.ps1'"
        $workflow | Should -Match '-SummaryPath \$env:GITHUB_STEP_SUMMARY'
    }

    It 'removes migration modes and permits source-row removal only through an explicit manual force input' {
        $workflow | Should -Not -Match 'bicep_mode|terraform_mode|BICEP_MODE|TERRAFORM_MODE|dual-source'
        $workflow | Should -Match "(?s)      force:\s+description:.*?type: boolean\s+default: false"
        $condition = 'FORCE_CSV_ROW_REMOVALS: ${{ github.event_name == ''workflow_dispatch'' && inputs.force == true }}'
        [regex]::Matches($workflow, [regex]::Escape($condition)).Count | Should -Be 3
        $argument = '-Force:([bool]::Parse($env:FORCE_CSV_ROW_REMOVALS))'
        [regex]::Matches($workflow, [regex]::Escape($argument)).Count | Should -Be 3
        $publisher = [System.IO.File]::ReadAllText((Join-Path $catalogScripts 'Publish-ModuleCatalog.ps1'))
        $publisher.IndexOf('-SourceRoot $root') | Should -BeGreaterThan -1
        $publisher.IndexOf('Assert-AvmCatalogPublicationBase -Root') | Should -BeLessThan $publisher.IndexOf('-SourceRoot $root')
        $publisher.IndexOf('-SourceRoot $root') | Should -BeLessThan $publisher.IndexOf('if ($null -ne $existing)')
        $publisher.IndexOf('-SourceRoot $root') | Should -BeLessThan $publisher.IndexOf('[System.IO.File]::Copy')
        $publisher | Should -Match 'Assert-AvmCatalogCsvRowRetention -Removals \$removals -Force:\$Force'
    }

    It 'allows collection across installed module repositories with no write permissions' {
        $collection = $workflow.Substring(0, $workflow.IndexOf("  publish:`n"))
        $collection | Should -Match 'permission-contents: read'
        $collection | Should -Match 'permission-members: read'
        $collection | Should -Not -Match '(?m)^\s+repositories:'
        $collection | Should -Not -Match 'permission-[a-z-]+: write'
    }

    It 'keeps expression interpolation outside every PowerShell run block and uses only trusted tools scripts' {
        $lines = $workflow -split "`n"
        $blocks = [System.Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^(?<indent>\s*)run: \|$') {
                $indent = $matches.indent.Length
                $body = [System.Collections.Generic.List[string]]::new()
                for ($next = $index + 1; $next -lt $lines.Count; $next++) {
                    if ($lines[$next].Trim().Length -gt 0 -and ($lines[$next].Length - $lines[$next].TrimStart().Length) -le $indent) {
                        break
                    }
                    $body.Add($lines[$next])
                }
                $blocks.Add($body -join "`n")
            }
        }
        $blocks | Should -HaveCount 8
        foreach ($block in $blocks) {
            $block | Should -Not -Match '\$\{\{'
            $block | Should -Match "'tools' 'repository-management' 'module-catalog' 'scripts'"
        }
        $publisher = [System.IO.File]::ReadAllText((Join-Path $catalogScripts 'Publish-ModuleCatalog.ps1'))
        $publisher | Should -Not -Match "'--force'|--force-with-lease|--auto|HEAD:refs/heads/main|git config --global"
        $publisher | Should -Match "'pr', 'merge'"
        $publisher | Should -Match '''--match-head-commit'', \$target.HeadSha'
        $publisher | Should -Match 'HEAD:refs/heads/\$\(\$target.Branch\)'
        $publisher | Should -Match 'GIT_CONFIG_VALUE_3'
        $publisher | Should -Match 'contains human commits'
        $publisher | Should -Not -Match 'AVM_METADATA_SYNC_ENABLED'
    }
}
