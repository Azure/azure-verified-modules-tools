BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:originalModulePath = $env:PSModulePath
    $script:originalToken = $env:GH_TOKEN
    $script:originalBotLogin = $env:AVM_APP_BOT_LOGIN
    $script:originalBotUserId = $env:AVM_APP_BOT_USER_ID
    $script:removeItemCommand = Get-Command Microsoft.PowerShell.Management\Remove-Item -CommandType Cmdlet
    $env:PSModulePath = @(
        (Join-Path $script:repoRoot 'src')
        (Join-Path $PSHOME 'Modules')
    ) -join [System.IO.Path]::PathSeparator
    $shared = Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    foreach ($name in @('RepositoryFileSync.ps1', 'AvmPreCommit.ps1', 'ManagedFilesUpgrade.ps1', 'RepositoryCandidate.ps1')) {
        . (Join-Path $shared $name)
    }
    $script:terraformOwnership = @{
        codeOwnersDefaultTeams = @('module-reviewers')
        codeOwnersFileProtectionTeams = @('engineering-reviewers')
    }
    $terraformTemplate = Get-Content -LiteralPath (Join-Path $shared '..' '..' 'CODEOWNERS.template') -Raw
    $script:terraformContent = $terraformTemplate.Replace('__AVM_CODEOWNERS_RULES__',
        "* @Azure/module-reviewers`n.github/CODEOWNERS @Azure/engineering-reviewers")
    function New-CoreActor {
        [pscustomobject]@{ login = 'azure-verified-modules[bot]'; id = 187664033; type = 'Bot' }
    }

    function New-CorePullRequest {
        [pscustomobject]@{
            number = 123
            html_url = "https://github.com/$($script:state.Repo.full_name)/pull/123"
            user = New-CoreActor
            merged_by = New-CoreActor
            auto_merge = $script:state.AutoMerge
            state = if ($script:state.Merged) { 'closed' } else { 'open' }
            merged = $script:state.Merged
            draft = $false
            merge_commit_sha = 'd' * 40
            changed_files = $script:state.RemotePaths.Count
            base = [pscustomobject]@{ ref = 'main'; sha = $script:state.MainSha; repo = $script:state.Repo }
            head = [pscustomobject]@{ ref = $script:state.Branch; sha = $script:state.RemoteHead; repo = $script:state.Repo }
        }
    }

    function New-CorePreparedArtifact {
        param([string]$Directory, [string]$BaseSha = ('a' * 40))

        $null = New-Item -ItemType Directory -Path $Directory -Force
        $candidate = @{
            schemaVersion = 1
            repository = 'Azure/terraform-test'
            phase = 'prepared'
            defaultBranch = 'main'
            baseSha = $BaseSha
            hasChanges = $true
            planOnly = $false
            headSha = 'b' * 40
            treeSha = '2' * 40
            changedPaths = @('main.tf')
            authoringSource = 'gallery'
            authoringVersion = '0.0.0'
        }
        [System.IO.File]::WriteAllText((Join-Path $Directory 'candidate.json'), ($candidate | ConvertTo-Json -Depth 6))
        [System.IO.File]::WriteAllBytes((Join-Path $Directory 'candidate.tar'), [byte[]]@(1, 2, 3))
        [System.IO.File]::WriteAllBytes((Join-Path $Directory 'candidate.patch'), [byte[]]@(4, 5, 6))
        $receipt = Join-Path $Directory 'receipt'
        Save-RepositorySyncValidationReceipt -Candidate $candidate -Directory $receipt
        return $receipt
    }

    function Invoke-CoreApi {
        param([string] $Endpoint)
        $script:state.ApiCalls.Add($Endpoint)
        switch -Regex ($Endpoint) {
            '^installation/' { return [pscustomobject]@{ total_count = 1; repositories = @($script:state.Repo) } }
            '^repos/[^/]+/[^/]+$' { return $script:state.Repo }
            '/pulls\?' {
                if ($script:state.HasPullRequest -and -not $script:state.Merged) { return [pscustomobject]@{ number = 123 } }
                return @()
            }
            '/pulls/123$' { return New-CorePullRequest }
            '/pulls/123/files\?' { return @($script:state.RemotePaths | ForEach-Object { [pscustomobject]@{ filename = $_ } }) }
            '/commits/' {
                $sha = $Endpoint.Split('/')[-1]
                $actor = if ($script:state.HumanHead -and $sha -ceq ('b' * 40)) {
                    [pscustomobject]@{ login = 'human'; id = 7; type = 'User' }
                } else { New-CoreActor }
                $tree = if ($sha -ceq ('b' * 40)) { $script:state.OldTree } elseif ($sha -ceq ('d' * 40)) { $script:state.MergedTree } else { '2' * 40 }
                return [pscustomobject]@{
                    sha = $sha; author = $actor; committer = $actor
                    commit = @{ tree = @{ sha = $tree } }
                    parents = @(@{ sha = 'a' * 40 })
                }
            }
            '/compare/' {
                if (-not $Endpoint.Contains('?')) { return [pscustomobject]@{ merge_base_commit = @{ sha = 'd' * 40 }; status = 'identical' } }
                return [pscustomobject]@{
                    base_commit = @{ sha = 'a' * 40 }
                    merge_base_commit = @{ sha = 'a' * 40 }
                    total_commits = 1
                    commits = @([pscustomobject]@{ sha = $script:state.RemoteHead; author = New-CoreActor; committer = New-CoreActor })
                    files = @($script:state.RemotePaths | ForEach-Object { [pscustomobject]@{ filename = $_ } })
                }
            }
            default { throw "Unmocked API endpoint: $Endpoint" }
        }
    }

    function Invoke-CoreGit {
        param([string[]] $Arguments, [string] $WorkingDirectory, [int] $MaxRetries = 0)
        $script:state.GitCalls.Add($Arguments)
        if ($Arguments[0] -eq 'clone') {
            $script:state.CloneRetries = $MaxRetries
            $root = $Arguments[-1]
            $script:state.Root = $root
            $null = New-Item -ItemType Directory -Path $root -Force
            if ($script:state.CreateGithub) {
                $null = New-Item -ItemType Directory -Path (Join-Path $root '.github') -Force
            }
            if ($null -ne $script:state.InitialCodeowners) {
                [System.IO.File]::WriteAllText((Join-Path $root '.github' 'CODEOWNERS'), $script:state.InitialCodeowners)
            }
            [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), 'original')
            $script:state.LocalHead = 'a' * 40
            return ''
        }
        if ($Arguments -contains 'commit-tree') { $script:state.LocalHead = 'c' * 40; return $script:state.LocalHead }
        if ($Arguments -contains 'commit') { $script:state.LocalHead = 'c' * 40; return '' }
        if ($Arguments[0] -eq 'archive' -or
            ($Arguments[0] -eq 'diff' -and @($Arguments | Where-Object { $_ -like '--output=*' }).Count -gt 0)) {
            $output = @($Arguments | Where-Object { $_ -like '--output=*' })[0].Substring(9)
            [System.IO.File]::WriteAllBytes($output, [byte[]]@(1, 2, 3))
            return ''
        }
        switch ($Arguments[0]) {
            'config' { return '' }
            'sparse-checkout' { return '' }
            'checkout' {
                if ($Arguments -contains '-b') { $script:state.Branch = $Arguments[-1] }
                return ''
            }
            'fetch' { return '' }
            'update-ref' { return '' }
            'add' { return '' }
            'rev-parse' {
                if ($Arguments[-1] -eq 'HEAD^{tree}') { return '2' * 40 }
                return $script:state.LocalHead
            }
            'ls-tree' { return "100644 blob $('e' * 40)`t$($Arguments[-1])" }
            'status' {
                $script:state.PreparedCodeownersBytes = [System.IO.File]::ReadAllBytes((Join-Path $WorkingDirectory '.github' 'CODEOWNERS'))
                if ($script:state.NoChanges -or $script:state.LocalHead -ceq ('c' * 40)) { return '' }
                return " M $($script:state.LocalPaths[0])"
            }
            'diff' { return ($script:state.LocalPaths -join [char]0) + [char]0 }
            'apply' {
                [System.IO.File]::WriteAllText((Join-Path $WorkingDirectory 'main.tf'), 'prepared')
                return ''
            }
            'write-tree' { return '2' * 40 }
            'push' {
                if ($script:state.RejectPush) { throw 'non-fast-forward update rejected' }
                $script:state.RemoteHead = $script:state.LocalHead
                return ''
            }
            default { throw "Unmocked Git invocation: $($Arguments -join ' ')" }
        }
    }
}

