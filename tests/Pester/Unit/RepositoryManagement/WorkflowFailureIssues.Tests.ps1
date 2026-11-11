BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $reviewerRoutingLib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    $lib = Join-Path $root 'repository-management' 'workflow-failure-issues' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $reviewerRoutingLib 'RepositoryFileAccess.ps1')
    . (Join-Path $reviewerRoutingLib 'ModuleOwners.ps1')
    . (Join-Path $reviewerRoutingLib 'RunSummary.ps1')
    . (Join-Path $lib 'WorkflowFailureIssues.ps1')
}

Describe 'Get-AvmWorkflowFailureModuleReference' {
    It 'converts a resource module workflow name into its top-level module path' {
        Get-AvmWorkflowFailureModuleReference -WorkflowName 'avm.res.storage.storage-account' | Should -Be 'avm/res/storage/storage-account'
    }

    It 'returns $null for a platform/shared workflow name' {
        Get-AvmWorkflowFailureModuleReference -WorkflowName '.Module - Check and Publish' | Should -BeNullOrEmpty
    }
}

Describe 'Get-AvmWorkflowFailureWorkflows' {
    It 'selects explicit maintenance workflow names without enabling unrelated CI workflows' {
        Mock Invoke-RepositoryGitHub {
            @([pscustomobject]@{
                    workflows = @(
                        [pscustomobject]@{ id = 1; name = 'Repos: Terraform Sync'; state = 'active' }
                        [pscustomobject]@{ id = 2; name = 'Repos: Bicep Sync'; state = 'active' }
                        [pscustomobject]@{ id = 3; name = 'Authoring: CI'; state = 'active' }
                    )
                })
        }
        $selected = @(Get-AvmWorkflowFailureWorkflows -Repository 'Azure/azure-verified-modules-tools' `
                -WorkflowName @('Repos: Terraform Sync', 'Repos: Bicep Sync'))
        $selected.name | Should -Be @('Repos: Terraform Sync', 'Repos: Bicep Sync')
        { Get-AvmWorkflowFailureWorkflows -Repository 'Azure/azure-verified-modules-tools' -WorkflowName @('Repos: Missing') } |
            Should -Throw '*missing or inactive*Repos: Missing*'
    }

    It 'slurps the paginated object-shaped workflows endpoint and never uses --jq' {
        Mock Invoke-RepositoryGitHub {
            @(
                [pscustomobject]@{
                    workflows = @(
                        [pscustomobject]@{ id = 1; name = 'avm.res.storage.storage-account'; state = 'active' }
                        [pscustomobject]@{ id = 2; name = 'avm.res.network.virtual-network'; state = 'disabled_manually' }
                    )
                }
                [pscustomobject]@{
                    workflows = @(
                        [pscustomobject]@{ id = 3; name = '.Module - Check and Publish'; state = 'active' }
                        [pscustomobject]@{ id = 4; name = '.Platform - Check PSRule'; state = 'active' }
                    )
                }
            )
        }

        $workflows = Get-AvmWorkflowFailureWorkflows -Repository 'Azure/bicep-registry-modules'

        Should -Invoke Invoke-RepositoryGitHub -Times 1 -ParameterFilter {
            $Arguments -contains '--paginate' -and
            $Arguments -contains '--slurp' -and
            $Arguments -notcontains '--jq'
        }
        $workflows.name | Should -Be @('avm.res.storage.storage-account', '.Module - Check and Publish')
    }
}

Describe 'Get-AvmWorkflowFailureRunHistory' {
    It 'counts failures across cancelled/skipped runs and stops at recovery: <Conclusions>' -ForEach @(
        @{ Conclusions = @('failure', 'cancelled', 'failure', 'skipped', 'failure', 'success'); Expected = @('failure', 'failure', 'failure') }
        @{ Conclusions = @('failure', 'success', 'failure', 'failure'); Expected = @('failure', 'success') }
        @{ Conclusions = @('cancelled', 'success', 'failure'); Expected = @('success') }
        @{ Conclusions = @('failure', 'failure'); Expected = @('failure', 'failure') }
    ) {
        $script:runs = @($Conclusions | ForEach-Object { [pscustomobject]@{ conclusion = $_; event = 'schedule' } })
        Mock Invoke-RepositoryGitHub { $script:runs }
        $history = @(Get-AvmWorkflowFailureRunHistory -Repository 'Azure/azure-verified-modules-tools' -WorkflowId 1 -Count 3)
        $history.conclusion | Should -Be $Expected
        Should -Invoke Invoke-RepositoryGitHub -Times 1 -ParameterFilter {
            $Arguments[1] -match 'branch=main&status=completed&per_page=100&page=1'
        }
    }

    It 'paginates past ignored runs but does not fetch beyond three eligible failures' {
        $script:firstPage = @(
            [pscustomobject]@{ conclusion = 'failure'; event = 'schedule' }
            1..99 | ForEach-Object { [pscustomobject]@{ conclusion = 'cancelled'; event = 'schedule' } }
        )
        Mock Invoke-RepositoryGitHub {
            if ($Arguments[1] -match 'page=1$') { return $script:firstPage }
            if ($Arguments[1] -match 'page=2$') {
                return @(
                    [pscustomobject]@{ conclusion = 'failure'; event = 'workflow_dispatch' }
                    [pscustomobject]@{ conclusion = 'failure'; event = 'push' }
                )
            }
            throw 'Unexpected extra page.'
        }
        @(Get-AvmWorkflowFailureRunHistory -Repository 'Azure/azure-verified-modules-tools' -WorkflowId 1 -Count 3) |
            Should -HaveCount 3
        Should -Invoke Invoke-RepositoryGitHub -Times 2 -Exactly
    }

    It 'does not count pull-request runs toward the maintenance failure streak' {
        Mock Invoke-RepositoryGitHub {
            @(
                [pscustomobject]@{ conclusion = 'failure'; event = 'pull_request' }
                [pscustomobject]@{ conclusion = 'failure'; event = 'pull_request_target' }
                [pscustomobject]@{ conclusion = 'success'; event = 'schedule' }
            )
        }
        $history = @(Get-AvmWorkflowFailureRunHistory -Repository 'Azure/azure-verified-modules-tools' -WorkflowId 1)
        $history | Should -HaveCount 1
        $history[0].conclusion | Should -Be 'success'
    }
}

Describe 'Get-AvmWorkflowFailureOpenIssues' {
    It 'paginates all open issues and excludes pull requests before matching incident titles' {
        Mock Invoke-RepositoryGitHub {
            @(
                [pscustomobject]@{
                    number = 42; title = '[Failed pipeline] Repos: Catalog Sync'
                    html_url = 'https://github.com/Azure/azure-verified-modules-tools/issues/42'
                    created_at = '2026-01-01T00:00:00Z'; labels = @(); body = 'Failed run.'
                }
                [pscustomobject]@{ number = 43; title = '[Failed pipeline] Not an issue'; pull_request = @{} }
                [pscustomobject]@{ number = 44; title = 'Unrelated issue' }
            )
        }
        $issues = @(Get-AvmWorkflowFailureOpenIssues -Repository 'Azure/azure-verified-modules-tools' -Maintenance)
        $issues | Should -HaveCount 1
        $issues[0].number | Should -Be 42
        $issues[0].url | Should -Be 'https://github.com/Azure/azure-verified-modules-tools/issues/42'
        $issues[0].body | Should -Be 'Failed run.'
        Should -Invoke Invoke-RepositoryGitHub -Times 1 -ParameterFilter {
            $Arguments -contains '--paginate' -and $Arguments -notcontains '--limit'
        }
    }

    It 'preserves the Bicep sweep issue lookup' {
        Mock Invoke-RepositoryGitHub {
            @([pscustomobject]@{ number = 42; title = '[Failed pipeline] avm.res.storage.storage-account' })
        }
        @(Get-AvmWorkflowFailureOpenIssues -Repository 'Azure/bicep-registry-modules') | Should -HaveCount 1
        Should -Invoke Invoke-RepositoryGitHub -Times 1 -ParameterFilter {
            $Arguments -contains 'issue' -and $Arguments -contains 'list' -and $Arguments -contains '500'
        }
    }
}

Describe 'Get-AvmWorkflowFailureIssueCommentsToday' {
    It 'fetches paginated comments and projects bodies client-side without --jq' {
        Mock Invoke-RepositoryGitHub {
            @(
                [pscustomobject]@{ body = 'first comment' }
                [pscustomobject]@{ body = 'second comment' }
            )
        }

        $bodies = Get-AvmWorkflowFailureIssueCommentsToday -Repository 'Azure/bicep-registry-modules' -Number 42

        Should -Invoke Invoke-RepositoryGitHub -Times 1 -ParameterFilter {
            $Arguments -contains '--paginate' -and
            $Arguments -notcontains '--jq'
        }
        $bodies | Should -Be @('first comment', 'second comment')
    }
}

Describe 'Get-AvmWorkflowFailureTeamMembers' {
    It 'reads all team members once and returns sorted unique logins' {
        Mock Invoke-RepositoryGitHub {
            @(
                ,@([pscustomobject]@{ login = 'user-two' }, [pscustomobject]@{ login = 'user-one' })
                ,@([pscustomobject]@{ login = 'user-two' })
            )
        }
        @(Get-AvmWorkflowFailureTeamMembers -Team 'Azure/engineering-owners') | Should -Be @('user-one', 'user-two')
        Should -Invoke Invoke-RepositoryGitHub -Times 1 -ParameterFilter {
            $Arguments -contains '--paginate' -and $Arguments -contains '--slurp' -and
            $Arguments -contains 'orgs/Azure/teams/engineering-owners/members?per_page=100'
        }
    }

    It 'fails explicitly on an empty or malformed team response: <Case>' -ForEach @(
        @{ Case = 'empty'; Members = @() }
        @{ Case = 'invalid login'; Members = @([pscustomobject]@{ login = 'invalid/name' }) }
        @{ Case = 'missing login'; Members = @([pscustomobject]@{ id = 1 }) }
    ) {
        $script:teamMembers = $Members
        Mock Invoke-RepositoryGitHub { ,@($script:teamMembers) }
        { Get-AvmWorkflowFailureTeamMembers -Team 'Azure/engineering-owners' } | Should -Throw
    }
}

Describe 'Resolve-AvmWorkflowFailureRouting' {
    BeforeEach {
        $script:run = [pscustomobject]@{ name = 'avm.res.storage.storage-account'; conclusion = 'failure'; html_url = 'https://github.com/Azure/bicep-registry-modules/actions/runs/1' }
    }

    It 'keeps the existing incident open without notifying on <Conclusion>' -ForEach @(
        @{ Conclusion = 'cancelled' }, @{ Conclusion = 'skipped' }, @{ Conclusion = 'neutral' }
    ) {
        $script:run.conclusion = $Conclusion
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run `
            -ExistingIssues @([pscustomobject]@{ number = 1 }) -Owners @() -IsModule $false `
            -PlatformTeam 'Azure/azure-verified-modules-engineering-owners'
        $routing.IssuesToClose | Should -HaveCount 0
        $routing.CreateIssueTitle | Should -BeNullOrEmpty
        $routing.CommentBody | Should -BeNullOrEmpty
    }

    It 'preserves the Bicep sweep handling of non-failure conclusions' {
        $script:run.conclusion = 'cancelled'
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run `
            -ExistingIssues @([pscustomobject]@{ number = 1 }) -Owners @() -IsModule $true
        $routing.IssuesToClose | Should -HaveCount 1
    }

    It 'alerts engineering owners for a maintenance <Conclusion> without requiring module labels' -ForEach @(
        @{ Conclusion = 'failure' }, @{ Conclusion = 'timed_out' }
        @{ Conclusion = 'startup_failure' }, @{ Conclusion = 'action_required' }
    ) {
        $script:run.name = 'Repos: Catalog Sync'
        $script:run.conclusion = $Conclusion
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @() -Owners @() `
            -IsModule $false -PlatformTeam 'Azure/azure-verified-modules-engineering-owners' -PlatformMembers @('member-one', 'member-two')
        $routing.CreateIssueTitle | Should -Be '[Failed pipeline] Repos: Catalog Sync'
        $routing.CreateIssueBody | Should -Match '@Azure/azure-verified-modules-engineering-owners'
        $routing.CreateIssueBody | Should -Match '@member-one'
        $routing.CreateIssueBody | Should -Match '@member-two'
        $routing.CreateIssueBody | Should -Match ([regex]::Escape($script:run.html_url))
        $routing.CreateIssueLabels | Should -HaveCount 0
        $routing.TaggingComment | Should -BeNullOrEmpty
        $routing.AssigneeToAdd | Should -BeNullOrEmpty
    }

    It 'closes every existing open issue when the run succeeded' {
        $script:run.conclusion = 'success'
        $existingIssue = [pscustomobject]@{ number = 1; title = '[Failed pipeline] avm.res.storage.storage-account'; url = 'https://github.com/Azure/bicep-registry-modules/issues/1'; createdAt = (Get-Date).ToUniversalTime().ToString('o') }
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @($existingIssue) -Owners @() -IsModule $true
        $routing.IssuesToClose | Should -HaveCount 1
        $routing.CloseComment | Should -Match 'Successful run'
    }

    It 'creates a new issue with the owner tagged and assigned when none exists yet' {
        $owners = @(@{ Handle = 'storage-owner'; Type = 'user' })
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @() -Owners $owners -IsModule $true
        $routing.CreateIssueTitle | Should -Be '[Failed pipeline] avm.res.storage.storage-account'
        $routing.CreateIssueLabels | Should -Contain 'Type: AVM :a: :v: :m:'
        $routing.AssigneeToAdd | Should -Be 'storage-owner'
        $routing.TaggingComment | Should -Match 'storage-owner'
    }

    It 'tags the tooling-contributors team and does not assign when the module is orphaned' {
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @() -Owners @() -IsModule $true
        $routing.AssigneeToAdd | Should -BeNullOrEmpty
        $routing.TaggingComment | Should -Match 'azure-verified-modules-tooling-contributors'
    }

    It 'tags the tooling-contributors team for a platform workflow' {
        $script:run.name = '.Module - Check and Publish'
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @() -Owners @() -IsModule $false
        $routing.TaggingComment | Should -Match 'azure-verified-modules-tooling-contributors'
        $routing.AssigneeToAdd | Should -BeNullOrEmpty
    }

    It 'comments on the newest existing issue for a repeated failure' {
        $existingIssue = [pscustomobject]@{ number = 1; title = '[Failed pipeline] avm.res.storage.storage-account'; url = 'https://github.com/Azure/bicep-registry-modules/issues/1'; createdAt = (Get-Date).ToUniversalTime().ToString('o') }
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @($existingIssue) -Owners @() -IsModule $true
        $routing.CommentIssueUrl | Should -Be $existingIssue.url
        $routing.CommentBody | Should -Match 'Failed run'
    }

    It 'does not repeat the same failed-run comment twice on the same day' {
        $existingIssue = [pscustomobject]@{ number = 1; title = '[Failed pipeline] avm.res.storage.storage-account'; url = 'https://github.com/Azure/bicep-registry-modules/issues/1'; createdAt = (Get-Date).ToUniversalTime().ToString('o') }
        $failedRunText = "Failed run: $($script:run.html_url)"
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @($existingIssue) -Owners @() -IsModule $true -ExistingCommentBodiesToday @($failedRunText)
        $routing.CommentIssueUrl | Should -BeNullOrEmpty
    }

    It 'closes older duplicate issues in favour of the newest and still comments on the newest' {
        $older = [pscustomobject]@{ number = 1; title = '[Failed pipeline] avm.res.storage.storage-account'; url = 'https://github.com/Azure/bicep-registry-modules/issues/1'; createdAt = (Get-Date).ToUniversalTime().AddDays(-2).ToString('o') }
        $newest = [pscustomobject]@{ number = 2; title = '[Failed pipeline] avm.res.storage.storage-account'; url = 'https://github.com/Azure/bicep-registry-modules/issues/2'; createdAt = (Get-Date).ToUniversalTime().ToString('o') }
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @($older, $newest) -Owners @() -IsModule $true
        $routing.DuplicateIssuesToClose | Should -HaveCount 1
        $routing.DuplicateIssuesToClose[0].url | Should -Be $older.url
        $routing.CommentIssueUrl | Should -Be $newest.url
    }

    It 'reports who a new issue notifies: <Case>' -ForEach @(
        @{ Case = 'module owners'; IsModule = $true; Owners = @(@{ Handle = 'storage-owner'; Type = 'user' }, @{ Handle = 'Azure/storage-team'; Type = 'team' }); Expected = @('storage-owner', 'Azure/storage-team') }
        @{ Case = 'orphaned module'; IsModule = $true; Owners = @(); Expected = @('Azure/azure-verified-modules-tooling-contributors') }
        @{ Case = 'platform workflow'; IsModule = $false; Owners = @(); Expected = @('Azure/azure-verified-modules-tooling-contributors') }
    ) {
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @() -Owners $Owners -IsModule $IsModule
        $routing.NotifiedHandles | Should -Be $Expected
    }
}

Describe 'Set-AvmWorkflowFailureIssueForRun' {
    BeforeEach {
        $script:run = [pscustomobject]@{ name = 'avm.res.storage.storage-account'; conclusion = 'failure'; html_url = 'https://github.com/Azure/bicep-registry-modules/actions/runs/1' }
        # Return value is discarded by every call site except the comments
        # fetch, which now projects `.body`; shaped as a comment object so
        # it works there too.
        Mock Invoke-RepositoryGitHub { @([pscustomobject]@{ body = 'https://github.com/Azure/bicep-registry-modules/issues/99' }) }
    }

    It 'adds a recovery comment with the successful run and auto-closes an existing maintenance incident' {
        $script:run.name = 'Repos: Terraform Sync'
        $script:run.conclusion = 'success'
        Mock Get-AvmWorkflowFailureIssueCommentsToday { @() }
        $issue = [pscustomobject]@{
            number = 42; title = '[Failed pipeline] Repos: Terraform Sync'
            url = 'https://github.com/Azure/azure-verified-modules-tools/issues/42'
            createdAt = '2026-01-01T00:00:00Z'; body = 'Three failed runs.'
        }
        $outcome = Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run `
            -Repository 'Azure/azure-verified-modules-tools' -ExistingIssues @($issue) -Owners @() `
            -IsModule $false -PlatformTeam 'Azure/azure-verified-modules-engineering-owners' -FailureThresholdMet:$false
        $outcome.Status | Should -Be 'Closed'
        Should -Invoke Invoke-RepositoryGitHub -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'issue' -and $Arguments[1] -eq 'close' -and
            $Arguments -contains '--comment' -and $Arguments[-1] -eq "Successful run: $($script:run.html_url)"
        }
    }

    It 'updates the open maintenance incident with team and member mentions instead of creating another issue' {
        $script:run.name = 'Repos: Terraform Sync'
        Mock Get-AvmWorkflowFailureIssueCommentsToday { @() }
        $issue = [pscustomobject]@{
            number = 42; title = '[Failed pipeline] Repos: Terraform Sync'
            url = 'https://github.com/Azure/azure-verified-modules-tools/issues/42'
            createdAt = '2026-01-01T00:00:00Z'; body = 'Earlier failed run.'
        }
        $outcome = Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run `
            -Repository 'Azure/azure-verified-modules-tools' -ExistingIssues @($issue) -Owners @() `
            -IsModule $false -PlatformTeam 'Azure/azure-verified-modules-engineering-owners' -PlatformMembers @('member-one', 'member-two')
        $outcome.Status | Should -Be 'Commented'
        $outcome.Notified | Should -Be @('Azure/azure-verified-modules-engineering-owners', 'member-one', 'member-two')
        Should -Invoke Get-AvmWorkflowFailureIssueCommentsToday -Times 1 -ParameterFilter { $All }
        Should -Invoke Invoke-RepositoryGitHub -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'issue' -and $Arguments[1] -eq 'comment' -and
            $Arguments[-1] -match '@Azure/azure-verified-modules-engineering-owners' -and
            $Arguments[-1] -match '@member-one' -and $Arguments[-1] -match '@member-two'
        }
    }

    It 'does not repeat a maintenance alert already present in the issue body or an older comment: <Location>' -ForEach @(
        @{ Location = 'body' }, @{ Location = 'comment' }
    ) {
        $script:run.name = 'Repos: Bicep Sync'
        $team = 'Azure/azure-verified-modules-engineering-owners'
        $routing = Resolve-AvmWorkflowFailureRouting -WorkflowRun $script:run -ExistingIssues @() -Owners @() -IsModule $false `
            -PlatformTeam $team -PlatformMembers @('former-member')
        $script:comments = if ($Location -eq 'comment') { @($routing.CreateIssueBody) } else { @() }
        Mock Get-AvmWorkflowFailureIssueCommentsToday { $script:comments }
        $issue = [pscustomobject]@{
            number = 42; title = '[Failed pipeline] Repos: Bicep Sync'
            url = 'https://github.com/Azure/azure-verified-modules-tools/issues/42'
            createdAt = '2026-01-01T00:00:00Z'
            body = if ($Location -eq 'body') { $routing.CreateIssueBody } else { 'Earlier failure.' }
        }
        $outcome = Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run `
            -Repository 'Azure/azure-verified-modules-tools' -ExistingIssues @($issue) -Owners @() -IsModule $false -PlatformTeam $team
        $outcome.Status | Should -Be 'AlreadyReported'
        Should -Invoke Invoke-RepositoryGitHub -Times 0 -Exactly
    }

    It 'updates a previously reported failure once to mention individual members' {
        $script:run.name = 'Repos: Terraform Sync'
        Mock Get-AvmWorkflowFailureIssueCommentsToday { @() }
        $issue = [pscustomobject]@{
            number = 42; title = '[Failed pipeline] Repos: Terraform Sync'
            url = 'https://github.com/Azure/azure-verified-modules-tools/issues/42'
            createdAt = '2026-01-01T00:00:00Z'; body = "Failed run: $($script:run.html_url)`n`n@Azure/engineering-owners"
        }
        $outcome = Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run `
            -Repository 'Azure/azure-verified-modules-tools' -ExistingIssues @($issue) -Owners @() `
            -IsModule $false -PlatformTeam 'Azure/engineering-owners' -PlatformMembers @('member-one')
        $outcome.Status | Should -Be 'Commented'
        Should -Invoke Invoke-RepositoryGitHub -Times 1 -Exactly -ParameterFilter {
            $Arguments[1] -eq 'comment' -and $Arguments[-1] -match '@member-one'
        }
    }

    It 'creates a maintenance incident with one issue write containing the team mention' {
        $script:run.name = 'Repos: Catalog Sync'
        Mock Invoke-RepositoryGitHub { 'https://github.com/Azure/azure-verified-modules-tools/issues/99' }
        $outcome = Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run `
            -Repository 'Azure/azure-verified-modules-tools' -ExistingIssues @() -Owners @() `
            -IsModule $false -PlatformTeam 'Azure/azure-verified-modules-engineering-owners'
        $outcome.Status | Should -Be 'Created'
        Should -Invoke Invoke-RepositoryGitHub -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'issue' -and $Arguments[1] -eq 'create' -and
            $Arguments -notcontains '--label' -and
            $Arguments[[array]::IndexOf($Arguments, '--body') + 1] -match '@Azure/azure-verified-modules-engineering-owners'
        }
    }

    It 'creates, assigns, and comments on a brand new failure issue' {
        $owners = @(@{ Handle = 'storage-owner'; Type = 'user' })
        Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run -Repository 'Azure/bicep-registry-modules' -ExistingIssues @() -Owners $owners -IsModule $true
        Should -Invoke Invoke-RepositoryGitHub -Times 3
    }

    It 'comments on an existing issue without creating a duplicate one' {
        Mock Get-AvmWorkflowFailureIssueCommentsToday { @() }
        $existingIssue = [pscustomobject]@{ number = 1; title = '[Failed pipeline] avm.res.storage.storage-account'; url = 'https://github.com/Azure/bicep-registry-modules/issues/1'; createdAt = (Get-Date).ToUniversalTime().ToString('o') }
        Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run -Repository 'Azure/bicep-registry-modules' -ExistingIssues @($existingIssue) -Owners @() -IsModule $true
        Should -Invoke Invoke-RepositoryGitHub -Times 1
    }

    It 'closes matching issues when the run succeeded' {
        $script:run.conclusion = 'success'
        $existingIssue = [pscustomobject]@{ number = 1; title = '[Failed pipeline] avm.res.storage.storage-account'; url = 'https://github.com/Azure/bicep-registry-modules/issues/1'; createdAt = (Get-Date).ToUniversalTime().ToString('o') }
        Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run -Repository 'Azure/bicep-registry-modules' -ExistingIssues @($existingIssue) -Owners @() -IsModule $true
        Should -Invoke Invoke-RepositoryGitHub -Times 1
    }

    It 'logs the new issue with who is assigned and notified, and returns the outcome' {
        Mock Invoke-RepositoryGitHub { 'https://github.com/Azure/bicep-registry-modules/issues/99' }
        $owners = @(@{ Handle = 'storage-owner'; Type = 'user' })
        $output = @(Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run -Repository 'Azure/bicep-registry-modules' -ExistingIssues @() -Owners $owners -IsModule $true 6>&1)
        $log = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) -join "`n"
        $outcome = $output | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] }

        $log | Should -Match ([regex]::Escape("Workflow [avm.res.storage.storage-account] failed in run [$($script:run.html_url)]. Creating issue [[Failed pipeline] avm.res.storage.storage-account], assigning storage-owner and notifying storage-owner."))
        $log | Should -Match ([regex]::Escape('Created issue [https://github.com/Azure/bicep-registry-modules/issues/99].'))
        $outcome.Status | Should -Be 'Created'
        $outcome.IssueUrl | Should -Be 'https://github.com/Azure/bicep-registry-modules/issues/99'
        $outcome.Assignee | Should -Be 'storage-owner'
        $outcome.Notified | Should -Be @('storage-owner')
    }

    It 'returns a <Expected> outcome for <Case>' -ForEach @(
        @{ Case = 'a repeat failure'; Conclusion = 'failure'; CommentsToday = @(); Expected = 'Commented' }
        @{ Case = 'a failure already reported today'; Conclusion = 'failure'; CommentsToday = @('Failed run: https://github.com/Azure/bicep-registry-modules/actions/runs/1'); Expected = 'AlreadyReported' }
        @{ Case = 'a fixed workflow'; Conclusion = 'success'; CommentsToday = @(); Expected = 'Closed' }
    ) {
        $script:run.conclusion = $Conclusion
        $script:commentsToday = $CommentsToday
        Mock Get-AvmWorkflowFailureIssueCommentsToday { $script:commentsToday }
        $existingIssue = [pscustomobject]@{ number = 1; title = '[Failed pipeline] avm.res.storage.storage-account'; url = 'https://github.com/Azure/bicep-registry-modules/issues/1'; createdAt = (Get-Date).ToUniversalTime().ToString('o') }
        $outcome = Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run -Repository 'Azure/bicep-registry-modules' -ExistingIssues @($existingIssue) -Owners @() -IsModule $true 6>$null
        $outcome.Status | Should -Be $Expected
        if ($Expected -eq 'Closed') {
            $outcome.ClosedIssueUrls | Should -Be @($existingIssue.url)
        }
        else {
            $outcome.IssueUrl | Should -Be $existingIssue.url
        }
    }

    It 'describes the planned issue without writing under WhatIf' {
        $outcome = Set-AvmWorkflowFailureIssueForRun -WorkflowRun $script:run -Repository 'Azure/bicep-registry-modules' -ExistingIssues @() -Owners @() -IsModule $true -WhatIf 6>$null
        $outcome.Status | Should -Be 'Created'
        $outcome.IssueUrl | Should -BeNullOrEmpty
        $outcome.Notified | Should -Be @('Azure/azure-verified-modules-tooling-contributors')
        Should -Invoke Invoke-RepositoryGitHub -Times 0 -Exactly
    }
}

