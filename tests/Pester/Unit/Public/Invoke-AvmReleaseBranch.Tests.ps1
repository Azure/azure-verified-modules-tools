#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-AvmReleaseBranch' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:scenario = @{
                Repo = @{
                    fork = $false; default_branch = 'main'; permissions = @{ push = $true }
                    owner = @{ login = 'Azure' }
                    allow_squash_merge = $true; allow_merge_commit = $false; allow_rebase_merge = $false
                }
                Pr = @{
                    state = 'open'; draft = $false; title = 'Example'
                    base = @{ ref = 'main'; repo = @{ full_name = 'Azure/bicep-registry-modules' } }
                    head = @{
                        sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                        repo = @{ fork = $true; owner = @{ login = 'contributor' } }
                    }
                    mergeable = $true; mergeable_state = 'clean'
                }
                Calls = [System.Collections.Generic.List[object]]::new()
                Failure = ''
                ChangedHead = $false
                ReleaseSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                ChangedReleaseAfterMerge = $false
            }
            Mock Test-AvmModuleVersion {}
            Mock Start-Sleep {}
            Mock Invoke-AvmGitHubApi {
                param($Endpoint, $Method = 'GET', $Body)
                $script:scenario.Calls.Add(@{ Endpoint = $Endpoint; Method = $Method; Body = $Body })
                if ($script:scenario.Failure -ceq "$Method $Endpoint") { throw 'injected failure' }
                switch -Regex ("$Method $Endpoint") {
                    '^GET repos/[^/]+/[^/]+$' { return $script:scenario.Repo }
                    '^GET repos/[^/]+/[^/]+/git/ref/heads/main$' {
                        return @{ object = @{ sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' } }
                    }
                    '^GET repos/[^/]+/[^/]+/git/ref/heads/release/' {
                        return @{ object = @{ sha = $script:scenario.ReleaseSha } }
                    }
                    '^GET repos/[^/]+/[^/]+/pulls/123$' {
                        if ($script:scenario.ChangedHead -and $script:scenario.Pr.base.ref -cne 'main') {
                            $script:scenario.Pr.head.sha = 'cccccccccccccccccccccccccccccccccccccccc'
                        }
                        return $script:scenario.Pr
                    }
                    '^PATCH repos/[^/]+/[^/]+/pulls/123$' {
                        $script:scenario.Pr.base.ref = $Body.base
                        return @{}
                    }
                    '^PUT repos/[^/]+/[^/]+/pulls/123/merge$' {
                        $script:scenario.ReleaseSha = if ($script:scenario.ChangedReleaseAfterMerge) {
                            'dddddddddddddddddddddddddddddddddddddddd'
                        }
                        else { 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
                        return @{ merged = $true; sha = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
                    }
                    '^POST repos/[^/]+/[^/]+/pulls$' {
                        return @{ number = 456; html_url = 'https://github.com/Azure/example/pull/456' }
                    }
                    '^POST repos/[^/]+/[^/]+/(git/refs|issues/456/labels)$' { return @{} }
                    default { throw "Unexpected API call: $Method $Endpoint" }
                }
            }
        }
    }

    It 'creates the Bicep handoff in order and labels the follow-up for E2E' {
        InModuleScope Avm.Authoring {
            $result = Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                -PullRequest 123
            $result.ReleaseBranch | Should -BeExactly 'release/fork-pr-123-aaaaaaaaaaaa'
            $result.FollowUpPullRequestUrl | Should -BeExactly 'https://github.com/Azure/example/pull/456'
            $writes = @($script:scenario.Calls | Where-Object Method -NE 'GET')
            ($writes.Method -join ',') | Should -BeExactly 'POST,PATCH,PUT,POST,POST'
            $writes[0].Body.sha | Should -BeExactly 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            $writes[0].Body.ref | Should -BeExactly 'refs/heads/release/fork-pr-123-aaaaaaaaaaaa'
            $writes[1].Body.base | Should -BeExactly $result.ReleaseBranch
            $result.HeadCommit | Should -BeExactly 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $writes[2].Body.sha | Should -BeExactly $result.HeadCommit
            $writes[2].Body.merge_method | Should -BeExactly 'squash'
            $writes[3].Body.head | Should -BeExactly $result.ReleaseBranch
            $writes[3].Body.base | Should -BeExactly 'main'
            $writes[4].Body.labels | Should -Contain 'PR: Run Required E2E Tests'
        }
    }

    It 'creates a Terraform handoff without applying the Bicep-specific label' {
        InModuleScope Avm.Authoring {
            $script:scenario.Pr.base.repo.full_name = 'Azure/terraform-azurerm-avm-res-example'
            $null = Invoke-AvmReleaseBranch -Repository 'Azure/terraform-azurerm-avm-res-example' `
                -PullRequest 123
            @($script:scenario.Calls | Where-Object Endpoint -Match '/labels$').Count | Should -Be 0
        }
    }

    It 'uses the current PR head and creates the release branch from main' {
        InModuleScope Avm.Authoring {
            $script:scenario.Pr.head.sha = 'cccccccccccccccccccccccccccccccccccccccc'
            $script:scenario.Pr.base.ref = 'maintenance'
            $result = Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' -PullRequest 123
            $result.HeadCommit | Should -BeExactly 'cccccccccccccccccccccccccccccccccccccccc'
            $result.ReleaseBranch | Should -BeExactly 'release/fork-pr-123-cccccccccccc'
            @($script:scenario.Calls | Where-Object Method -EQ 'PUT')[0].Body.sha | Should -BeExactly $result.HeadCommit
            @($script:scenario.Calls | Where-Object Endpoint -Match '/git/refs$')[0].Body.sha |
                Should -BeExactly 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            @($script:scenario.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Endpoint -match '/pulls$' })[0].Body.base |
                Should -BeExactly 'main'
        }
    }

    It 'uses another enabled merge method if squash is disabled' {
        InModuleScope Avm.Authoring {
            $script:scenario.Repo.allow_squash_merge = $false
            $script:scenario.Repo.allow_merge_commit = $true
            $null = Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                -PullRequest 123
            @($script:scenario.Calls | Where-Object Method -EQ 'PUT')[0].Body.merge_method | Should -BeExactly 'merge'
        }
    }

    It 'previews without making writes' {
        InModuleScope Avm.Authoring {
            $null = Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                -PullRequest 123 -WhatIf
            @($script:scenario.Calls | Where-Object Method -NE 'GET').Count | Should -Be 0
        }
    }

    It 'routes the shared CLI verb and WhatIf without making writes' {
        InModuleScope Avm.Authoring {
            $null = Invoke-Avm 'release-branch' '--repository' 'Azure/bicep-registry-modules' `
                '--pull-request' '123' '--whatif'
            @($script:scenario.Calls | Where-Object Method -NE 'GET').Count | Should -Be 0
            @($script:scenario.Calls | Where-Object Method -EQ 'GET').Count | Should -Be 3
        }
    }

    It 'honors offline mode before any GitHub request' {
        InModuleScope Avm.Authoring {
            $original = [Environment]::GetEnvironmentVariable('AVM_OFFLINE', 'Process')
            try {
                $env:AVM_OFFLINE = '1'
                { Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                        -PullRequest 123 } |
                    Should -Throw '*AVM_OFFLINE=1*'
                $script:scenario.Calls.Count | Should -Be 0
            }
            finally {
                if ($null -eq $original) {
                    [Environment]::SetEnvironmentVariable('AVM_OFFLINE', [NullString]::Value, 'Process')
                }
                else {
                    [Environment]::SetEnvironmentVariable('AVM_OFFLINE', $original, 'Process')
                }
            }
        }
    }

    It 'rejects invalid trust and permission boundaries before writing (<Case>)' -ForEach @(
        @{ Case = 'same owner' }
        @{ Case = 'not a fork' }
        @{ Case = 'wrong upstream' }
        @{ Case = 'draft' }
        @{ Case = 'closed' }
        @{ Case = 'no write permission' }
        @{ Case = 'no merge method' }
        @{ Case = 'invalid head' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Case = $Case } {
            param($Case)
            switch ($Case) {
                'same owner' { $script:scenario.Pr.head.repo.owner.login = 'Azure' }
                'not a fork' { $script:scenario.Pr.head.repo.fork = $false }
                'wrong upstream' { $script:scenario.Pr.base.repo.full_name = 'Azure/other' }
                'draft' { $script:scenario.Pr.draft = $true }
                'closed' { $script:scenario.Pr.state = 'closed' }
                'no write permission' { $script:scenario.Repo.permissions.push = $false }
                'no merge method' { $script:scenario.Repo.allow_squash_merge = $false }
                'invalid head' { $script:scenario.Pr.head.sha = 'not-a-commit' }
            }
            { Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                    -PullRequest 123 } | Should -Throw
            @($script:scenario.Calls | Where-Object Method -NE 'GET').Count | Should -Be 0
        }
    }

    It 'stops after retargeting when the captured head changes' {
        InModuleScope Avm.Authoring {
            $script:scenario.ChangedHead = $true
            { Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                    -PullRequest 123 } |
                Should -Throw '*manual recovery*captured head changed*'
            @($script:scenario.Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 0
        }
    }

    It 'does not bypass blocked branch protections' {
        InModuleScope Avm.Authoring {
            $script:scenario.Pr.mergeable_state = 'blocked'
            { Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                    -PullRequest 123 } |
                Should -Throw '*blocked*without bypassing protections*'
            @($script:scenario.Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 0
        }
    }

    It 'does not open a follow-up when GitHub rejects the merge' {
        InModuleScope Avm.Authoring {
            $script:scenario.Failure = 'PUT repos/Azure/bicep-registry-modules/pulls/123/merge'
            { Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                    -PullRequest 123 } |
                Should -Throw '*merging the fork pull request*injected failure*'
            @($script:scenario.Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 1
            @($script:scenario.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Endpoint -match '/pulls$' }).Count | Should -Be 0
        }
    }

    It 'stops if the release branch changes before the merge' {
        InModuleScope Avm.Authoring {
            $script:scenario.ReleaseSha = 'dddddddddddddddddddddddddddddddddddddddd'
            { Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                    -PullRequest 123 } |
                Should -Throw '*release branch changed before the fork merge*'
            @($script:scenario.Calls | Where-Object Method -EQ 'PUT').Count | Should -Be 0
        }
    }

    It 'does not open a follow-up when the release branch changes after the merge' {
        InModuleScope Avm.Authoring {
            $script:scenario.ChangedReleaseAfterMerge = $true
            { Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                    -PullRequest 123 } |
                Should -Throw '*release branch no longer points*'
            @($script:scenario.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Endpoint -match '/pulls$' }).Count | Should -Be 0
        }
    }

    It 'surfaces label failure with the follow-up URL and does not retry' {
        InModuleScope Avm.Authoring {
            $script:scenario.Failure = 'POST repos/Azure/bicep-registry-modules/issues/456/labels'
            { Invoke-AvmReleaseBranch -Repository 'Azure/bicep-registry-modules' `
                    -PullRequest 123 } |
                Should -Throw '*https://github.com/Azure/example/pull/456*injected failure*'
            @($script:scenario.Calls | Where-Object Endpoint -Match '/labels$').Count | Should -Be 1
        }
    }
}