AfterAll {
    $env:GH_TOKEN = $script:originalToken
    $env:AVM_APP_BOT_LOGIN = $script:originalBotLogin
    $env:AVM_APP_BOT_USER_ID = $script:originalBotUserId
    $env:PSModulePath = $script:originalModulePath
}

Describe 'Existing repository-sync publication core' -Tag Component {
    BeforeEach {
        $env:GH_TOKEN = 'offline-test-token'
        $env:AVM_APP_BOT_LOGIN = 'azure-verified-modules[bot]'
        $env:AVM_APP_BOT_USER_ID = '187664033'
        $script:state = @{
            Repo = [pscustomobject]@{ id = 42; full_name = 'Azure/bicep-registry-modules'; default_branch = 'main'; fork = $false; archived = $false; disabled = $false; allow_squash_merge = $true; permissions = @{ push = $true } }
            MainSha = 'a' * 40
            LocalHead = 'a' * 40
            RemoteHead = $null
            OldTree = '2' * 40
            MergedTree = '2' * 40
            Branch = $null
            HasPullRequest = $false
            Merged = $false
            AutoMerge = $null
            HumanHead = $false
            NoChanges = $false
            RejectPush = $false
            CloneRetries = -1
            PrBody = $null
            CleanupFailureEnabled = $false
            LocalPaths = @('.github/CODEOWNERS')
            RemotePaths = @('.github/CODEOWNERS')
            OwnerErrors = @()
            Root = $null
            CreateGithub = $true
            InitialCodeowners = $script:terraformContent
            PreparedCodeownersBytes = @()
            GitCalls = [System.Collections.Generic.List[object]]::new()
            GhCalls = [System.Collections.Generic.List[object]]::new()
            ApiCalls = [System.Collections.Generic.List[string]]::new()
        }
        Mock Invoke-RepositoryGit { param($Arguments, $WorkingDirectory, $MaxRetries) Invoke-CoreGit @PSBoundParameters }
        Mock Invoke-RepositoryGitHubApi { param($Endpoint) Invoke-CoreApi $Endpoint }
        Mock Get-RepositoryBranchHead {
            param($Repository, $Branch)
            if ($Branch -eq 'main') { return $script:state.MainSha }
            $script:state.Branch = $Branch
            if ($Branch -match '^avm-bot/pre-commit-[0-9]{14}$' -and $script:state.RemoteHead -ceq ('b' * 40)) { return $null }
            return $script:state.RemoteHead
        }
        Mock Invoke-RepositoryGitHub {
            param($Arguments, $AsJson, $MaxRetries)
            $script:state.GhCalls.Add($Arguments)
            if ($Arguments[0] -eq 'api') {
                return [pscustomobject]@{ data = @{ viewer = @{ login = 'azure-verified-modules[bot]'; databaseId = 187664033 } } }
            }
            if ($Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'create') {
                $script:state.HasPullRequest = $true
                $script:state.PrBody = Get-Content -LiteralPath $Arguments[([array]::IndexOf($Arguments, '--body-file') + 1)] -Raw
                return "https://github.com/$($script:state.Repo.full_name)/pull/123"
            }
            if ($Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'merge') {
                $script:state.Merged = $true
                $script:state.MainSha = 'd' * 40
                return ''
            }
            throw 'An unexpected remote command was attempted.'
        }
        Mock Remove-AvmMetadataFileConflict { $false }
        Mock Resolve-AvmManagedFilesUpgradeDecision { @{ Upgrade = $false; Reason = 'current pin' } }
        Mock Invoke-AvmPreCommitWithUpgradeRetry {
            [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'main.tf'), 'prepared')
            [pscustomobject]@{ Status = 'pass'; Steps = @() }
        }
    }

    It 'uses the original Terraform preparation and publication defaults through the shared core' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.LocalPaths = @('main.tf', '.github/CODEOWNERS')
        $script:state.RemotePaths = @('main.tf', '.github/CODEOWNERS')
        $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $false -issueLog @()
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $result.HasChanges | Should -BeTrue
        $result.IssueLog | Should -HaveCount 0
        [System.Text.Encoding]::UTF8.GetString($script:state.PreparedCodeownersBytes) | Should -BeExactly $script:terraformContent
        $script:state.Branch | Should -Match '^avm-bot/pre-commit-[0-9]{14}$'
        $script:state.Merged | Should -BeTrue
        $script:state.CloneRetries | Should -Be 5
        $clone = @($script:state.GitCalls | Where-Object { $_[0] -eq 'clone' })[0]
        $clone[0..5] | Should -Be @('clone', '--quiet', '--depth', '1', '--branch', 'main')
        $clone | Should -Not -Contain '--no-checkout'
        $clone | Should -Not -Contain '--filter=blob:none'
        $commit = @($script:state.GitCalls | Where-Object { $_ -contains 'commit' })[0]
        $commit | Should -Contain 'user.name=azure-verified-modules[bot]'
        $commit | Should -Contain 'user.email=187664033+azure-verified-modules[bot]@users.noreply.github.com'
        $commit[-2..-1] | Should -Be @('-m', 'chore: run avm pre-commit [skip ci]')
        $create = @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'create' })[0]
        $create | Should -Contain 'chore: run avm pre-commit [skip ci]'
        $create | Should -Contain '--base=main'
        $create | Should -Contain "--head=$($script:state.Branch)"
        $create | Should -Not -Contain '--no-maintainer-edit'
        $script:state.PrBody | Should -BeExactly @"