Describe 'Invoke-AvmWorkflowFailureIssues summary' {
    BeforeEach {
        $script:previousSummary = $env:GITHUB_STEP_SUMMARY
        $script:summaryPath = Join-Path $TestDrive 'summary.md'
        Remove-Item -LiteralPath $script:summaryPath -ErrorAction SilentlyContinue
        $env:GITHUB_STEP_SUMMARY = $script:summaryPath
        $script:now = (Get-Date).ToUniversalTime().ToString('o')
        Mock Get-AvmWorkflowFailureWorkflows {
            @(
                [pscustomobject]@{ id = 1; name = 'avm.res.storage.storage-account' }
                [pscustomobject]@{ id = 2; name = 'avm.res.network.virtual-network' }
                [pscustomobject]@{ id = 3; name = 'avm.res.new.module' }
            )
        }
        Mock Get-AvmWorkflowFailureOpenIssues {
            @([pscustomobject]@{ number = 10; title = '[Failed pipeline] avm.res.network.virtual-network'; url = 'https://github.com/Azure/bicep-registry-modules/issues/10'; createdAt = $script:now })
        }
        Mock Get-AvmReviewerRoutingCatalogIndex {
            @{ 'avm/res/storage/storage-account' = @{ owners = @(@{ handle = 'storage-owner'; type = 'user'; displayName = $null }) } }
        }
        Mock Get-AvmBicepModuleMetadataOwners { @() }
        Mock Get-AvmWorkflowFailureIssueCommentsToday { @() }
        Mock Get-AvmWorkflowFailureLatestRun {
            switch ($WorkflowId) {
                1 { [pscustomobject]@{ name = 'avm.res.storage.storage-account'; conclusion = 'failure'; html_url = 'https://github.com/Azure/bicep-registry-modules/actions/runs/101' } }
                2 { [pscustomobject]@{ name = 'avm.res.network.virtual-network'; conclusion = 'success'; html_url = 'https://github.com/Azure/bicep-registry-modules/actions/runs/102' } }
                default { $null }
            }
        }
        Mock Invoke-RepositoryGitHub { 'https://github.com/Azure/bicep-registry-modules/issues/99' }
    }

    AfterEach {
        $env:GITHUB_STEP_SUMMARY = $script:previousSummary
    }

    It 'lists the issues created and closed, with who was assigned and notified' {
        $log = Invoke-AvmWorkflowFailureIssues -Repository 'Azure/bicep-registry-modules' 6>&1 | Out-String
        $log | Should -Match ([regex]::Escape('3 workflow(s) checked in [Azure/bicep-registry-modules]: 1 new issue(s), 0 repeat failure(s) commented, 0 already reported today, 1 fixed (issues closed), 1 without a completed run, 0 failed.'))
        $log | Should -Match ([regex]::Escape('avm.res.storage.storage-account: created https://github.com/Azure/bicep-registry-modules/issues/99, assigned storage-owner and notified storage-owner'))
        $log | Should -Match ([regex]::Escape('avm.res.network.virtual-network: closed after a successful run: https://github.com/Azure/bicep-registry-modules/issues/10'))

        $summary = Get-Content -Raw -LiteralPath $script:summaryPath
        $summary | Should -Match '(?m)^### Workflow failure issues\r?$'
        $summary | Should -Match ([regex]::Escape('| `avm.res.storage.storage-account` | [run](https://github.com/Azure/bicep-registry-modules/actions/runs/101) | [#99](https://github.com/Azure/bicep-registry-modules/issues/99) | Created, assigned `storage-owner` and notified `storage-owner` |'))
        $summary | Should -Match ([regex]::Escape('| `avm.res.network.virtual-network` | [run](https://github.com/Azure/bicep-registry-modules/actions/runs/102) | [#10](https://github.com/Azure/bicep-registry-modules/issues/10) | Closed after a successful run |'))
    }

    It 'describes a WhatIf run as a dry run' {
        $null = Invoke-AvmWorkflowFailureIssues -Repository 'Azure/bicep-registry-modules' -WhatIf 6>&1
        $summary = Get-Content -Raw -LiteralPath $script:summaryPath
        $summary | Should -Match 'Workflow failure issues \(dry run, nothing changed\)'
        $summary | Should -Match ([regex]::Escape('| new issue | Would create, assign `storage-owner` and notify `storage-owner` |'))
        Should -Invoke Invoke-RepositoryGitHub -Times 0 -Exactly
    }
}

