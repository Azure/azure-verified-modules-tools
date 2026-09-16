#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
    $script:originalModulePath = $env:PSModulePath
    $env:PSModulePath = @((Join-Path $script:repoRoot 'src'), (Join-Path $PSHOME 'Modules')) -join [System.IO.Path]::PathSeparator
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:shared = Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $script:shared 'AvmPreCommit.ps1')
    . (Join-Path $script:shared 'ManagedFilesUpgrade.ps1')
    $script:adapter = Join-Path $script:repoRoot 'repository-management' 'module-metadata' 'MetadataBackfillSync.ps1'
    $script:schemaId = (Get-Content (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json') -Raw |
            ConvertFrom-Json).'$id'
}

AfterAll { $env:PSModulePath = $script:originalModulePath }

Describe 'Component: Terraform metadata workflow scope' -Tag Component {
    It 'keeps one default-off manual input without a separate setup or publication lane' {
        $workflow = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'repository-management-sync.yml') -Raw
        $expression = "METADATA_BACKFILL_ENABLED: \$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.metadata_backfill \|\| false \}\}"
        [regex]::Matches($workflow, $expression).Count | Should -Be 1
        $workflow | Should -Match '(?s)metadata_backfill:.*?default: false\s+type: boolean'
        $workflow | Should -Not -Match 'metadata_update_source|METADATA_UPDATE_SOURCE|!inputs\.metadata_backfill|if \(\$metadataBackfill\)|if \(-not \$metadataBackfill\)'
        $workflow | Should -Not -Match 'app-repository|reviewed-seeds|SeedManifestPath|AVM_SYNC_PAUSED'
        $workflow | Should -Match '(?s)Install-PSResource -Name Avm.Authoring.*?Import-Module Avm.Authoring'
        $workflow | Should -Not -Match "Import-Module \(Join-Path .*?'src' 'Avm.Authoring'"
        foreach ($step in @('Setup Terraform', 'Resolve state backend', 'Azure Login for state \(OIDC\)', 'Download Labels CSV File')) {
            $workflow | Should -Match ("(?m)- name: '\[AVM\] " + $step + "'\r?\n        (?!if:)")
        }
        $workflow | Should -Match "github.event_name != 'workflow_dispatch' \|\| inputs.sync_project_items"
        $workflow | Should -Match "-bamiTestTenantSyncEnabled \(\`$env:AVM_BAMI_TEST_TENANT_SYNC_ENABLED -ceq 'true'\)"
        $workflow | Should -Match "github.repository == 'Azure/azure-verified-modules-tools' && github.ref == 'refs/heads/main' && vars.AVM_BAMI_TEST_TENANT_SYNC_ENABLED == 'true'"
        $ci = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'ci.yml') -Raw
        $ci | Should -Match "if:.*vars\.ARM_CLIENT_ID != ''"
    }

    It 'keeps normal tenant inputs with backfill=<Backfill>' -TestCases @(
        @{ Backfill = $false }
        @{ Backfill = $true }
    ) {
        param($Backfill)
        $workflow = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'repository-management-sync.yml') -Raw
        $start = $workflow.IndexOf('          $testSubscriptionIds = $env:TEST_SUBSCRIPTION_IDS')
        $start | Should -BeGreaterThan 0
        $end = $workflow.IndexOf('          $repoMetaDataJson', $start)
        $end | Should -BeGreaterThan $start
        $probe = [scriptblock]::Create($workflow.Substring($start, $end - $start) +
            "`n[pscustomobject]@{ Subscriptions = `$testSubscriptionIds; Bami = `$bamiSettings }")
        $savedSubscriptions = $env:TEST_SUBSCRIPTION_IDS
        $savedBamiTenant = $env:TEST_BAMI_TENANT_ID
        try {
            $metadataBackfill = $Backfill
            $env:TEST_SUBSCRIPTION_IDS = '["legacy-subscription"]'
            $env:TEST_BAMI_TENANT_ID = 'bami-tenant'
            $result = & $probe
            @($result.Subscriptions) | Should -Be @('legacy-subscription')
            $result.Bami.Count | Should -Be 8
            $result.Bami.TEST_BAMI_TENANT_ID | Should -BeExactly 'bami-tenant'
            $env:TEST_SUBSCRIPTION_IDS = 'invalid JSON'
            { & $probe } | Should -Throw
        }
        finally {
            [Environment]::SetEnvironmentVariable('TEST_SUBSCRIPTION_IDS', $savedSubscriptions)
            [Environment]::SetEnvironmentVariable('TEST_BAMI_TENANT_ID', $savedBamiTenant)
        }
    }
}

