BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:shared = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $script:codeowners = Join-Path $script:root 'repository-management' 'bicep-codeowners-sync'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:shared 'RepositoryFileSync.ps1')
    . (Join-Path $script:shared 'AvmPreCommit.ps1')
    . (Join-Path $script:shared 'ManagedFilesUpgrade.ps1')
    . (Join-Path $script:codeowners 'scripts' 'lib' 'Codeowners.ps1')
    . (Join-Path $script:codeowners 'scripts' 'lib' 'CodeownersSync.ps1')
    $script:terraformOwnership = @{
        codeOwnersDefaultTeams = @('module-reviewers')
        codeOwnersFileProtectionTeams = @('engineering-reviewers')
    }
    $script:template = Get-Content -LiteralPath (Join-Path $script:codeowners 'CODEOWNERS.template') -Raw
    $script:content = $script:template.Replace('__AVM_MODULE_OWNERS__', '/avm/res/test/module/ @alice @Azure/azure-verified-modules-module-owners')
    $script:snapshot = [pscustomobject]@{
        Content = $script:content
        BlobSha = Get-RepositoryGitBlobSha -Bytes ([System.Text.Encoding]::UTF8.GetBytes($script:content))
        SourceSha = 'f' * 40
        ModuleCount = 1
    }

    function New-SyncTestActor {
        [pscustomobject]@{ login = 'azure-verified-modules[bot]'; id = 187664033; type = 'Bot' }
    }

    function New-SyncTestContext {
        @{
            Repository = [pscustomobject]@{ id = 42; full_name = 'Azure/bicep-registry-modules' }
            DefaultBranch = 'main'
            Branch = 'avm-bot/bicep-codeowners-sync'
            BaseSha = 'a' * 40
            HeadSha = 'b' * 40
            ExpectedActor = New-SyncTestActor
            AllowedPaths = @('.github/CODEOWNERS')
            ChangedPaths = @('.github/CODEOWNERS')
            State = @{ Template = $script:template; Snapshot = $script:snapshot }
            PlanOnly = $true
            Phase = 'Candidate'
        }
    }

    function New-SyncTestPullRequest {
        [pscustomobject]@{
            number = 123
            html_url = 'https://github.com/Azure/bicep-registry-modules/pull/123'
            user = New-SyncTestActor
            auto_merge = $null
            state = 'open'
            merged = $false
            draft = $false
            base = [pscustomobject]@{ ref = 'main'; sha = 'a' * 40; repo = [pscustomobject]@{ id = 42; full_name = 'Azure/bicep-registry-modules'; default_branch = 'main' } }
            head = [pscustomobject]@{ ref = 'avm-bot/bicep-codeowners-sync'; sha = 'b' * 40; repo = [pscustomobject]@{ id = 42; full_name = 'Azure/bicep-registry-modules'; fork = $false } }
        }
    }
}

