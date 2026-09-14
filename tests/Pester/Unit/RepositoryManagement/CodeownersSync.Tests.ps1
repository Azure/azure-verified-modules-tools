BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:syncRoot = Join-Path $script:root 'repository-management' 'bicep-codeowners-sync'
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:syncRoot 'scripts' 'lib' 'Codeowners.ps1')
    . (Join-Path $script:syncRoot 'scripts' 'lib' 'GitHubSync.ps1')
    $script:template = Get-Content -LiteralPath (Join-Path $script:syncRoot 'CODEOWNERS.template') -Raw
    $script:originalToken = $env:GH_TOKEN

    function New-CodeownersTestBot {
        [pscustomobject]@{ login = 'azure-verified-modules[bot]'; id = 187664033; type = 'Bot' }
    }

    function Get-CodeownersTestBlob {
        param([string] $Content)
        Get-AvmCodeownersBlobSha -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Content))
    }

    function New-CodeownersTestFile {
        param([string] $Content = $script:state.HeadContent)
        [pscustomobject]@{ filename = '.github/CODEOWNERS'; status = 'modified'; sha = Get-CodeownersTestBlob $Content }
    }

    function New-CodeownersTestCommit {
        param([string] $Sha, [string] $Tree = $script:state.TreeSha)
        [pscustomobject]@{
            sha = $Sha
            author = New-CodeownersTestBot
            committer = New-CodeownersTestBot
            commit = [pscustomobject]@{ tree = [pscustomobject]@{ sha = $Tree } }
            parents = @([pscustomobject]@{ sha = $script:state.OriginalBaseSha })
            files = @((New-CodeownersTestFile -Content $script:snapshot.Content))
        }
    }

    function New-CodeownersTestPullRequest {
        [pscustomobject]@{
            number = 123
            html_url = 'https://github.com/Azure/bicep-registry-modules/pull/123'
            state = if ($script:state.Merged) { 'closed' } else { 'open' }
            merged = $script:state.Merged
            draft = $false
            auto_merge = $null
            maintainer_can_modify = $false
            user = New-CodeownersTestBot
            merged_by = New-CodeownersTestBot
            merge_commit_sha = $script:state.MergeSha
            changed_files = $script:state.ChangedFiles
            title = $script:state.Title
            body = $script:state.Body
            base = [pscustomobject]@{ ref = 'main'; sha = $script:state.BaseSha; repo = $script:repository }
            head = [pscustomobject]@{ ref = 'avm-bot/bicep-codeowners-sync'; sha = $script:state.BranchSha; repo = $script:repository }
        }
    }

    function Enable-CodeownersTestCandidate {
        $script:state.HasBranch = $true
        $script:state.HasPullRequest = $true
        $script:state.BranchSha = 'b' * 40
        $script:state.HeadContent = $script:snapshot.Content
    }

    function Invoke-CodeownersTestApi {
        param([string] $Endpoint, [string] $Method = 'GET', [hashtable] $Body)
        $script:state.Calls.Add([pscustomobject]@{ Endpoint = $Endpoint; Method = $Method; Body = $Body })
        switch -Regex ($Endpoint) {
            '^installation/repositories' {
                return [pscustomobject]@{ total_count = 1; repositories = @($script:repository) }
            }
            '^graphql$' {
                return [pscustomobject]@{ data = [pscustomobject]@{ viewer = [pscustomobject]@{ login = 'azure-verified-modules[bot]'; databaseId = 187664033 } } }
            }
            '^repos/Azure/bicep-registry-modules$' { return $script:repository }
            '/git/ref/heads/main$' {
                return [pscustomobject]@{ ref = 'refs/heads/main'; object = [pscustomobject]@{ type = 'commit'; sha = $script:state.BaseSha } }
            }
            '/git/matching-refs/' {
                if ($script:state.HasBranch) {
                    return [pscustomobject]@{ ref = 'refs/heads/avm-bot/bicep-codeowners-sync'; object = [pscustomobject]@{ type = 'commit'; sha = $script:state.BranchSha } }
                }
                return @()
            }
            '/commits/([a-f0-9]{40})$' {
                $sha = ($Endpoint -split '/')[-1]
                if ($sha -ceq $script:state.MergeSha) {
                    return New-CodeownersTestCommit -Sha $sha -Tree $script:state.MergedTreeSha
                }
                if ($sha -ceq $script:state.BaseSha) {
                    return New-CodeownersTestCommit -Sha $sha -Tree $script:state.BaseTreeSha
                }
                if ($sha -in @($script:state.NewSha, $script:state.BranchSha)) {
                    return New-CodeownersTestCommit -Sha $sha
                }
                throw "Unexpected commit lookup: $Endpoint"
            }
            '/compare/' {
                if (-not $Endpoint.Contains('?')) {
                    return [pscustomobject]@{
                        status = 'identical'
                        merge_base_commit = [pscustomobject]@{ sha = $script:state.MergeSha }
                    }
                }
                $base = (($Endpoint -split '/compare/')[1] -split '\.\.\.')[0]
                $mergeBase = if ($script:state.ComparisonBase) { $script:state.ComparisonBase } else { $base }
                $files = if ($null -ne $script:state.ComparisonFiles) { $script:state.ComparisonFiles } else { @((New-CodeownersTestFile)) }
                return [pscustomobject]@{
                    base_commit = [pscustomobject]@{ sha = $base }
                    merge_base_commit = [pscustomobject]@{ sha = $mergeBase }
                    total_commits = 1
                    commits = @((New-CodeownersTestCommit -Sha $script:state.BranchSha))
                    files = @($files)
                }
            }
            '/pulls\?' {
                if ($script:state.HasPullRequest -and -not $script:state.Merged) {
                    return [pscustomobject]@{ number = 123 }
                }
                return @()
            }
            '/pulls/7343$' {
                return [pscustomobject]@{
                    merged = $script:state.PrerequisiteMerged
                    base = [pscustomobject]@{ ref = 'main'; repo = $script:repository }
                }
            }
            '/pulls/123/files\?' {
                if ($null -ne $script:state.PullRequestFiles) {
                    return $script:state.PullRequestFiles
                }
                return New-CodeownersTestFile
            }
            '/pulls/123$' {
                if ($Method -eq 'PATCH') {
                    $script:state.Title = $Body.title
                    $script:state.Body = $Body.body
                }
                return New-CodeownersTestPullRequest
            }
            '/pulls$' {
                if ($Method -ne 'POST') { throw 'Only candidate creation uses this endpoint.' }
                $script:state.HasPullRequest = $true
                $script:state.Title = $Body.title
                $script:state.Body = $Body.body
                return New-CodeownersTestPullRequest
            }
            '/codeowners/errors\?' {
                return [pscustomobject]@{ errors = @($script:state.CodeownersErrors) }
            }
            '/git/trees$' {
                if ($Method -ne 'POST') { throw 'Only tree creation uses this endpoint.' }
                return [pscustomobject]@{ sha = $script:state.TreeSha }
            }
            '/git/commits$' {
                if ($Method -ne 'POST') { throw 'Only commit creation uses this endpoint.' }
                return [pscustomobject]@{ sha = $script:state.NewSha }
            }
            '/git/refs($|/heads/)' {
                $script:state.HasBranch = $true
                $script:state.BranchSha = $Body.sha
                $script:state.HeadContent = $script:snapshot.Content
                $script:state.ComparisonBase = $null
                return [pscustomobject]@{
                    ref = 'refs/heads/avm-bot/bicep-codeowners-sync'
                    object = [pscustomobject]@{ type = 'commit'; sha = $Body.sha }
                }
            }
            default { throw "Unmocked GitHub endpoint: $Method $Endpoint" }
        }
    }

    function Get-CodeownersTestWrites {
        @($script:state.Calls | Where-Object { $_.Method -ne 'GET' -and $_.Endpoint -ne 'graphql' })
    }
}