Describe 'Component: metadata preparation through normal repository sync' -Tag Component {
    BeforeEach {
        $script:originalEvent = $env:GITHUB_EVENT_NAME
        $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $script:state = @{
            Events = [System.Collections.Generic.List[string]]::new()
            GitCalls = [System.Collections.Generic.List[object]]::new()
            GhCalls = [System.Collections.Generic.List[object]]::new()
            Root = $null
            LocalHead = 'a' * 40
            ExistingMetadata = $null
            Reader = "locals { authored = true }`n"
            RequireMetadata = $true
            Failure = ''
            Metadata = $null
            Codeowners = $null
            Csv = "ModuleName,ModuleDisplayName,Description,RepoURL,PrimaryModuleOwnerGHHandle`navm-ptn-example-repo,Example module,Creates example resources.,https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo,example-owner`n"
        }
        $script:parameters = @{
            orgAndRepoName = 'Azure/terraform-azurerm-avm-ptn-example-repo'
            repoId = 'avm-ptn-example-repo'
            repositoryConfigDir = $TestDrive
            codeOwnersDefaultTeams = @('module-reviewers')
            codeOwnersFileProtectionTeams = @('engineering-reviewers')
            defaultBranch = 'main'
            planOnly = $false
            issueLog = @()
        }
        $fixtureState = $script:state
        Mock Invoke-RepositoryGitHubApi ({
            param($Endpoint)
            if ($Endpoint -cne 'repos/Azure/Azure-Verified-Modules/commits/main') { throw "Unexpected API read: $Endpoint" }
            $fixtureState.Events.Add('index')
            [pscustomobject]@{ sha = 'b' * 40 }
        }.GetNewClosure())
        Mock Get-RepositoryFileAtCommit ({
            param($Repository, $Path, $Sha)
            if ($Repository -cne 'Azure/Azure-Verified-Modules' -or
                $Path -cne 'docs/static/module-indexes/TerraformPatternModules.csv' -or $Sha -cne ('b' * 40)) {
                throw 'Unexpected metadata index read.'
            }
            [pscustomobject]@{ Content = $fixtureState.Csv }
        }.GetNewClosure())
        Mock Get-RepositoryBranchHead { throw 'No metadata-specific branch may be inspected.' }
        Mock Invoke-RepositoryGit {
            $script:state.GitCalls.Add($Arguments)
            if ($Arguments[0] -ceq 'clone') {
                $script:state.Events.Add('clone')
                $script:state.Root = $Arguments[-1]
                $null = New-Item -ItemType Directory -Path $script:state.Root
                [System.IO.File]::WriteAllText((Join-Path $script:state.Root 'main.tf'), "locals { unrelated = true }`n")
                if ($null -ne $script:state.Reader) {
                    [System.IO.File]::WriteAllText((Join-Path $script:state.Root 'main.metadata.tf'), $script:state.Reader)
                }
                if ($null -ne $script:state.ExistingMetadata) {
                    [System.IO.File]::WriteAllText((Join-Path $script:state.Root 'metadata.json'), $script:state.ExistingMetadata)
                }
                if ($script:state.Failure -ceq 'disabled') {
                    $null = New-Item -ItemType Directory -Path (Join-Path $script:state.Root '.avm')
                    [System.IO.File]::WriteAllText((Join-Path $script:state.Root '.avm' '.disable'), '')
                }
                if ($script:state.Failure -ceq 'codeowners') {
                    [System.IO.File]::WriteAllText((Join-Path $script:state.Root '.github'), 'authored file')
                }
                return ''
            }
            if ($Arguments -contains 'commit') {
                $script:state.LocalHead = 'c' * 40
                return ''
            }
            switch ($Arguments[0]) {
                'config' { return '' }
                'rev-parse' { return $script:state.LocalHead }
                'status' {
                    $script:state.Events.Add('status')
                    $script:state.Codeowners = Get-Content (Join-Path $WorkingDirectory '.github' 'CODEOWNERS') -Raw
                    $metadata = Join-Path $WorkingDirectory 'metadata.json'
                    if (Test-Path $metadata) { $script:state.Metadata = Get-Content $metadata -Raw }
                    Get-Content (Join-Path $WorkingDirectory 'managed.txt') -Raw | Should -BeExactly 'normal pre-commit'
                    Get-Content (Join-Path $WorkingDirectory 'main.tf') -Raw | Should -BeExactly "locals { unrelated = true }`n"
                    if ($null -ne $script:state.Reader) {
                        Get-Content (Join-Path $WorkingDirectory 'main.metadata.tf') -Raw | Should -BeExactly $script:state.Reader
                    } else {
                        Test-Path (Join-Path $WorkingDirectory 'main.metadata.tf') | Should -BeFalse
                    }
                    return " M .github/CODEOWNERS`n?? managed.txt"
                }
                'add' { return '' }
                'diff' { return ".github/CODEOWNERS$([char]0)managed.txt$([char]0)" + $(if ($script:state.Metadata) { "metadata.json$([char]0)" }) }
                'write-tree' { return 'd' * 40 }
                'checkout' {
                    $Arguments[-1] | Should -Match '^avm-bot/pre-commit-[0-9]{14}$'
                    return ''
                }
                'push' {
                    $script:state.Events.Add('push')
                    return ''
                }
                default { throw "Unexpected Git command: $($Arguments -join ' ')" }
            }
        }
        Mock Invoke-RepositoryGitHub {
            $script:state.GhCalls.Add($Arguments)
            if ($Arguments[0] -ceq 'pr' -and $Arguments[1] -ceq 'create') {
                $script:state.Events.Add('create')
                return 'https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo/pull/1'
            }
            if ($Arguments[0] -ceq 'pr' -and $Arguments[1] -ceq 'merge') {
                $script:state.Events.Add('merge')
                if ($script:state.Failure -ceq 'merge') { throw 'standard merge denied' }
                return ''
            }
            throw "Unexpected GitHub command: $($Arguments -join ' ')"
        }
        Mock Resolve-AvmManagedFilesUpgradeDecision { @{ Upgrade = $forceFileUpdate; Reason = 'standard upgrade decision' } }
        Mock Invoke-AvmPreCommitWithUpgradeRetry {
            $script:state.Events.Add('pre-commit')
            if ($script:state.RequireMetadata) {
                $validation = Test-AvmModuleMetadata -Path (Get-Location).Path -Ecosystem terraform -ModuleType pattern -SkipModuleVersionCheck
                $validation.Status | Should -BeExactly 'pass'
            }
            [System.IO.File]::WriteAllText((Join-Path (Get-Location).Path 'managed.txt'), 'normal pre-commit')
            if ($script:state.Failure -ceq 'pre-commit') {
                return [pscustomobject]@{ Status = 'fail'; Steps = @([pscustomobject]@{ Step = 'format'; Status = 'fail'; Error = 'formatter failed' }) }
            }
            [pscustomobject]@{ Status = 'pass'; Steps = @() }
        }
    }

    AfterEach { [Environment]::SetEnvironmentVariable('GITHUB_EVENT_NAME', $script:originalEvent) }

    It 'preserves ordinary sync with backfill off and still forwards forced upgrades' {
        $script:state.RequireMetadata = $false
        $result = Invoke-AvmPreCommitForRepository @script:parameters -forceFileUpdate $true
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $script:state.Events | Should -Be @('clone', 'pre-commit', 'status', 'push', 'create', 'merge')
        $script:state.Metadata | Should -BeNullOrEmpty
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
        Should -Invoke Invoke-AvmPreCommitWithUpgradeRetry -Exactly 1 -ParameterFilter { $upgradeManagedFiles }
    }

    It 'creates real metadata before normal pre-commit, CODEOWNERS and publication with plan=<Plan>' -TestCases @(
        @{ Plan = $false }
        @{ Plan = $true }
    ) {
        param($Plan)
        $script:parameters.planOnly = $Plan
        $script:state.Reader = $null
        $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $result.HasChanges | Should -BeTrue
        $metadata = $script:state.Metadata | ConvertFrom-Json
        $metadata.moduleDescription | Should -BeExactly 'Creates example resources.'
        $metadata.canonicalType | Should -BeExactly 'example/repo'
        $metadata.owners | Should -Be @('example-owner')
        $script:state.Codeowners | Should -Match '\* @Azure/module-reviewers'
        $script:state.Codeowners | Should -Match 'metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners'
        Should -Invoke Get-RepositoryBranchHead -Exactly 0
        Test-Path -LiteralPath $script:state.Root | Should -BeFalse
        if ($Plan) {
            $script:state.Events | Should -Be @('clone', 'index', 'pre-commit', 'status')
            Should -Invoke Invoke-RepositoryGitHub -Exactly 0
            Should -Invoke Invoke-RepositoryGit -Exactly 0 -ParameterFilter { $Arguments[0] -in @('add', 'checkout', 'push') -or $Arguments -contains 'commit' }
        } else {
            $script:state.Events | Should -Be @('clone', 'index', 'pre-commit', 'status', 'push', 'create', 'merge')
            Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter {
                $Arguments -contains 'create' -and $Arguments -contains 'chore: run avm pre-commit [skip ci]' -and $Arguments -notcontains '--no-maintainer-edit'
            }
            Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter {
                $Arguments -contains 'merge' -and $Arguments -contains '--squash' -and $Arguments -contains '--admin' -and
                $Arguments -contains '--match-head-commit' -and $Arguments -contains ('c' * 40) -and
                $Arguments -contains '--delete-branch' -and $MaxRetries -eq 5
            }
        }
    }

    It 'validates existing metadata without replacing it or an authored Terraform reader' {
        $script:state.ExistingMetadata = @{
            '$schema' = $script:schemaId
            moduleDisplayName = 'Authored name'
            moduleDescription = 'Authored description.'
            canonicalType = 'example/authored'
            telemetryIdPrefix = '46d3xtrf.ptn.example-repo'
            owners = @('authored-owner')
        } | ConvertTo-Json
        $null = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
        $script:state.Metadata | Should -BeExactly $script:state.ExistingMetadata
        $script:state.Events[-1] | Should -BeExactly 'merge'
    }

    It 'stops publication on <Failure> while keeping normal preparation ordering' -TestCases @(
        @{ Failure = 'invalid metadata'; Expected = '*No files were written*'; Prepared = 0 }
        @{ Failure = 'missing description'; Expected = '*No files were written*'; Prepared = 0 }
        @{ Failure = 'disabled'; Expected = '*disabled*'; Prepared = 0 }
        @{ Failure = 'pre-commit'; Expected = '*formatter failed*'; Prepared = 1 }
        @{ Failure = 'codeowners'; Expected = '*'; Prepared = 1 }
    ) {
        param($Failure, $Expected, $Prepared)
        $script:state.Failure = $Failure
        if ($Failure -ceq 'invalid metadata') { $script:state.ExistingMetadata = '{}' }
        if ($Failure -ceq 'missing description') { $script:state.Csv = $script:state.Csv.Replace('Creates example resources.', '') }
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw $Expected
        Should -Invoke Invoke-AvmPreCommitWithUpgradeRetry -Exactly $Prepared
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
        Should -Invoke Invoke-RepositoryGit -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'push' -or $Arguments -contains 'commit' }
        Test-Path -LiteralPath $script:state.Root | Should -BeFalse
    }

    It 'fails an index/script dependency error before ordinary pre-commit or publication' {
        Mock Get-RepositoryFileAtCommit { throw 'metadata index unavailable' }
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*metadata index unavailable*'
        Should -Invoke Invoke-AvmPreCommitWithUpgradeRetry -Exactly 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'rejects an unpinned index response before reading its CSV' {
        Mock Invoke-RepositoryGitHubApi { [pscustomobject]@{ sha = 'main' } }
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*commit is missing or invalid*'
        Should -Invoke Get-RepositoryFileAtCommit -Exactly 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'fails closed and cleans up external request files on worker <Failure>' -TestCases @(
        @{ Failure = 'error'; Exit = 1; Expected = '*worker failed*' }
        @{ Failure = 'missing result'; Exit = 0; Expected = '*result.json*' }
        @{ Failure = 'invalid result'; Exit = 0; Expected = '*successful result*' }
    ) {
        param($Failure, $Exit, $Expected)
        $workerState = @{ Failure = $Failure; Exit = $Exit; Temporary = $null; Root = $null }
        Mock Invoke-RepositorySyncProcess ({
            param($Command, $Arguments, $WorkingDirectory, $EnvVars)
            $workerState.Temporary = Split-Path $Arguments[5] -Parent
            $workerState.Root = $WorkingDirectory
            $Arguments[0..2] | Should -Be @('-NoProfile', '-NonInteractive', '-File')
            $Arguments[4] | Should -BeExactly '-InputPath'
            $Arguments[6] | Should -BeExactly '-OutputPath'
            $workerState.Temporary.StartsWith($WorkingDirectory, [StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
            $EnvVars.GH_TOKEN | Should -BeNullOrEmpty
            $request = Get-Content $Arguments[5] -Raw | ConvertFrom-Json
            $request.RepositoryRoot | Should -BeExactly $WorkingDirectory
            if ($workerState.Failure -ceq 'invalid result') {
                [System.IO.File]::WriteAllText($Arguments[7], '{"Status":"planned"}')
            }
            [pscustomobject]@{ ExitCode = $workerState.Exit; StdOut = 'worker diagnostic'; StdErr = $(if ($workerState.Exit) { 'worker failed' } else { '' }) }
        }.GetNewClosure())
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw $Expected
        Should -Invoke Invoke-AvmPreCommitWithUpgradeRetry -Exactly 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
        $workerState.Temporary | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $workerState.Temporary | Should -BeFalse
        Test-Path -LiteralPath $workerState.Root | Should -BeFalse
    }

    It 'surfaces the normal merge failure without another publication or bypass path' {
        $script:state.Failure = 'merge'
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*standard merge denied*'
        Should -Invoke Invoke-RepositoryGitHub -Exactly 2
        $script:state.Events[-2..-1] | Should -Be @('create', 'merge')
    }

    It 'preserves WhatIf without creating a checkout or invoking metadata' {
        & {
            $WhatIfPreference = $true
            $result = Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true
            $result.HasChanges | Should -BeFalse
        }
        Should -Invoke Invoke-RepositoryGit -Exactly 0
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 0
    }

    It 'rejects non-manual activation before any repository access: <Event>' -TestCases @(
        @{ Event = 'schedule' }, @{ Event = 'repository_dispatch' }, @{ Event = 'push' }, @{ Event = 'workflow_run' }
    ) {
        param($Event)
        $env:GITHUB_EVENT_NAME = $Event
        { Invoke-AvmPreCommitForRepository @script:parameters -metadataBackfill $true } | Should -Throw '*manual-only*'
        Should -Invoke Invoke-RepositoryGit -Exactly 0
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 0
    }
}

Describe 'Component: metadata backfill worker isolation and errors' -Tag Component {
    BeforeEach {
        $script:fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:target = Join-Path $script:fixture 'repository'
        $null = New-Item -ItemType Directory -Path $script:target -Force
        [System.IO.File]::WriteAllText((Join-Path $script:target 'main.tf'), "locals { unrelated = true }`n")
        $script:inputPath = Join-Path $script:fixture 'input.json'
        $script:outputPath = Join-Path $script:fixture 'result.json'
        @{
            RepositoryRoot = $script:target
            Repository = 'Azure/terraform-azurerm-avm-ptn-example-repo'
            LegacyRecord = @(@{
                ModuleName = 'avm-ptn-example-repo'
                ModuleDisplayName = 'Example'
                Description = 'Creates example resources.'
                RepoURL = 'https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo'
            })
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:inputPath
        $script:workerSource = Join-Path $script:repoRoot 'repository-management' 'module-metadata' 'Invoke-ModuleMetadataBackfillWorker.ps1'
        $script:worker = $script:workerSource
        $script:executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    }

    It 'imports checkout metadata without an installed module and preserves <Description>' -TestCases @(
        @{ Description = 'Creates example resources.' }
        @{ Description = '2024-07-01T00:30:00Z' }
    ) {
        param($Description)
        $request = Get-Content $script:inputPath -Raw | ConvertFrom-Json -AsHashtable
        $request.LegacyRecord[0].Description = $Description
        $request | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:inputPath
        $process = Invoke-RepositorySyncProcess -Command $script:executable -Arguments @(
            '-NoProfile', '-NonInteractive', '-File', $script:worker, '-InputPath', $script:inputPath, '-OutputPath', $script:outputPath
        ) -EnvVars @{ PSModulePath = Join-Path $PSHOME 'Modules'; AVM_OFFLINE = '1'; GH_TOKEN = $null }
        $process.ExitCode | Should -Be 0 -Because $process.StdErr
        $result = Get-Content $script:outputPath -Raw | ConvertFrom-Json
        $result.Status | Should -BeExactly 'pass'
        $result.Modules[0].PlannedFiles | Should -Be @('metadata.json')
        $metadata = Get-AvmModuleMetadata -Path $script:target -Ecosystem terraform -ModuleType pattern -SkipModuleVersionCheck
        $metadata.Metadata.canonicalType | Should -BeExactly 'example/repo'
        $metadata.Metadata.moduleDescription | Should -BeExactly $Description
        Test-Path (Join-Path $script:target 'main.metadata.tf') | Should -BeFalse
    }

    It 'surfaces <Failure> and warnings without writing a success result' -TestCases @(
        @{ Failure = 'terminating errors'; Code = "throw 'worker terminating failure'"; Expected = '*worker terminating failure*' }
        @{ Failure = 'nonterminating errors'; Code = "Write-Error 'worker nonterminating failure' -ErrorAction Continue; [pscustomobject]@{ Status = 'pass' }"; Expected = '*worker nonterminating failure*' }
        @{ Failure = 'missing results'; Code = ''; Expected = '*successful result*' }
        @{ Failure = 'unsuccessful results'; Code = "[pscustomobject]@{ Status = 'planned' }"; Expected = '*successful result*' }
        @{ Failure = 'multiple results'; Code = "[pscustomobject]@{ Status = 'pass' }; [pscustomobject]@{ Status = 'pass' }"; Expected = '*successful result*' }
    ) {
        param($Code, $Expected)
        $tools = Join-Path $script:fixture 'tools'
        $adapter = Join-Path $tools 'repository-management' 'module-metadata'
        $module = Join-Path $tools 'src' 'Avm.Authoring'
        $null = New-Item -ItemType Directory -Path $adapter, $module -Force
        Copy-Item -LiteralPath $script:workerSource -Destination $adapter
        [System.IO.File]::WriteAllText((Join-Path $module 'Avm.Authoring.psd1'), "@{ RootModule = 'Avm.Authoring.psm1'; ModuleVersion = '0.0.1' }")
        Copy-Item -LiteralPath (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Private' 'Metadata' 'ConvertFrom-AvmMetadataJson.ps1') -Destination $module
        [System.IO.File]::WriteAllText((Join-Path $module 'Avm.Authoring.psm1'), ". (Join-Path `$PSScriptRoot 'ConvertFrom-AvmMetadataJson.ps1')`n")
        $scriptBody = @'
[CmdletBinding(SupportsShouldProcess)]
param($RepositoryRoot, $Repository, $Ecosystem, $LegacyRecord)
Write-Warning 'worker warning'
'@
        [System.IO.File]::WriteAllText((Join-Path $adapter 'Invoke-ModuleMetadataBackfill.ps1'), $scriptBody + "`n$Code`n")
        $process = Invoke-RepositorySyncProcess -Command $script:executable -Arguments @(
            '-NoProfile', '-NonInteractive', '-File', (Join-Path $adapter 'Invoke-ModuleMetadataBackfillWorker.ps1'),
            '-InputPath', $script:inputPath, '-OutputPath', $script:outputPath
        ) -EnvVars @{ PSModulePath = Join-Path $PSHOME 'Modules'; AVM_OFFLINE = '1'; GH_TOKEN = $null }
        $process.ExitCode | Should -Not -Be 0
        $process.StdErr | Should -BeLike $Expected
        $process.StdOut | Should -Match 'worker warning'
        Test-Path $script:outputPath | Should -BeFalse
        Test-Path (Join-Path $script:target 'metadata.json') | Should -BeFalse
    }
}

Describe 'Component: metadata backfill isolated module loading' -Tag Component {
    It 'uses checkout metadata without changing installed authoring commands that lack metadata APIs' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $child = @'
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$repository = 'Azure/terraform-azurerm-avm-ptn-example-repo'
$root = $env:BACKFILL_TEST_ROOT
if (Get-Module Avm.Authoring) { throw 'The child must start without a loaded authoring module.' }
if (@(Get-Module -ListAvailable Avm.Authoring).Count -ne 0) { throw 'The source module must not be discoverable by name.' }
. (Join-Path $env:BACKFILL_TOOLS_ROOT 'repository-management' 'repository-sync' 'scripts' 'lib' 'AvmPreCommit.ps1')
$installedParent = Join-Path $root 'installed'
$null = New-Item -ItemType Directory -Path $installedParent
Copy-Item -LiteralPath (Join-Path $env:BACKFILL_TOOLS_ROOT 'src' 'Avm.Authoring') -Destination $installedParent -Recurse
$installedRoot = Join-Path $installedParent 'Avm.Authoring'
foreach ($name in @('Get-AvmModuleMetadata.ps1', 'Initialize-AvmModuleMetadata.ps1', 'Test-AvmModuleMetadata.ps1')) {
    Remove-Item -LiteralPath (Join-Path $installedRoot 'Public' $name)
}
[System.IO.File]::WriteAllText((Join-Path $installedRoot 'Avm.Authoring.psd1'),
    "@{ RootModule = 'Avm.Authoring.psm1'; ModuleVersion = '0.0.1'; FunctionsToExport = @('Invoke-AvmPreCommit') }")
[System.IO.File]::AppendAllText((Join-Path $installedRoot 'Avm.Authoring.psm1'), @"

function Invoke-AvmPreCommit {
    param(`$Ecosystem, `$RepoId, `$ConfigLocalPath, [switch] `$Upgrade)
    if (`$Ecosystem -cne 'terraform' -or `$RepoId -cne 'avm-ptn-example-repo') { throw 'Wrong normal pre-commit parameters.' }
    `$metadata = Get-Content -LiteralPath (Join-Path (Get-Location).Path 'metadata.json') -Raw | ConvertFrom-Json
    if (`$metadata.moduleDescription -cne 'Creates example resources.') { throw 'Normal pre-commit did not receive prepared metadata.' }
    [pscustomobject]@{ Status = 'pass'; Steps = @(); Origin = 'installed-release' }
}
Export-ModuleMember -Function Invoke-AvmPreCommit
"@)
$env:PSModulePath = @($installedParent, (Join-Path $PSHOME 'Modules')) -join [System.IO.Path]::PathSeparator
Import-Module Avm.Authoring -ErrorAction Stop
function Invoke-RepositoryGitHubApi {
    param($Endpoint)
    if ($Endpoint -cne 'repos/Azure/Azure-Verified-Modules/commits/main') { throw "Unexpected API read: $Endpoint" }
    [pscustomobject]@{ sha = 'a' * 40 }
}
function Get-RepositoryFileAtCommit {
    param($Repository, $Path, $Sha)
    if ($Repository -cne 'Azure/Azure-Verified-Modules' -or
        $Path -cne 'docs/static/module-indexes/TerraformPatternModules.csv' -or $Sha -cne ('a' * 40)) {
        throw 'Unexpected metadata index read.'
    }
    [pscustomobject]@{ Content = "ModuleName,ModuleDisplayName,Description,RepoURL,PrimaryModuleOwnerGHHandle`navm-ptn-example-repo,Example module,Creates example resources.,https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo,example-owner`n" }
}
function Invoke-RepositoryGit { throw 'No Git operation is permitted in isolated metadata preparation.' }
function Invoke-RepositoryGitHub { throw 'No remote mutation is permitted in isolated metadata preparation.' }
function Install-PSResource { throw 'The hook must not install modules.' }
function Update-PSResource { throw 'The hook must not upgrade modules.' }
$beforeModule = Get-Module Avm.Authoring
$beforeCommand = Get-Command Invoke-AvmPreCommit -ListImported -ErrorAction SilentlyContinue
$beforePath = $env:PSModulePath
if (Get-Command Initialize-AvmModuleMetadata -ListImported -ErrorAction SilentlyContinue) { throw 'The caller must lack metadata APIs.' }
[System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), "locals { unrelated = true }`n")
$hook = Join-Path $env:BACKFILL_TOOLS_ROOT 'repository-management' 'module-metadata' 'MetadataBackfillSync.ps1'
$result = & $hook -Context @{ Root = $root; Repository = @{ full_name = $repository }; PlanOnly = $false }
if ($result.Status -cne 'pass' -or -not $result.Changed) { throw 'Real checkout metadata preparation failed.' }
$afterModule = Get-Module Avm.Authoring
$afterCommand = Get-Command Invoke-AvmPreCommit -ListImported -ErrorAction SilentlyContinue
if (-not [object]::ReferenceEquals($beforeModule, $afterModule)) { throw 'The hook replaced the caller module.' }
if ([bool]$beforeCommand -ne [bool]$afterCommand -or
    ($beforeCommand -and ($beforeCommand.Module.Path -cne $afterCommand.Module.Path -or
        $beforeCommand.Definition -cne $afterCommand.Definition))) { throw 'The hook changed the caller command.' }
if ($env:PSModulePath -cne $beforePath) { throw 'The hook changed module discovery.' }
if (Get-Command Initialize-AvmModuleMetadata -ListImported -ErrorAction SilentlyContinue) { throw 'The hook leaked checkout commands.' }
Push-Location $root
try {
    $normal = Invoke-AvmPreCommitWithUpgradeRetry -repoId 'avm-ptn-example-repo' -repositoryConfigDir $root
    if ($normal.Origin -cne 'installed-release') { throw 'Normal sync did not retain its installed authoring implementation.' }
} finally { Pop-Location }
if (Test-Path (Join-Path $root 'main.metadata.tf')) { throw 'The hook generated a Terraform reader.' }
[pscustomobject]@{
    Result = $result
    NormalOrigin = $normal.Origin
    Metadata = Get-Content -LiteralPath (Join-Path $root 'metadata.json') -Raw | ConvertFrom-Json
} | ConvertTo-Json -Depth 10 -Compress
'@
        $module = Get-Module Avm.Authoring | Select-Object -First 1
        $output = & $module {
            param($Code, $ToolsRoot, $FixtureRoot)
            $executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
            Invoke-AvmProcess -FilePath $executable -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $Code) `
                -TimeoutSec 90 -IgnoreExitCode -EnvVars @{
                    BACKFILL_TOOLS_ROOT = $ToolsRoot
                    BACKFILL_TEST_ROOT = $FixtureRoot
                    PSModulePath = Join-Path $PSHOME 'Modules'
                    AVM_OFFLINE = '1'
                    GITHUB_EVENT_NAME = 'workflow_dispatch'
                    GH_TOKEN = $null
                    GITHUB_TOKEN = $null
                }
        } $child $script:repoRoot $root
        $output.ExitCode | Should -Be 0 -Because $output.StdErr
        $report = ($output.StdOut.TrimEnd() -split '\r?\n')[-1] | ConvertFrom-Json
        $report.Result.Modules[0].PlannedFiles | Should -Be @('metadata.json')
        $report.Metadata.canonicalType | Should -BeExactly 'example/repo'
        $report.Metadata.owners | Should -Be @('example-owner')
        $report.NormalOrigin | Should -BeExactly 'installed-release'
    }
}