Describe 'Both repository-sync entry points use one existing publication core' {
    BeforeEach {
        Mock Import-Module {}
        Mock Invoke-RepositoryFileSync { @{ HasChanges = $true; Status = 'Planned'; PullRequestUrl = $null; HeadSha = $null } }
        Mock Get-AvmBicepCodeownersSnapshot { $script:snapshot }
        Mock Set-TerraformCodeowners {}
        Mock Invoke-RepositoryGit { throw 'A caller must delegate Git operations to the shared core.' }
        Mock Invoke-RepositoryGitHub { throw 'A caller must delegate publication to the shared core.' }
    }

    It 'routes the existing Terraform driver and CODEOWNERS adapter through the same core function' {
        $legacy = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $true -issueLog @('existing issue')
        $generated = Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly
        $legacy.IssueLog | Should -Be @('existing issue')
        $generated.SourceSha | Should -Be $script:snapshot.SourceSha
        Should -Invoke Invoke-RepositoryFileSync -Exactly 2
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter {
            $Repository -ceq 'Azure/terraform-test' -and $DefaultBranch -ceq 'main' -and
            $PlanOnly -and -not $ReviewOnly -and -not $KeepBranch -and -not $StableBranch -and -not $VerifyCandidate -and
            $null -ne $Prepare -and $State.RepoId -ceq 'avm-res-test' -and $State.RepositoryConfigDir -ceq 'configuration' -and
            $State.CodeownersContent -cmatch '(?m)^\* @Azure/module-reviewers$' -and
            $State.CodeownersContent -cmatch '(?m)^\.github/CODEOWNERS @Azure/engineering-reviewers$'
        }
        Should -Invoke Invoke-RepositoryFileSync -Exactly 1 -ParameterFilter {
            $Repository -ceq 'Azure/bicep-registry-modules' -and $DefaultBranch -ceq 'main' -and
            $PlanOnly -and -not $ReviewOnly -and $KeepBranch -and $VerifyCandidate -and $StableBranch -ceq 'avm-bot/bicep-codeowners-sync' -and
            $GeneratedFiles.Count -eq 1 -and $GeneratedFiles['.github/CODEOWNERS'] -ceq $script:snapshot.Content -and
            ($AllowedPaths -join ',') -ceq '.github/CODEOWNERS' -and $ExpectedActor.id -eq 187664033 -and
            $null -ne $ValidateChange -and -not $Prepare
        }
        Should -Invoke Invoke-RepositoryGit -Times 0
        Should -Invoke Invoke-RepositoryGitHub -Times 0
    }

    It 'preserves the exact legacy return shape for no-change, plan, and apply outcomes' -ForEach @(
        @{ CoreStatus = 'NoChange'; Changed = $false; Plan = $false }
        @{ CoreStatus = 'Planned'; Changed = $true; Plan = $true }
        @{ CoreStatus = 'Merged'; Changed = $true; Plan = $false }
    ) {
        $script:coreResult = @{ HasChanges = $Changed; Status = $CoreStatus; PullRequestUrl = 'unused'; HeadSha = 'unused' }
        Mock Invoke-RepositoryFileSync { $script:coreResult }
        $issues = @([pscustomobject]@{ message = 'existing issue' })
        $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $Plan -issueLog $issues
        $result | Should -BeOfType [hashtable]
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $result.HasChanges | Should -Be $Changed
        [object]::ReferenceEquals($result.IssueLog, $issues) | Should -BeTrue
    }

    It 'imports the installed module before the shared core can clone in a fresh process' {
        $script:sequence = [System.Collections.Generic.List[string]]::new()
        Mock Import-Module { $script:sequence.Add('import') }
        Mock Invoke-RepositoryFileSync { $script:sequence.Add('clone'); @{ HasChanges = $false } }
        $null = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -defaultBranch main -issueLog @()
        $script:sequence.ToArray() | Should -Be @('import', 'clone')
        Should -Invoke Import-Module -Exactly 1 -ParameterFilter { $Name -ceq 'Avm.Authoring' -and $ErrorAction -eq 'Stop' }
    }

    It 'keeps the existing Terraform preparation and upgrade behavior in its adapter' {
        Mock Remove-AvmMetadataFileConflict { $false }
        Mock Resolve-AvmManagedFilesUpgradeDecision { @{ Upgrade = $true; Reason = 'forced update' } }
        Mock Invoke-AvmPreCommitWithUpgradeRetry { [pscustomobject]@{ Status = 'pass'; Steps = @() } }
        Mock Invoke-RepositoryFileSync {
            param($Prepare, $State, $PlanOnly)
            & $Prepare @{ Root = 'isolated-clone'; Repository = @{ full_name = 'Azure/terraform-test' }; State = $State; PlanOnly = $PlanOnly }
            @{ HasChanges = $true; Status = 'Planned' }
        }
        $null = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $true -forceFileUpdate $true -issueLog @()
        Should -Invoke Resolve-AvmManagedFilesUpgradeDecision -Exactly 1 -ParameterFilter { $forceFileUpdate -and $repoRoot -eq 'isolated-clone' }
        Should -Invoke Invoke-AvmPreCommitWithUpgradeRetry -Exactly 1 -ParameterFilter {
            $repoId -eq 'avm-res-test' -and $repositoryConfigDir -eq 'configuration' -and $upgradeManagedFiles
        }
        Should -Invoke Set-TerraformCodeowners -Exactly 1 -ParameterFilter {
            $RepositoryRoot -ceq 'isolated-clone' -and
            $Content -cmatch '(?m)^\* @Azure/module-reviewers$' -and
            $Content -cmatch '(?m)^\.github/CODEOWNERS @Azure/engineering-reviewers$'
        }
    }

    It 'does not write CODEOWNERS when the authoring gauntlet fails' {
        Mock Remove-AvmMetadataFileConflict { $false }
        Mock Resolve-AvmManagedFilesUpgradeDecision { @{ Upgrade = $false; Reason = 'current pin' } }
        Mock Invoke-AvmPreCommitWithUpgradeRetry { [pscustomobject]@{ Status = 'fail'; Steps = @() } }
        Mock Invoke-RepositoryFileSync {
            param($Prepare, $State, $PlanOnly)
            & $Prepare @{ Root = 'isolated-clone'; Repository = @{ full_name = 'Azure/terraform-test' }; State = $State; PlanOnly = $PlanOnly }
        }
        { Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' `
            -repoId 'avm-res-test' -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $true -issueLog @() } |
            Should -Throw "*avm pre-commit returned status 'fail'*"
        Should -Invoke Set-TerraformCodeowners -Times 0
    }

    It 'requires explicit ownership inputs instead of silently dropping file protection' {
        $command = Get-Command Invoke-AvmPreCommitForRepository
        foreach ($name in @('codeOwnersDefaultTeams', 'codeOwnersFileProtectionTeams')) {
            $parameter = $command.Parameters[$name]
            @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }) |
                Should -HaveCount 1
        }
    }

    It 'rejects invalid ownership before the shared core can clone or publish' {
        { Invoke-AvmPreCommitForRepository -codeOwnersDefaultTeams @('bad team') -codeOwnersFileProtectionTeams @('reviewers') `
            -orgAndRepoName 'Azure/terraform-test' -defaultBranch main -issueLog @() } | Should -Throw '*team slug*'
        Should -Invoke Invoke-RepositoryFileSync -Times 0
    }

    It 'retains the production driver call and removes the parallel CODEOWNERS engine' {
        $driver = Get-Content -LiteralPath (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositorySync.ps1') -Raw
        $driver | Should -Match 'Invoke-AvmPreCommitForRepository'
        $driver | Should -Match '-codeOwnersDefaultTeams\s+\$settings\.CodeOwnersDefaultTeams'
        $driver | Should -Match '-codeOwnersFileProtectionTeams\s+\$settings\.CodeOwnersFileProtectionTeams'
        Test-Path -LiteralPath (Join-Path $script:codeowners 'scripts' 'lib' 'GitHubSync.ps1') | Should -BeFalse
        $adapter = Get-Content -LiteralPath (Join-Path $script:codeowners 'scripts' 'lib' 'CodeownersSync.ps1') -Raw
        $adapter | Should -Not -Match "'pr', 'create'|'pr', 'merge'|'commit-tree'|'push'|/git/refs|Invoke-AvmCodeownersApi"
    }

    It 'loads the standalone shared library without importing the Terraform adapter' {
        $scriptPath = Join-Path $script:shared 'RepositoryFileSync.ps1'
        $loaded = & {
            param($Path)
            . $Path
            (Get-Command Invoke-RepositoryFileSync -CommandType Function).ScriptBlock.File
        } $scriptPath
        $loaded | Should -BeExactly $scriptPath
        $core = Get-Content -LiteralPath $scriptPath -Raw
        $core | Should -Not -Match 'AvmPreCommit\.ps1|function Invoke-AvmPreCommitForRepository|Invoke-AvmPreCommitWithUpgradeRetry'
        $terraform = Get-Content -LiteralPath (Join-Path $script:shared 'AvmPreCommit.ps1') -Raw
        $terraform | Should -Match "Join-Path \`$PSScriptRoot 'RepositoryFileSync.ps1'"
        $terraform | Should -Not -Match 'function Invoke-RepositoryFileSync|function Assert-RepositorySync|function Get-RepositorySyncComparison'
        $entry = Get-Content -LiteralPath (Join-Path $script:codeowners 'scripts' 'Invoke-BicepCodeownersSync.ps1') -Raw
        $entry | Should -Match "'RepositoryFileSync.ps1'"
        $entry | Should -Not -Match 'AvmPreCommit|ManagedFilesUpgrade'
    }
}

Describe 'Shared candidate identity, scope, and commit history guards' {
    BeforeEach {
        $script:context = New-SyncTestContext
        $script:candidate = New-SyncTestPullRequest
        Mock Invoke-RepositoryGitHubApi { throw 'Unexpected API call.' }
    }

    It 'accepts the exact expected app-owned candidate' {
        { Assert-RepositorySyncPullRequest -Context $script:context -PullRequest $script:candidate } | Should -Not -Throw
    }

    It 'rejects unsafe candidate identities or pre-enabled auto-merge' -ForEach @(
        @{ Area = 'user'; Property = 'login'; Value = 'human' }
        @{ Area = 'user'; Property = 'id'; Value = 1 }
        @{ Area = 'user'; Property = 'type'; Value = 'User' }
        @{ Area = 'base'; Property = 'ref'; Value = 'release' }
        @{ Area = 'baseRepo'; Property = 'id'; Value = 1 }
        @{ Area = 'baseRepo'; Property = 'default_branch'; Value = 'release' }
        @{ Area = 'baseRepo'; Property = 'full_name'; Value = 'Other/repository' }
        @{ Area = 'head'; Property = 'ref'; Value = 'other-branch' }
        @{ Area = 'head'; Property = 'sha'; Value = ('c' * 40) }
        @{ Area = 'headRepo'; Property = 'id'; Value = 1 }
        @{ Area = 'headRepo'; Property = 'full_name'; Value = 'Other/repository' }
        @{ Area = 'headRepo'; Property = 'fork'; Value = $true }
        @{ Area = 'pr'; Property = 'draft'; Value = $true }
        @{ Area = 'pr'; Property = 'state'; Value = 'closed' }
        @{ Area = 'pr'; Property = 'auto_merge'; Value = @{ merge_method = 'squash' } }
    ) {
        $target = switch ($Area) {
            user { $script:candidate.user }
            base { $script:candidate.base }
            baseRepo { $script:candidate.base.repo }
            head { $script:candidate.head }
            headRepo { $script:candidate.head.repo }
            pr { $script:candidate }
        }
        $target.$Property = $Value
        { Assert-RepositorySyncPullRequest -Context $script:context -PullRequest $script:candidate } | Should -Throw
    }

    It 'rejects unlisted or missing prepared file changes' {
        { Assert-RepositorySyncFileScope -Paths @('.github/CODEOWNERS', 'other.ps1') -AllowedPaths @('.github/CODEOWNERS') } | Should -Throw '*outside*'
        { Assert-RepositorySyncFileScope -Paths @() -AllowedPaths @('.github/CODEOWNERS') -ExpectedPaths @('.github/CODEOWNERS') } | Should -Throw '*differs*'
    }

    It 'validates later history pages for human work before reusing a stable branch' {
        Mock Invoke-RepositoryGitHubApi {
            $commits = if ($Endpoint.EndsWith('page=1')) {
                1..100 | ForEach-Object { [pscustomobject]@{ sha = $_.ToString('x40'); author = New-SyncTestActor; committer = New-SyncTestActor } }
            } else {
                [pscustomobject]@{ sha = (101).ToString('x40'); author = [pscustomobject]@{ login = 'human'; id = 1; type = 'User' }; committer = New-SyncTestActor }
            }
            [pscustomobject]@{
                base_commit = @{ sha = $script:context.BaseSha }
                total_commits = 101
                commits = @($commits)
                files = @([pscustomobject]@{ filename = '.github/CODEOWNERS' })
            }
        }
        { Get-RepositorySyncComparison -Context $script:context -HeadSha $script:context.HeadSha } | Should -Throw '*expected app bot*'
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 2
    }
}

Describe 'Shared immutable repository file reads' {
    BeforeEach {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("hello`n")
        $script:file = [pscustomobject]@{
            type = 'file'; path = 'index.csv'; encoding = 'base64'
            size = $bytes.Length; content = [Convert]::ToBase64String($bytes)
            sha = Get-RepositoryGitBlobSha -Bytes $bytes
        }
        Mock Invoke-RepositoryGitHubApi { $script:file }
    }

    It 'preserves verified UTF-8 data using the existing blob hash algorithm' {
        $value = Get-RepositoryFileAtCommit -Repository 'Azure/example' -Path 'index.csv' -Sha ('a' * 40)
        $value.Content | Should -BeExactly "hello`n"
        $value.Sha | Should -BeExactly 'ce013625030ba8dba906f756967f9e9ca394464a'
    }

    It 'rejects wrong paths, nonfiles, partial metadata, and corrupted content' -ForEach @(
        @{ Property = 'type'; Value = 'symlink' }
        @{ Property = 'path'; Value = 'different.csv' }
        @{ Property = 'encoding'; Value = 'none' }
        @{ Property = 'size'; Value = 99 }
        @{ Property = 'sha'; Value = ('0' * 40) }
        @{ Property = 'content'; Value = 'invalid !' }
    ) {
        $script:file.$Property = $Value
        { Get-RepositoryFileAtCommit -Repository 'Azure/example' -Path 'index.csv' -Sha ('a' * 40) } | Should -Throw
    }
}