Describe 'Invoke-AvmWorkflowFailureIssues diagnostics' {
    BeforeEach {
        Mock Get-AvmReviewerRoutingCatalogIndex { @{} }
        Mock Get-AvmWorkflowFailureTeamMembers { @('member-one', 'member-two') }
        $script:workflow1 = [pscustomobject]@{ id = 11; name = 'avm.res.storage.storage-account' }
    }

    It 'applies a three-failure threshold without fetching the module catalog: <Failures> failure(s)' -ForEach @(
        @{ Failures = 1; ExpectedWrites = 0 }
        @{ Failures = 2; ExpectedWrites = 0 }
        @{ Failures = 3; ExpectedWrites = 1 }
    ) {
        $script:failures = $Failures
        Mock Get-AvmWorkflowFailureWorkflows {
            @([pscustomobject]@{ id = 11; name = 'Repos: Catalog Sync' })
        }
        Mock Get-AvmWorkflowFailureOpenIssues { @() }
        Mock Get-AvmWorkflowFailureRunHistory {
            @(
                1..$script:failures | ForEach-Object {
                    [pscustomobject]@{ name = 'Repos: Catalog Sync'; conclusion = 'failure'; html_url = "https://github.com/Azure/azure-verified-modules-tools/actions/runs/$_" }
                }
                if ($script:failures -lt 3) {
                    [pscustomobject]@{ name = 'Repos: Catalog Sync'; conclusion = 'success'; html_url = 'https://github.com/Azure/azure-verified-modules-tools/actions/runs/0' }
                }
            )
        }
        Mock Invoke-RepositoryGitHub { 'https://github.com/Azure/azure-verified-modules-tools/issues/99' }
        Invoke-AvmWorkflowFailureIssues -Repository 'Azure/azure-verified-modules-tools' `
            -WorkflowName @('Repos: Catalog Sync') -PlatformTeam 'Azure/azure-verified-modules-engineering-owners' -FailureThreshold 3
        Should -Invoke Get-AvmReviewerRoutingCatalogIndex -Times 0 -Exactly
        Should -Invoke Get-AvmWorkflowFailureTeamMembers -Times 1 -Exactly
        Should -Invoke Invoke-RepositoryGitHub -Times $ExpectedWrites -Exactly
    }

    It 'emits a per-item progress marker for every workflow before it is processed' {
        Mock Get-AvmWorkflowFailureWorkflows { @($script:workflow1) }
        Mock Get-AvmWorkflowFailureOpenIssues { @() }
        Mock Get-AvmWorkflowFailureLatestRun { $null }
        $verboseOutput = Invoke-AvmWorkflowFailureIssues -Repository 'Azure/bicep-registry-modules' -Verbose 4>&1 | Out-String
        $verboseOutput | Should -Match ([regex]::Escape("[1/1] Checking workflow [$($script:workflow1.name)]"))
    }

    It 'writes full exception detail and rethrows when pre-loop setup fails' {
        Mock Get-AvmWorkflowFailureWorkflows { throw [System.InvalidOperationException]::new('workflow fetch boom') }
        $hostOutput = & {
            try { Invoke-AvmWorkflowFailureIssues -Repository 'Azure/bicep-registry-modules' *>&1 }
            catch { "THREW: $($_.Exception.Message)" }
        } | Out-String
        $hostOutput | Should -Match 'workflow fetch boom'
        $hostOutput | Should -Match 'InvalidOperationException'
        $hostOutput | Should -Match 'THREW: workflow fetch boom'
    }
}

Describe 'Invoke-AvmWorkflowFailureIssues entry point diagnostics' {
    BeforeAll {
        $script:entryPointPath = Join-Path $root 'repository-management' 'workflow-failure-issues' 'scripts' 'Invoke-AvmWorkflowFailureIssues.ps1'
        $script:entryPointText = Get-Content -Raw -Path $script:entryPointPath
    }

    It 'exists' {
        Test-Path $script:entryPointPath | Should -BeTrue
    }

    It 'wraps the sweep invocation in a try/catch that prints a FATAL banner and rethrows' {
        $script:entryPointText | Should -Match '(?ms)try\s*\{\s*Invoke-AvmWorkflowFailureIssues\b.*?\}\s*catch\s*\{.*?Write-Host\s+"FATAL:.*?Write-Host\s+\$_\.ScriptStackTrace.*?throw\s*\r?\n\}'
    }
}

Describe 'Workflow failure issue management workflow safety' {
    BeforeAll {
        $script:workflowPath = Join-Path $root '.github' 'workflows' 'repository-management-workflow-failure-issues.yml'
        $script:workflowText = Get-Content -Raw -Path $script:workflowPath
        $script:triggerBlock = [System.Text.RegularExpressions.Regex]::Match(
            $script:workflowText, '(?ms)^on:\r?\n(.*?)(?=^\S)').Groups[1].Value
        $script:runBlocks = [System.Text.RegularExpressions.Regex]::Matches(
            $script:workflowText, '(?ms)^        run:\s*\|\r?\n(?<body>.*?)(?=^      - |^  [\w-]+:|\z)')
    }

    It 'exists' {
        Test-Path $script:workflowPath | Should -BeTrue
    }

    It 'is triggered only by schedule and workflow_dispatch, never by issues, pull requests or workflow runs' {
        $triggerNames = @([System.Text.RegularExpressions.Regex]::Matches(
                $script:triggerBlock, '(?m)^  ([A-Za-z_]+):') |
            ForEach-Object { $_.Groups[1].Value })
        $triggerNames.Count | Should -Be 2
        $triggerNames | Should -Contain 'workflow_dispatch'
        $triggerNames | Should -Contain 'schedule'
        $script:triggerBlock | Should -Match '(?m)^\s{2}workflow_dispatch:'
        $script:triggerBlock | Should -Match '(?m)^\s{2}schedule:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}issues:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}workflow_run:'
    }

    It 'does not delegate Tools maintenance checks from the Bicep sweep' {
        $script:workflowText | Should -Not -Match 'critical_only|maintenance-alerts'
    }

    Describe 'Maintenance workflow failure alert safety' {
        BeforeAll {
            $script:alertWorkflow = Get-Content -Raw (Join-Path $root '.github' 'workflows' 'repository-management-maintenance-alerts.yml')
            $script:alertTriggers = [regex]::Match($script:alertWorkflow, '(?ms)^on:\n(.*?)(?=^\S)').Groups[1].Value
        }

        It 'monitors all eight maintenance workflows, including the old monitor but not itself' {
            $json = [regex]::Match($script:alertWorkflow, '(?ms)MONITORED_WORKFLOWS: >-\n(.*?)\n        run:').Groups[1].Value
            $names = @($json | ConvertFrom-Json)
            $names | Should -HaveCount 8
            $names | Should -Contain 'Repos: Workflow Failures'
            foreach ($name in $names) {
                $script:alertTriggers | Should -Match ([regex]::Escape("- '$name'"))
            }
            $script:alertTriggers | Should -Not -Match "- 'Repos: Maintenance Alerts'"
            $script:alertTriggers | Should -Match 'branches: \[main\]'
            $script:alertTriggers | Should -Match 'types: \[completed\]'
            $script:alertTriggers | Should -Match "cron: '47 5 \* \* \*'"
            $script:alertTriggers | Should -Match 'workflow_dispatch:'
            $script:alertTriggers | Should -Not -Match 'workflow_call:'
        }

        It 'uses trusted code and a scoped GitHub App token without artifact downloads' {
            $script:alertWorkflow | Should -Not -Match 'download-artifact'
            $script:alertWorkflow | Should -Match 'create-github-app-token'
            $script:alertWorkflow | Should -Match '(?m)^\s+repositories: azure-verified-modules-tools$'
            $script:alertWorkflow | Should -Match '(?m)^\s+permission-actions: read$'
            $script:alertWorkflow | Should -Match '(?m)^\s+permission-issues: write$'
            $script:alertWorkflow | Should -Match '(?m)^\s+permission-members: read$'
            $script:alertWorkflow | Should -Match 'GH_TOKEN: \$\{\{ steps.app-token.outputs.token \}\}'
            $script:alertWorkflow | Should -Match 'head_repository.full_name == github.repository'
            $script:alertWorkflow | Should -Match "workflow_run.event != 'pull_request'"
            $script:alertWorkflow | Should -Match "workflow_run.event != 'pull_request_target'"
            $script:alertWorkflow | Should -Match 'github.event.repository.default_branch'
            $script:alertWorkflow | Should -Not -Match 'workflow_run.head_sha|workflow_run.head_branch'
            $run = [regex]::Match($script:alertWorkflow, '(?ms)        run: \|\n(.*)$').Groups[1].Value
            $run | Should -Not -Match '\$\{\{'
            $run | Should -Match 'Import-Module .+ -Force -ErrorAction Stop'
        }

        It 'configures three consecutive failures, the engineering owners team and a write-free manual default' {
            $script:alertWorkflow | Should -Match "FAILURE_THRESHOLD: '3'"
            $script:alertWorkflow | Should -Match 'NOTIFY_TEAM: Azure/azure-verified-modules-engineering-owners'
            $script:alertWorkflow | Should -Match '-FailureThreshold \(\[int\]\$env:FAILURE_THRESHOLD\)'
            $script:alertWorkflow | Should -Match '-PlatformTeam \$env:NOTIFY_TEAM'
            $script:alertWorkflow | Should -Match '-WhatIf:\$whatIf'
            $script:alertTriggers | Should -Match '(?ms)workflow_dispatch:\n.*?what_if:\n.*?default: true'
        }
    }

    It 'runs the offset cron without schedule-dependent expressions' {
        $script:workflowText | Should -Match "- cron:\s*'41 5 \* \* \*'"
        $script:workflowText | Should -Not -Match 'github\.event\.schedule'
    }

    It 'maps the what-if input directly' {
        $script:triggerBlock | Should -Match '(?ms)^      what_if:\r?\n.*?^        default:\s*true\s*$'
        $script:workflowText | Should -Match '(?m)^\s{10}WHAT_IF:\s*\$\{\{\s*inputs\.what_if\s*\}\}\s*$'
        $script:workflowText | Should -Match "\`$whatIf\s*=\s*\`$env:WHAT_IF\s*-eq\s*'true'"
    }

    It 'never interpolates ${{ }} expressions directly into a run: body' {
        $script:runBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $script:runBlocks) {
            $match.Groups['body'].Value | Should -Not -Match '\$\{\{'
        }
    }

    It 'imports Avm.Authoring in the work run block before invoking the repository-management script' {
        $workRunBlocks = @($script:runBlocks | Where-Object {
                $_.Groups['body'].Value -match '(?m)^\s*\./repository-management/.+\.ps1\b'
            })
        $workRunBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $workRunBlocks) {
            $runBody = $match.Groups['body'].Value
            $import = [regex]::Match($runBody, '(?m)^\s*Import-Module .+ -Force -ErrorAction Stop')
            $importIndex = $import.Index
            $scriptIndex = [System.Text.RegularExpressions.Regex]::Match(
                $runBody, '(?m)^\s*\./repository-management/.+\.ps1\b').Index
            $import.Success | Should -BeTrue
            $importIndex | Should -BeLessThan $scriptIndex
        }
    }

    It 'uses GH_TOKEN directly and clears native exit status after the work script' {
        $workRunBlocks = @($script:runBlocks | Where-Object {
                $_.Groups['body'].Value -match '(?m)^\s*\./repository-management/.+\.ps1\b'
            })
        $workRunBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $workRunBlocks) {
            $runBody = $match.Groups['body'].Value
            $runBody | Should -Not -Match '(?m)^\s*gh auth login\b'
            $scriptIndex = [System.Text.RegularExpressions.Regex]::Match(
                $runBody, '(?m)^\s*\./repository-management/.+\.ps1\b').Index
            $resetIndex = $runBody.LastIndexOf('$global:LASTEXITCODE = 0')
            $resetIndex | Should -BeGreaterThan $scriptIndex
            $runBody | Should -Match '(?s)\$global:LASTEXITCODE\s*=\s*0\s*\z'
        }
    }
}