Automated ``avm pre-commit`` run from [azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools).

This PR is opened and merged by the AVM bot. ``[skip ci]`` is set on the commit so downstream workflows are not retriggered.
"@
        $merge = @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'merge' })[0]
        $merge | Should -Contain '--delete-branch'
        $merge | Should -Contain '--admin'
        $merge | Should -Contain '--squash'
        $merge | Should -Contain '--subject'
        $merge | Should -Contain 'chore: run avm pre-commit [skip ci]'
        $merge | Should -Contain '--body='
        $merge | Should -Contain '--match-head-commit'
        $merge | Should -Contain ('c' * 40)
        $script:state.ApiCalls | Should -HaveCount 0
        Should -Invoke Invoke-RepositoryGitHub -Exactly 1 -ParameterFilter { $Arguments -contains 'merge' -and $MaxRetries -eq 5 }
        Test-Path -LiteralPath $script:state.Root | Should -BeFalse
    }

    It 'fails before pushing when fallback bot identity configuration is invalid' {
        $env:AVM_APP_BOT_USER_ID = 'not-a-number'
        { Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $false -issueLog @() } |
            Should -Throw '*AVM_APP_BOT_USER_ID*'
        @($script:state.GitCalls | Where-Object { $_[0] -eq 'push' }) | Should -HaveCount 0
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' }) | Should -HaveCount 0
    }

    It 'preserves Terraform plan-only behavior without opening or merging a candidate' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.LocalPaths = @('main.tf', '.github/CODEOWNERS')
        $script:state.RemotePaths = @('main.tf', '.github/CODEOWNERS')
        $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $true -issueLog @()
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $result.HasChanges | Should -BeTrue
        [System.Text.Encoding]::UTF8.GetString($script:state.PreparedCodeownersBytes) | Should -BeExactly $script:terraformContent
        $script:state.GhCalls | Should -HaveCount 0
        $script:state.ApiCalls | Should -HaveCount 0
        @($script:state.GitCalls | Where-Object { $_ -contains 'add' -or $_ -contains 'commit' }) | Should -HaveCount 0
        @($script:state.GitCalls | Where-Object { $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'preserves Terraform no-change behavior and the caller issue array' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.NoChanges = $true
        $script:state.InitialCodeowners = $script:terraformContent
        Mock Invoke-AvmPreCommitWithUpgradeRetry { [pscustomobject]@{ Status = 'pass'; Steps = @() } }
        $issues = @('existing issue')
        $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $false -issueLog $issues
        @($result.Keys | Sort-Object) | Should -Be @('HasChanges', 'IssueLog')
        $result.HasChanges | Should -BeFalse
        [System.Text.Encoding]::UTF8.GetString($script:state.PreparedCodeownersBytes) | Should -BeExactly $script:state.InitialCodeowners
        [object]::ReferenceEquals($result.IssueLog, $issues) | Should -BeTrue
        $script:state.GhCalls | Should -HaveCount 0
        $script:state.ApiCalls | Should -HaveCount 0
        @($script:state.GitCalls | Where-Object { $_ -contains 'add' -or $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'stages a changed Terraform candidate before any remote operation in <Mode> mode' -ForEach @(
        @{ Mode = 'plan-only'; Plan = $true }
        @{ Mode = 'apply'; Plan = $false }
    ) {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.LocalPaths = @('main.tf', '.github/CODEOWNERS')
        $candidateDirectory = Join-Path $TestDrive "candidate-$Mode"
        $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' `
            -repoId 'avm-res-test' -repositoryConfigDir 'configuration' -defaultBranch main `
            -planOnly $Plan -candidateOutputDirectory $candidateDirectory -issueLog @()
        $result.HasChanges | Should -BeTrue
        $manifest = Get-Content -LiteralPath (Join-Path $candidateDirectory 'candidate.json') -Raw | ConvertFrom-Json -AsHashtable
        $manifest.phase | Should -BeExactly 'prepared'
        $manifest.hasChanges | Should -BeTrue
        $manifest.planOnly | Should -Be $Plan
        $manifest.repository | Should -BeExactly 'Azure/terraform-test'
        $manifest.baseSha | Should -BeExactly ('a' * 40)
        $manifest.headSha | Should -BeExactly ('c' * 40)
        $manifest.treeSha | Should -BeExactly ('2' * 40)
        $manifest.changedPaths | Should -Be @('main.tf', '.github/CODEOWNERS')
        $manifest.authoringSource | Should -BeExactly 'gallery'
        $manifest.authoringVersion | Should -BeExactly '0.0.0'
        (Get-Item -LiteralPath (Join-Path $candidateDirectory 'candidate.tar')).Length | Should -BeGreaterThan 0
        (Get-Item -LiteralPath (Join-Path $candidateDirectory 'candidate.patch')).Length | Should -BeGreaterThan 0
        @($script:state.GitCalls | Where-Object { $_ -contains 'commit' }) | Should -HaveCount 1
        @($script:state.GitCalls | Where-Object { $_[0] -eq 'push' }) | Should -HaveCount 0
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' }) | Should -HaveCount 0
    }

    It 'stages only newly added managed paths before archiving a plan-only candidate' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:managedPath = '.github/skills/avm-tf-azapi/scripts/Get-AzureSchema.ps1'
        $script:state.LocalPaths = @($script:managedPath, '.github/CODEOWNERS')
        Mock Invoke-AvmPreCommitWithUpgradeRetry {
            $path = Join-Path (Get-Location) ($script:managedPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
            [System.IO.File]::WriteAllText($path, "Write-Output 'managed'`n")
            [pscustomobject]@{
                Status = 'pass'
                Steps = @([pscustomobject]@{
                        Step = 'sync'
                        Status = 'pass'
                        Result = [pscustomobject]@{ Added = @($script:managedPath) }
                    })
            }
        }

        $candidateDirectory = Join-Path $TestDrive 'managed-file-candidate'
        $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' `
            -repoId 'avm-res-test' -repositoryConfigDir 'configuration' -defaultBranch main `
            -planOnly $true -candidateOutputDirectory $candidateDirectory -issueLog @()

        $result.HasChanges | Should -BeTrue
        $forced = @($script:state.GitCalls | Where-Object { $_[0] -eq 'add' -and $_ -contains '--force' })
        $forced | Should -HaveCount 1
        $forced[0] | Should -Be @('add', '--force', '--', $script:managedPath)
        $manifest = Get-Content -LiteralPath (Join-Path $candidateDirectory 'candidate.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $manifest.changedPaths | Should -Contain $script:managedPath
        @($script:state.GitCalls | Where-Object { $_[0] -eq 'push' }) | Should -HaveCount 0
    }

    It 'skips local commits and remote operations when pre-commit produces no changes' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.NoChanges = $true
        Mock Invoke-AvmPreCommitWithUpgradeRetry { [pscustomobject]@{ Status = 'pass'; Steps = @() } }
        $candidateDirectory = Join-Path $TestDrive 'candidate-unchanged'
        $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' `
            -repoId 'avm-res-test' -repositoryConfigDir 'configuration' -defaultBranch main `
            -planOnly $true -candidateOutputDirectory $candidateDirectory -issueLog @()
        $result.HasChanges | Should -BeFalse
        $manifest = Get-Content -LiteralPath (Join-Path $candidateDirectory 'candidate.json') -Raw | ConvertFrom-Json -AsHashtable
        $manifest.phase | Should -BeExactly 'prepared'
        $manifest.hasChanges | Should -BeFalse
        @($script:state.GitCalls | Where-Object { $_ -contains 'add' -or $_ -contains 'commit' -or $_[0] -eq 'push' }) |
            Should -HaveCount 0
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' }) | Should -HaveCount 0
    }

    It 'publishes the matching validated tree using the original bot branch and merge path' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.LocalPaths = @('main.tf')
        $script:state.RemotePaths = @('main.tf')
        $directory = Join-Path $TestDrive 'validated-candidate'
        $receipt = New-CorePreparedArtifact -Directory $directory
        $result = Invoke-RepositorySyncCandidatePublication -Repository 'Azure/terraform-test' `
            -CandidateDirectory $directory -ReceiptDirectory $receipt
        $result.Status | Should -BeExactly 'Merged'
        $script:state.Merged | Should -BeTrue
        @($script:state.GitCalls | Where-Object { $_[0] -eq 'push' }) | Should -HaveCount 1
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'create' }) | Should -HaveCount 1
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'merge' }) | Should -HaveCount 1
    }

    It 'does not push a validated candidate when the target branch moved' {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $directory = Join-Path $TestDrive 'outdated-candidate'
        $receipt = New-CorePreparedArtifact -Directory $directory -BaseSha ('e' * 40)
        { Invoke-RepositorySyncCandidatePublication -Repository 'Azure/terraform-test' `
            -CandidateDirectory $directory -ReceiptDirectory $receipt } |
            Should -Throw '*target branch moved since candidate validation*'
        @($script:state.GitCalls | Where-Object { $_[0] -eq 'push' }) | Should -HaveCount 0
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' }) | Should -HaveCount 0
    }

    It 'propagates Terraform preparation and publication failures without reporting success' -ForEach @(
        'clone', 'prepare', 'codeowners', 'commit', 'push', 'create', 'merge'
    ) {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.LocalPaths = @('main.tf')
        $script:state.RemotePaths = @('main.tf')
        $script:failureStage = $_
        if ($_ -eq 'prepare') {
            Mock Invoke-AvmPreCommitWithUpgradeRetry { throw 'prepare failed' }
        } elseif ($_ -eq 'codeowners') {
            Mock Set-TerraformCodeowners { throw 'codeowners failed' }
        } elseif ($_ -in @('clone', 'commit', 'push')) {
            Mock Invoke-RepositoryGit { throw "$script:failureStage failed" } -ParameterFilter { $Arguments -contains $script:failureStage }
        } else {
            Mock Invoke-RepositoryGitHub { throw "$script:failureStage failed" } -ParameterFilter { $Arguments -contains $script:failureStage }
        }
        { Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -repoId 'avm-res-test' `
            -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $false -issueLog @() } |
            Should -Throw "*Administrative corrective action is required*$script:failureStage failed*"
        $script:state.Merged | Should -BeFalse
        if ($script:state.Root) { Test-Path -LiteralPath $script:state.Root | Should -BeFalse }
    }

    It 'keeps cleanup failure as a warning without masking the Terraform outcome' -ForEach @($false, $true) {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.NoChanges = $true
        $script:state.CleanupFailureEnabled = $true
        Mock Remove-Item { throw [System.IO.IOException]::new('cleanup unavailable') } -ParameterFilter {
            $script:state.CleanupFailureEnabled -and $script:state.Root -and
            $LiteralPath -ceq (Split-Path -Parent $script:state.Root)
        }
        Mock Write-Warning {}
        if ($_) { Mock Invoke-AvmPreCommitWithUpgradeRetry { throw 'prepare failed' } }
        try {
            if ($_) {
                { Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -defaultBranch main -issueLog @() } |
                    Should -Throw '*prepare failed*'
            } else {
                $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' -defaultBranch main -issueLog @()
                $result.HasChanges | Should -BeFalse
            }
            Should -Invoke Write-Warning -Exactly 1 -ParameterFilter { $Message -like 'Failed to clean up*cleanup unavailable*' }
        } finally {
            $script:state.CleanupFailureEnabled = $false
            if ($script:state.Root) {
                & $script:removeItemCommand -LiteralPath (Split-Path -Parent $script:state.Root) -Recurse -Force
            }
        }
    }

    It 'repairs a legacy Terraform header with LF and UTF-8 without BOM' {
        $retired = 'avm-terraform-' + 'governance'
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.InitialCodeowners = ([string][char]0xFEFF) + "# This file is managed by $retired.`r`n* @old-owner`r`n"
        $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' `
            -repoId 'avm-res-test' -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $true -issueLog @()
        $result.HasChanges | Should -BeTrue
        [System.Text.Encoding]::UTF8.GetString($script:state.PreparedCodeownersBytes) | Should -BeExactly $script:terraformContent
        $script:state.PreparedCodeownersBytes | Should -Not -Contain 13
        ($script:state.PreparedCodeownersBytes[0..2] -join ',') | Should -Not -Be '239,187,191'
        $script:state.GhCalls | Should -HaveCount 0
    }

    It 'creates Terraform CODEOWNERS when <MissingPath> is missing' -ForEach @(
        @{ MissingPath = 'the file'; CreateGithub = $true }
        @{ MissingPath = 'the .github directory'; CreateGithub = $false }
    ) {
        $script:state.Repo.full_name = 'Azure/terraform-test'
        $script:state.InitialCodeowners = $null
        $script:state.CreateGithub = $CreateGithub
        $result = Invoke-AvmPreCommitForRepository @script:terraformOwnership -orgAndRepoName 'Azure/terraform-test' `
            -repoId 'avm-res-test' -repositoryConfigDir 'configuration' -defaultBranch main -planOnly $true -issueLog @()
        $result.HasChanges | Should -BeTrue
        [System.Text.Encoding]::UTF8.GetString($script:state.PreparedCodeownersBytes) | Should -BeExactly $script:terraformContent
        $script:state.GhCalls | Should -HaveCount 0
        @($script:state.GitCalls | Where-Object { $_ -contains 'push' }) | Should -HaveCount 0
    }

    It 'publishes a verified review-only metadata candidate without requiring merge capability' {
        $script:state.Repo.allow_squash_merge = $false
        $script:state.LocalPaths = @('metadata.json')
        $script:state.RemotePaths = @('metadata.json')
        $result = Invoke-RepositoryFileSync -Repository 'Azure/bicep-registry-modules' -DefaultBranch main `
            -StableBranch 'avm-bot/bicep-metadata-backfill' -ExpectedActor (New-CoreActor) `
            -AllowedPaths @('metadata.json') -FullCheckout -VerifyCandidate -ReviewOnly `
            -Title 'chore: backfill Bicep module metadata' -Prepare {
                param($context)
                [System.IO.File]::WriteAllText((Join-Path $context.Root 'metadata.json'), '{}')
            }
        $result.Status | Should -Be 'ReviewRequired'
        $result.PullRequestUrl | Should -Be 'https://github.com/Azure/bicep-registry-modules/pull/123'
        $script:state.Merged | Should -BeFalse
        $clone = @($script:state.GitCalls | Where-Object { $_[0] -eq 'clone' })[0]
        $clone | Should -Not -Contain '--no-checkout'
        @($script:state.GitCalls | Where-Object { $_[0] -eq 'sparse-checkout' }) | Should -HaveCount 0
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'create' }) | Should -HaveCount 1
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' -and $_[1] -eq 'merge' }) | Should -HaveCount 0
    }

    It 'keeps review-only plans strictly read-only even when changes exist' {
        $result = Invoke-RepositoryFileSync -Repository 'Azure/bicep-registry-modules' -DefaultBranch main `
            -StableBranch 'avm-bot/bicep-metadata-backfill' -ExpectedActor (New-CoreActor) `
            -AllowedPaths @('.github/CODEOWNERS') -VerifyCandidate -ReviewOnly -PlanOnly `
            -GeneratedFiles @{ '.github/CODEOWNERS' = $script:terraformContent }
        $result.Status | Should -Be 'Planned'
        $result.PullRequestUrl | Should -BeNullOrEmpty
        @($script:state.GitCalls | Where-Object { $_ -contains 'add' -or $_ -contains 'commit' -or $_ -contains 'push' }) | Should -HaveCount 0
        @($script:state.GhCalls | Where-Object { $_[0] -eq 'pr' }) | Should -HaveCount 0
    }
}

Describe 'Original repository-sync preparation regressions' -Tag Component {
    It 'resolves the checkout module by name from the isolated source-only catalog' {
        $module = Import-Module Avm.Authoring -PassThru -ErrorAction Stop
        $module.Path | Should -BeExactly (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psm1')
    }

    It 'retains the standalone pre-commit result, metadata, and upgrade cases' {
        { & (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'Test-AvmPreCommit.ps1') } | Should -Not -Throw
    }

    It 'retains the original managed-file pin fallback and upgrade decisions' {
        { & (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'Test-ManagedFilesUpgrade.ps1') } | Should -Not -Throw
    }

    It 'keeps standalone input-contract checks valid after shared-library extraction' {
        { & (Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'scripts' 'Test-RepositorySyncInputs.ps1') } | Should -Not -Throw
    }

    It 'loads the module before local Git in a fresh process with Actions mode <ActionsContext>' -ForEach @(
        @{ ActionsContext = 'false' }
        @{ ActionsContext = 'true' }
    ) {
        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $child = @'
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$env:PSModulePath = (Join-Path $env:SYNC_TEST_ROOT 'src') + [System.IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
if (Get-Module Avm.Authoring) { throw 'The child must start without Avm.Authoring loaded.' }
$available = @(Get-Module -ListAvailable Avm.Authoring)
if ($available.Count -ne 1 -or $available[0].Path -cne (Join-Path $env:SYNC_TEST_ROOT 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')) { throw 'The child module catalog is not isolated to the checkout.' }
. (Join-Path $env:SYNC_TEST_ROOT 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryFileSync.ps1')
if (Get-Command Invoke-AvmPreCommitForRepository -ErrorAction SilentlyContinue) { throw 'The shared library loaded the Terraform adapter.' }
if (-not (Get-Command Invoke-RepositoryFileSync -CommandType Function)) { throw 'The standalone shared core is missing.' }
. (Join-Path $env:SYNC_TEST_ROOT 'repository-management' 'repository-sync' 'scripts' 'lib' 'AvmPreCommit.ps1')
function Invoke-RepositoryFileSync {
    param($Repository, $DefaultBranch, $PlanOnly, $State, $Prepare)
    $module = Get-Module Avm.Authoring
    if (-not $module) { throw 'Missing module before clone.' }
    if ($module.Path -cne (Join-Path $env:SYNC_TEST_ROOT 'src' 'Avm.Authoring' 'Avm.Authoring.psm1')) { throw 'The probe did not load the checkout module.' }
    $probe = Invoke-RepositorySyncProcess -Command git -Arguments @('--version')
    if ($probe.ExitCode -ne 0 -or $probe.StdOut -notmatch '^git version ') { throw 'Local Git transport failed.' }
    return @{ HasChanges = $false; Status = 'NoChange' }
}
$result = Invoke-AvmPreCommitForRepository -orgAndRepoName 'Azure/offline-test' -defaultBranch main -issueLog @() `
    -codeOwnersDefaultTeams @() -codeOwnersFileProtectionTeams @('engineering-reviewers')
if ($result.HasChanges -or $result.Count -ne 2) { throw 'Unexpected legacy result.' }
'fresh-process-transport-ok'
'@
        $modulePath = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psm1'
        $module = Get-Module Avm.Authoring | Where-Object { $_.Path -ceq $modulePath } | Select-Object -First 1
        $output = & $module {
            param($Executable, $Code, $Root, $ActionsMode)
            Invoke-AvmProcess -FilePath $Executable -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $Code) `
                -TimeoutSec 60 -EnvVars @{
                    SYNC_TEST_ROOT = $Root
                    PSModulePath = (Join-Path $Root 'src') + [System.IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
                    GITHUB_ACTIONS = $ActionsMode
                    GH_TOKEN = $null
                    GITHUB_TOKEN = $null
                }
        } $pwsh $child $script:repoRoot $ActionsContext
        $output.ExitCode | Should -Be 0
        $lines = @($output.StdOut.TrimEnd() -split '\r?\n')
        $lines[-1] | Should -BeExactly 'fresh-process-transport-ok'
        @($lines | Where-Object { $_ -ceq 'fresh-process-transport-ok' }) | Should -HaveCount 1
    }
}

Describe 'Checked-out authoring source preview' -Tag Component {
    It 'keeps the version opt-out inside the imported module without a Gallery upgrade' {
        $root = Join-Path $TestDrive ('terraform-preview-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), "terraform {}`n")
        $source = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'

        Mock Import-Module {} -ParameterFilter { $Name -ceq $source }
        Mock Test-AvmModuleVersion -ModuleName Avm.Authoring {
            if (-not $SkipModuleVersionCheck) {
                throw [System.InvalidOperationException]::new('A nested Gallery version check was not skipped.')
            }
        }
        Mock Resolve-AvmCommandTool -ModuleName Avm.Authoring { @() }
        Mock Test-AvmMetadataModules -ModuleName Avm.Authoring { [pscustomobject]@{ Status = 'pass'; Issues = @() } }
        Mock Invoke-AvmSync -ModuleName Avm.Authoring { [pscustomobject]@{ Status = 'pass' } }
        Mock Invoke-AvmCheckConvention -ModuleName Avm.Authoring { [pscustomobject]@{ Status = 'pass' } }
        Mock Invoke-AvmTransform -ModuleName Avm.Authoring { [pscustomobject]@{ Status = 'pass' } }
        Mock Invoke-AvmFormat -ModuleName Avm.Authoring { [pscustomobject]@{ Status = 'pass' } }
        Mock Invoke-AvmDocs -ModuleName Avm.Authoring { [pscustomobject]@{ Status = 'pass' } }
        Mock Update-PSResource { throw 'The Gallery must not be upgraded during a source preview.' }

        Push-Location $root
        try {
            $result = Invoke-AvmPreCommitWithUpgradeRetry -repoId 'avm-res-test' `
                -repositoryConfigDir 'configuration' -modulePath $source
            $result.Status | Should -BeExactly 'pass'
            Should -Invoke Test-AvmModuleVersion -ModuleName Avm.Authoring -Exactly 2 -ParameterFilter {
                $SkipModuleVersionCheck
            }
            Should -Invoke Update-PSResource -Exactly 0
        }
        finally {
            Pop-Location
        }
    }
}
