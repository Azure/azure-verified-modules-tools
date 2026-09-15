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
        $plan = [ordered]@{ schemaVersion = 1; manifestHash = $Configuration.hash; docs = $null; tools = $null; outputHashes = [ordered]@{} }
        foreach ($role in $paths.Keys) {
            $plan[$role] = [ordered]@{ repository = $paths[$role].repository; baseFiles = [ordered]@{} }
            foreach ($target in $paths[$role].basePaths) {
                $plan[$role].baseFiles[$target] = '1' * 64
            }
            foreach ($relative in $paths[$role].files.Keys) {
                $file = Join-Path $root $relative
                $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
                $text = if ($relative.EndsWith('.csv')) {
                    "ModuleName,ModuleDisplayName,RepoURL,ModuleStatus,Description,Tier,CanonicalType`n"
                }
                elseif ($relative -eq (Get-AvmCatalogOutput -Configuration $Configuration -Kind catalog).bundlePath) {
                    ConvertTo-AvmCatalogJson -Value ([ordered]@{ '$schema' = $catalogSchemaId; schemaVersion = 1; modules = [ordered]@{} })
                }
                elseif ($relative -eq (Get-AvmCatalogOutput -Configuration $Configuration -Kind mar).bundlePath) {
                    "[]`n"
                }
                elseif ($relative -eq (Get-AvmCatalogOutput -Configuration $Configuration -Kind tier-configuration).bundlePath) {
                    "{`"repositoryGroups`": []}`n"
                }
                else {
                    "{`"schemaVersion`": 1}`n"
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
}

Describe 'Component: module catalog publication boundaries' -Tag Component {
    It 'validates a complete fixed-path hashed bundle without network or remote changes' {
        $root = New-CatalogPublicationFixture
        $plan = Test-AvmCatalogPublicationBundle -Path $root
        $plan.docs.repository | Should -BeExactly 'Azure/Azure-Verified-Modules'
        $plan.tools.repository | Should -BeExactly 'Azure/azure-verified-modules-tools'
        $plan.outputHashes.Count | Should -Be 10
    }

    It 'rejects altered output bytes before preparing any remote update' {
        $root = New-CatalogPublicationFixture
        [System.IO.File]::AppendAllText((Join-Path $root 'docs' 'test-BicepResourceModules.csv'), 'tampered')
        { Test-AvmCatalogPublicationBundle -Path $root } | Should -Throw '*hash mismatch*'
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

    It 'rejects a canonical CSV included as an output during preview publication' {
        $root = New-CatalogPublicationFixture
        Copy-Item -LiteralPath (Join-Path $root 'docs' 'test-BicepResourceModules.csv') `
            -Destination (Join-Path $root 'docs' 'BicepResourceModules.csv')
        { Test-AvmCatalogPublicationBundle -Path $root } | Should -Throw '*Unexpected file*'
    }

    It 'requires a base hash for canonical inputs as well as preview outputs' {
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

    It 'permits only tier membership edits and refuses settings or non-tier group changes' {
        $before = [ordered]@{ repositoryGroups = @(
                [ordered]@{ name = 'azure-verified-modules-tier-1'; repositories = @('old'); topics = @('avm-tier-1') },
                [ordered]@{ name = 'canary'; repositories = @('keep'); settings = @{ value = 1 } }
            ) }
        $after = ConvertFrom-Json -InputObject (ConvertTo-AvmCatalogJson -Value $before) -AsHashtable -Depth 100
        $after.repositoryGroups[0].repositories = @('new')
        { Assert-AvmCatalogTierOnlyChange -Before $before -After $after } | Should -Not -Throw
        $after.repositoryGroups[1].settings.value = 2
        { Assert-AvmCatalogTierOnlyChange -Before $before -After $after } | Should -Throw '*only tier repository memberships*'
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
        $workflow | Should -Match "cron: '0 1 \* \* \*'"
        $publication = $workflow.Substring($workflow.IndexOf("  publish:`n"))
        $workflow | Should -Not -Match 'AVM_METADATA_SYNC_ENABLED'
        $publication | Should -Match "github.ref == 'refs/heads/main'"
        $publication | Should -Match 'inputs.plan_only == false'
        $publication | Should -Match "github.event_name == 'schedule'"
        $workflow | Should -Not -Match 'pull_request_target|repository_dispatch|workflow_run'
        $publication | Should -Match '(?s)repositories: \$\{\{ steps.manifest.outputs.publication-repositories \}\}\s+permission-contents: write\s+permission-pull-requests: write'
        $workflow | Should -Not -Match 'azure-cloud-native/Azure-Verified-Modules-Docs'
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
        $blocks | Should -HaveCount 6
        foreach ($block in $blocks) {
            $block | Should -Not -Match '\$\{\{'
            $block | Should -Match "'tools' 'repository-management' 'module-catalog' 'scripts'"
        }
        $publisher = [System.IO.File]::ReadAllText((Join-Path $catalogScripts 'Publish-ModuleCatalog.ps1'))
        $publisher | Should -Not -Match "'--force'|--force-with-lease|pr merge|--auto|HEAD:refs/heads/main|git config --global"
        $publisher | Should -Match 'HEAD:refs/heads/\$\(\$target.Branch\)'
        $publisher | Should -Match 'GIT_CONFIG_VALUE_3'
        $publisher | Should -Match 'contains human commits'
        $publisher | Should -Not -Match 'AVM_METADATA_SYNC_ENABLED'
    }
}