Describe 'CODEOWNERS-specific validation hooks and immutable source data' {
    BeforeEach {
        $script:context = New-SyncTestContext
        $script:context.PullRequest = New-SyncTestPullRequest
        Mock Get-RepositoryFileAtCommit { [pscustomobject]@{ Content = $script:content; Sha = $script:snapshot.BlobSha } }
        Mock Invoke-RepositoryGitHubApi {
            if ($Endpoint -like '*/codeowners/errors?*') { return [pscustomobject]@{ errors = @() } }
            if ($Endpoint -like '*/pulls/7343') { return [pscustomobject]@{ merged = $true; base = @{ ref = 'main'; repo = @{ id = 42; full_name = 'Azure/bicep-registry-modules' } } } }
            throw 'Unexpected API call.'
        }
    }

    It 'fails visibly on all owner diagnostics without altering the candidate' {
        Mock Invoke-RepositoryGitHubApi { [pscustomobject]@{ errors = @(@{ message = 'Unknown owner alice' }, @{ message = 'Unknown owner bob' }) } }
        { Test-BicepCodeownersSyncChange -Context $script:context } | Should -Throw '*candidate remains open*alice*bob*'
    }

    It 'enforces the compatibility prerequisite only for merging' {
        Mock Invoke-RepositoryGitHubApi { [pscustomobject]@{ merged = $false } } -ParameterFilter { $Endpoint -like '*/pulls/7343' }
        { Test-BicepCodeownersSyncChange -Context $script:context } | Should -Not -Throw
        $script:context.PlanOnly = $false
        { Test-BicepCodeownersSyncChange -Context $script:context } | Should -Throw '*7343*'
    }

    It 'checks exact generated content after publication and after merging' -ForEach @('Candidate', 'Merged') {
        $script:context.Phase = $_
        Mock Get-RepositoryFileAtCommit { [pscustomobject]@{ Content = $script:content.Replace('@alice ', '@other '); Sha = $script:snapshot.BlobSha } }
        { Test-BicepCodeownersSyncChange -Context $script:context } | Should -Throw '*exactly match*'
    }

    It 'refuses unreviewed static changes on the base or existing candidate' -ForEach @('Base', 'Existing') {
        $script:context.Phase = $_
        Mock Get-RepositoryFileAtCommit { [pscustomobject]@{ Content = "# Keep this comment`n" + $script:content; Sha = 'c' * 40 } }
        { Test-BicepCodeownersSyncChange -Context $script:context } | Should -Throw '*static CODEOWNERS*'
    }

    It 'loads all official indexes through the shared transport at one source commit' {
        Mock Invoke-RepositoryGitHubApi { [pscustomobject]@{ sha = 'f' * 40 } }
        Mock Get-RepositoryFileAtCommit {
            $kind = switch -Wildcard ($Path) { '*Resource*' { 'res' } '*Pattern*' { 'ptn' } '*Utility*' { 'utl' } }
            [pscustomobject]@{
                Sha = 'a' * 40
                Content = "ModuleName,ModuleStatus,PrimaryModuleOwnerGHHandle,SecondaryModuleOwnerGHHandle`navm/$kind/test/module,Available,alice,`n"
            }
        }
        $snapshot = Get-AvmBicepCodeownersSnapshot -Template $script:template
        $snapshot.ModuleCount | Should -Be 3
        Should -Invoke Invoke-RepositoryGitHubApi -Exactly 1
        Should -Invoke Get-RepositoryFileAtCommit -Exactly 3 -ParameterFilter {
            $Repository -ceq 'Azure/Azure-Verified-Modules' -and $Sha -ceq ('f' * 40)
        }
    }
}