AfterAll {
    $env:GH_TOKEN = $script:originalToken
}

Describe 'Guarded Bicep CODEOWNERS synchronization' {
    BeforeEach {
        $env:GH_TOKEN = 'offline-test-installation-token'
        $script:repository = [pscustomobject]@{
            id = 42
            full_name = 'Azure/bicep-registry-modules'
            default_branch = 'main'
            fork = $false
            archived = $false
            disabled = $false
            allow_squash_merge = $true
            permissions = [pscustomobject]@{ push = $true }
        }
        $content = $script:template.Replace('__AVM_MODULE_OWNERS__', '/avm/res/test/module/ @alice @Azure/azure-verified-modules-module-owners')
        $script:snapshot = [pscustomobject]@{
            Content = $content
            SourceSha = 'f' * 40
            BlobSha = Get-CodeownersTestBlob $content
            ModuleCount = 1
        }
        $script:state = @{
            BaseSha = 'a' * 40
            OriginalBaseSha = 'a' * 40
            BaseTreeSha = '1' * 40
            TreeSha = '2' * 40
            MergedTreeSha = '2' * 40
            NewSha = 'c' * 40
            MergeSha = 'd' * 40
            HasBranch = $false
            BranchSha = $null
            HeadContent = $null
            HasPullRequest = $false
            Merged = $false
            PrerequisiteMerged = $true
            ChangedFiles = 1
            Title = ''
            Body = ''
            ComparisonBase = $null
            ComparisonFiles = $null
            PullRequestFiles = $null
            CodeownersErrors = @()
            Calls = [System.Collections.Generic.List[object]]::new()
            MergeCalls = [System.Collections.Generic.List[object]]::new()
            BaseContent = @(
                '* @Azure/azure-verified-modules-tooling-contributors', '',
                '/avm/ @Azure/azure-verified-modules-module-contributors', '',
                '*avm.core.team.tests.ps1 @Azure/azure-verified-modules-tooling-contributors',
                '*.e2eignore @Azure/azure-verified-modules-tooling-contributors', ''
            ) -join "`n"
        }
        Mock Invoke-AvmCodeownersApi { param($Endpoint, $Method = 'GET', $Body) Invoke-CodeownersTestApi @PSBoundParameters }
        Mock Get-AvmBicepCodeownersSnapshot { $script:snapshot }
        Mock Get-AvmCodeownersGitHubFile {
            param($Repository, $Path, $Sha)
            if ($Repository -cne 'Azure/bicep-registry-modules' -or $Path -cne '.github/CODEOWNERS') {
                throw 'Unexpected target file read.'
            }
            $content = if ($Sha -ceq $script:state.BaseSha) { $script:state.BaseContent } else { $script:state.HeadContent }
            [pscustomobject]@{ Content = $content; Sha = Get-CodeownersTestBlob $content }
        }
        Mock Invoke-AvmCodeownersGh {
            param($ArgumentList)
            if ($ArgumentList[0] -cne 'pr' -or $ArgumentList[1] -cne 'merge') {
                throw 'No live GitHub CLI calls are permitted in these tests.'
            }
            $script:state.MergeCalls.Add($ArgumentList)
            $script:state.Merged = $true
            $script:state.BaseSha = $script:state.MergeSha
            $script:state.BaseContent = $script:snapshot.Content
            ''
        }
    }

    It 'does not create, update, or merge anything when the generated blob already matches main' {
        $script:state.BaseContent = $script:snapshot.Content
        $result = Invoke-AvmBicepCodeownersSync -Template $script:template
        $result.Status | Should -Be 'NoChange'
        Get-CodeownersTestWrites | Should -HaveCount 0
        $script:state.MergeCalls | Should -HaveCount 0
        Should -Invoke Get-AvmCodeownersGitHubFile -Times 1 -Exactly
    }

    It 'creates a reviewable plan that changes only CODEOWNERS and never merges' {
        $result = Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly
        $result.Status | Should -Be 'Planned'
        $result.PullRequestUrl | Should -Be 'https://github.com/Azure/bicep-registry-modules/pull/123'
        $result.HeadSha | Should -Be $script:state.NewSha
        $script:state.MergeCalls | Should -HaveCount 0
        $treeWrite = @(Get-CodeownersTestWrites | Where-Object Endpoint -Like '*/git/trees')
        $treeWrite | Should -HaveCount 1
        $treeWrite[0].Body.tree | Should -HaveCount 1
        $treeWrite[0].Body.tree[0].path | Should -BeExactly '.github/CODEOWNERS'
        $treeWrite[0].Body.tree[0].mode | Should -BeExactly '100644'
        $treeWrite[0].Body.tree[0].content | Should -BeExactly $script:snapshot.Content
        $creation = @(Get-CodeownersTestWrites | Where-Object Endpoint -Like '*/pulls')
        $creation[0].Body.base | Should -BeExactly 'main'
        $creation[0].Body.head | Should -BeExactly 'avm-bot/bicep-codeowners-sync'
        $creation[0].Body.maintainer_can_modify | Should -BeFalse
    }

    It 'reuses the same plan branch, commit, and pull request on an identical second run' {
        $null = Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly
        $script:state.Calls.Clear()
        $result = Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly
        $result.Status | Should -Be 'Planned'
        Get-CodeownersTestWrites | Should -HaveCount 0
        $script:state.MergeCalls | Should -HaveCount 0
        $result.HeadSha | Should -Be $script:state.NewSha
    }

    It 'updates only an app-owned stable branch using a non-forced descendant of both heads' {
        Enable-CodeownersTestCandidate
        $oldHead = $script:state.BranchSha
        $script:state.HeadContent = $script:snapshot.Content.Replace('@alice ', '@previous ')
        $script:state.ComparisonBase = 'e' * 40
        $result = Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly
        $result.Status | Should -Be 'Planned'
        $commit = @(Get-CodeownersTestWrites | Where-Object Endpoint -Like '*/git/commits')[0]
        $commit.Body.parents | Should -Be @($script:state.OriginalBaseSha, $oldHead)
        $reference = @(Get-CodeownersTestWrites | Where-Object Endpoint -Like '*/git/refs/heads/*')[0]
        $reference.Method | Should -Be 'PATCH'
        $reference.Body.force | Should -BeFalse
        @(Get-CodeownersTestWrites | Where-Object Endpoint -Like '*/pulls') | Should -HaveCount 0
    }

    It 'merges only the exact head using app bypass and verifies the persisted result' {
        $result = Invoke-AvmBicepCodeownersSync -Template $script:template
        $result.Status | Should -Be 'Merged'
        $script:state.MergeCalls | Should -HaveCount 1
        $arguments = $script:state.MergeCalls[0]
        $arguments | Should -Contain '--admin'
        $arguments | Should -Contain '--squash'
        $arguments[([array]::IndexOf($arguments, '--match-head-commit') + 1)] | Should -Be $script:state.NewSha
        $arguments[([array]::IndexOf($arguments, '--repo') + 1)] | Should -BeExactly 'Azure/bicep-registry-modules'
        $arguments | Should -Not -Contain '--auto'
        $arguments | Should -Not -Contain '--delete-branch'
        @(Get-CodeownersTestWrites | Where-Object Endpoint -Match 'rulesets|protection|reviews|collaborators') | Should -HaveCount 0
        $script:state.Calls.Clear()
        (Invoke-AvmBicepCodeownersSync -Template $script:template).Status | Should -Be 'NoChange'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'leaves the candidate open and fails visibly when app bypass is unavailable' {
        Mock Invoke-AvmCodeownersGh { throw 'HTTP 403: bypass unavailable' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*bypass unavailable*'
        $script:state.HasPullRequest | Should -BeTrue
        $script:state.Merged | Should -BeFalse
        Should -Invoke Invoke-AvmCodeownersGh -Times 1 -Exactly
    }

    It 'does not treat a successful command that left a pending pull request as a merge' {
        Mock Invoke-AvmCodeownersGh { '' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*app bypass did not merge*'
    }

    It 'permits review-only plans before the prerequisite merges but blocks automatic merging' {
        $script:state.PrerequisiteMerged = $false
        (Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly).Status | Should -Be 'Planned'
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*compatibility prerequisite*'
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'preserves the plan and surfaces every invalid-owner diagnostic without dropping owners' -ForEach @($true, $false) {
        $script:state.CodeownersErrors = @(
            [pscustomobject]@{ kind = 'Invalid owner'; message = 'Unknown owner @alice'; line = 7 }
            [pscustomobject]@{ kind = 'Invalid owner'; message = 'Unknown owner @bob'; line = 8 }
        )
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly:$_ } |
            Should -Throw '*candidate remains open*alice*bob*'
        $script:state.HasPullRequest | Should -BeTrue
        $script:state.HeadContent | Should -BeExactly $script:snapshot.Content
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'does not mutate a target whose current static rules or comments changed' {
        $script:state.BaseContent = "# Keep my custom rule explanation`n" + $script:state.BaseContent
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*static CODEOWNERS*'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'never writes a branch or pull request after a CSV/API download failure' {
        Mock Get-AvmBicepCodeownersSnapshot { throw 'CSV download failed' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly } | Should -Throw '*CSV download failed*'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'does not fall back to cached credentials when the explicit token is absent' {
        $env:GH_TOKEN = ''
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*installation token*'
        $script:state.Calls | Should -HaveCount 0
    }

    It 'rejects an installation token with wider repository access' {
        Mock Invoke-AvmCodeownersApi {
            [pscustomobject]@{ total_count = 2; repositories = @($script:repository, $script:repository) }
        } -ParameterFilter { $Endpoint -like 'installation/*' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*scoped only*'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'rejects a different authenticated app or human identity' {
        Mock Invoke-AvmCodeownersApi {
            [pscustomobject]@{ data = [pscustomobject]@{ viewer = [pscustomobject]@{ login = 'human'; databaseId = 1 } } }
        } -ParameterFilter { $Endpoint -eq 'graphql' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*authenticated identity*'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'rejects a renamed, forked, archived, disabled, or non-squash target' -ForEach @(
        @{ Property = 'default_branch'; Value = 'other' }
        @{ Property = 'full_name'; Value = 'Attacker/bicep-registry-modules' }
        @{ Property = 'fork'; Value = $true }
        @{ Property = 'archived'; Value = $true }
        @{ Property = 'disabled'; Value = $true }
        @{ Property = 'allow_squash_merge'; Value = $false }
    ) {
        $script:repository.$Property = $Value
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'rejects insufficient app write permissions without widening them' {
        $script:repository.permissions.push = $false
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*write permissions*'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'does not take over a human-owned stable branch even without a pull request' {
        Enable-CodeownersTestCandidate
        $script:state.HasPullRequest = $false
        Mock Invoke-AvmCodeownersApi {
            $commit = New-CodeownersTestCommit -Sha $script:state.BranchSha
            $commit.author = [pscustomobject]@{ login = 'human'; id = 1; type = 'User' }
            $commit
        } -ParameterFilter { $Endpoint -like '*/commits/bbbbb*' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*expected AVM App bot*'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'refuses to overwrite an app branch that includes unrelated files' {
        Enable-CodeownersTestCandidate
        $script:state.HeadContent = $script:snapshot.Content.Replace('@alice ', '@previous ')
        $script:state.ComparisonFiles = @(
            (New-CodeownersTestFile)
            [pscustomobject]@{ filename = '.github/workflows/untrusted.yml'; status = 'added'; sha = 'e' * 40 }
        )
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*entire change*'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'refuses ambiguous open pull requests for the stable branch' {
        Enable-CodeownersTestCandidate
        Mock Invoke-AvmCodeownersApi { @([pscustomobject]@{ number = 123 }, [pscustomobject]@{ number = 124 }) } `
            -ParameterFilter { $Endpoint -like '*/pulls?state=open*' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*ambiguous*'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'rejects a changed head during final validation instead of merging a race winner' {
        Enable-CodeownersTestCandidate
        Mock Get-AvmCodeownersBranchSha { 'e' * 40 }
        $guard = @{
            Number = 123; RepositoryId = 42; BaseSha = $script:state.BaseSha
            HeadSha = $script:state.BranchSha; TreeSha = $script:state.TreeSha
            Snapshot = $script:snapshot; Template = $script:template
        }
        { Merge-AvmCodeownersPullRequest @guard } | Should -Throw '*moved during validation*'
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'rejects a changed main during final validation instead of bypassing stale checks' {
        Enable-CodeownersTestCandidate
        Mock Get-AvmCodeownersBaseSha { 'e' * 40 }
        { Merge-AvmCodeownersPullRequest -Number 123 -RepositoryId 42 -BaseSha $script:state.BaseSha `
            -HeadSha $script:state.BranchSha -TreeSha $script:state.TreeSha -Snapshot $script:snapshot -Template $script:template } |
            Should -Throw '*moved during validation*'
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'rejects different generated content even if it otherwise follows the ownership contract' {
        Enable-CodeownersTestCandidate
        Mock Get-AvmCodeownersGitHubFile {
            [pscustomobject]@{ Content = $script:snapshot.Content.Replace('@alice ', '@attacker '); Sha = $script:snapshot.BlobSha }
        }
        { Merge-AvmCodeownersPullRequest -Number 123 -RepositoryId 42 -BaseSha $script:state.BaseSha `
            -HeadSha $script:state.BranchSha -TreeSha $script:state.TreeSha -Snapshot $script:snapshot -Template $script:template } |
            Should -Throw '*exactly match the generated*'
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'rejects a merged tree that contains a concurrent or unrelated update' {
        $script:state.MergedTreeSha = 'e' * 40
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*merged tree or base differs*'
    }

    It 'honors WhatIf without creating Git objects, branches, or pull requests' {
        (Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly -WhatIf).Status | Should -Be 'Preview'
        Get-CodeownersTestWrites | Should -HaveCount 0
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'checks all pull request identity fields rather than trusting the branch name' -ForEach @(
        @{ Area = 'user'; Property = 'login'; Value = 'another-app[bot]' }
        @{ Area = 'user'; Property = 'id'; Value = 1 }
        @{ Area = 'user'; Property = 'type'; Value = 'User' }
        @{ Area = 'base'; Property = 'ref'; Value = 'release' }
        @{ Area = 'baseRepo'; Property = 'full_name'; Value = 'Attacker/bicep-registry-modules' }
        @{ Area = 'baseRepo'; Property = 'id'; Value = 1 }
        @{ Area = 'baseRepo'; Property = 'default_branch'; Value = 'release' }
        @{ Area = 'head'; Property = 'ref'; Value = 'avm-bot/something-else' }
        @{ Area = 'head'; Property = 'sha'; Value = ('e' * 40) }
        @{ Area = 'headRepo'; Property = 'full_name'; Value = 'Attacker/bicep-registry-modules' }
        @{ Area = 'headRepo'; Property = 'id'; Value = 1 }
        @{ Area = 'headRepo'; Property = 'fork'; Value = $true }
        @{ Area = 'pr'; Property = 'draft'; Value = $true }
        @{ Area = 'pr'; Property = 'maintainer_can_modify'; Value = $true }
        @{ Area = 'pr'; Property = 'state'; Value = 'closed' }
        @{ Area = 'pr'; Property = 'merged'; Value = $true }
        @{ Area = 'pr'; Property = 'auto_merge'; Value = [pscustomobject]@{ merge_method = 'squash' } }
        @{ Area = 'pr'; Property = 'html_url'; Value = 'https://example.invalid/pull/123' }
    ) {
        Enable-CodeownersTestCandidate
        $candidate = New-CodeownersTestPullRequest
        $target = switch ($Area) {
            'user' { $candidate.user }
            'base' { $candidate.base }
            'baseRepo' { $candidate.base.repo }
            'head' { $candidate.head }
            'headRepo' { $candidate.head.repo }
            'pr' { $candidate }
        }
        $target.$Property = $Value
        { Assert-AvmCodeownersPullRequestIdentity -PullRequest $candidate -RepositoryId 42 `
            -ExpectedHeadSha $script:state.BranchSha -ExpectedBaseSha $script:state.BaseSha } | Should -Throw
    }

    It 'does not overwrite a pull request authored by a human on the correct branch' {
        Enable-CodeownersTestCandidate
        Mock Invoke-AvmCodeownersApi {
            $candidate = New-CodeownersTestPullRequest
            $candidate.user = [pscustomobject]@{ login = 'human'; type = 'User'; id = 7 }
            $candidate
        } -ParameterFilter { $Endpoint -like '*/pulls/123' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly } | Should -Throw '*expected AVM App bot*'
        Get-CodeownersTestWrites | Should -HaveCount 0
    }

    It 'does not update an existing auto-merge candidate during plan-only execution' {
        Enable-CodeownersTestCandidate
        $script:state.HeadContent = $script:snapshot.Content.Replace('@alice ', '@previous ')
        Mock Invoke-AvmCodeownersApi {
            $candidate = New-CodeownersTestPullRequest
            $candidate.auto_merge = [pscustomobject]@{ merge_method = 'squash' }
            $candidate
        } -ParameterFilter { $Endpoint -like '*/pulls/123' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly } | Should -Throw '*already has auto-merge enabled*'
        Get-CodeownersTestWrites | Should -HaveCount 0
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'checks every changed-file page even when the metadata claims one file' {
        Enable-CodeownersTestCandidate
        Mock Invoke-AvmCodeownersApi {
            if ($Endpoint.EndsWith('page=1')) {
                1..100 | ForEach-Object { New-CodeownersTestFile }
            } else {
                [pscustomobject]@{ filename = 'hidden-on-page-two.ps1'; status = 'added'; sha = 'e' * 40 }
            }
        } -ParameterFilter { $Endpoint -like '*/pulls/123/files?*' }
        { Merge-AvmCodeownersPullRequest -Number 123 -RepositoryId 42 -BaseSha $script:state.BaseSha `
            -HeadSha $script:state.BranchSha -TreeSha $script:state.TreeSha -Snapshot $script:snapshot -Template $script:template } |
            Should -Throw '*entire change*'
        Should -Invoke Invoke-AvmCodeownersApi -Times 2 -Exactly -ParameterFilter { $Endpoint -like '*/pulls/123/files?*' }
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'checks later commit pages for human work on an otherwise app-owned branch' {
        Enable-CodeownersTestCandidate
        Mock Invoke-AvmCodeownersApi {
            $commits = if ($Endpoint.EndsWith('page=1')) {
                1..100 | ForEach-Object { New-CodeownersTestCommit -Sha $_.ToString('x40') }
            } else {
                $commit = New-CodeownersTestCommit -Sha (101).ToString('x40')
                $commit.author = [pscustomobject]@{ login = 'human'; type = 'User'; id = 7 }
                $commit
            }
            [pscustomobject]@{
                base_commit = [pscustomobject]@{ sha = $script:state.BaseSha }
                merge_base_commit = [pscustomobject]@{ sha = $script:state.BaseSha }
                total_commits = 101
                commits = @($commits)
                files = @((New-CodeownersTestFile))
            }
        } -ParameterFilter { $Endpoint -like '*/compare/*' }
        { Get-AvmCodeownersComparison -BaseSha $script:state.BaseSha -HeadSha $script:state.BranchSha } |
            Should -Throw '*expected AVM App bot*'
        Should -Invoke Invoke-AvmCodeownersApi -Times 2 -Exactly -ParameterFilter { $Endpoint -like '*/compare/*' }
    }

    It 'rejects incomplete commit pagination' {
        Enable-CodeownersTestCandidate
        Mock Invoke-AvmCodeownersApi {
            [pscustomobject]@{
                base_commit = [pscustomobject]@{ sha = $script:state.BaseSha }
                merge_base_commit = [pscustomobject]@{ sha = $script:state.BaseSha }
                total_commits = 2
                commits = @((New-CodeownersTestCommit -Sha $script:state.BranchSha))
                files = @((New-CodeownersTestFile))
            }
        } -ParameterFilter { $Endpoint -like '*/compare/*' }
        { Get-AvmCodeownersComparison -BaseSha $script:state.BaseSha -HeadSha $script:state.BranchSha } |
            Should -Throw '*incomplete branch commit history*'
    }

    It 'rejects renames, deletions, additions, and an unrelated sole changed file' -ForEach @(
        @{ Status = 'renamed'; Name = '.github/CODEOWNERS' }
        @{ Status = 'removed'; Name = '.github/CODEOWNERS' }
        @{ Status = 'added'; Name = '.github/CODEOWNERS' }
        @{ Status = 'modified'; Name = 'unrelated.ps1' }
    ) {
        Enable-CodeownersTestCandidate
        $script:state.PullRequestFiles = @([pscustomobject]@{ filename = $Name; status = $Status; sha = $script:snapshot.BlobSha })
        { Merge-AvmCodeownersPullRequest -Number 123 -RepositoryId 42 -BaseSha $script:state.BaseSha `
            -HeadSha $script:state.BranchSha -TreeSha $script:state.TreeSha -Snapshot $script:snapshot -Template $script:template } |
            Should -Throw '*entire change*'
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'leaves a concurrently changed branch untouched after a rejected non-fast-forward update' {
        Enable-CodeownersTestCandidate
        $original = $script:state.BranchSha
        $script:state.HeadContent = $script:snapshot.Content.Replace('@alice ', '@previous ')
        Mock Invoke-AvmCodeownersApi { throw 'HTTP 422: Update is not a fast forward' } `
            -ParameterFilter { $Method -eq 'PATCH' -and $Endpoint -like '*/git/refs/heads/*' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template -PlanOnly } | Should -Throw '*not a fast forward*'
        $script:state.BranchSha | Should -Be $original
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'fails when GitHub owner diagnostics cannot be read' {
        Mock Invoke-AvmCodeownersApi { throw 'HTTP 403: diagnostics unavailable' } `
            -ParameterFilter { $Endpoint -like '*/codeowners/errors?*' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*diagnostics unavailable*'
        $script:state.MergeCalls | Should -HaveCount 0
    }

    It 'verifies the actual merger is the expected app rather than another actor' {
        Mock Invoke-AvmCodeownersApi {
            $candidate = New-CodeownersTestPullRequest
            if ($script:state.Merged) {
                $candidate.merged_by = [pscustomobject]@{ login = 'human'; type = 'User'; id = 7 }
            }
            $candidate
        } -ParameterFilter { $Endpoint -like '*/pulls/123' }
        { Invoke-AvmBicepCodeownersSync -Template $script:template } | Should -Throw '*expected AVM App bot*'
    }
}
