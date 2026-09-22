BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $reviewerRoutingLib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    $lib = Join-Path $root 'repository-management' 'workflow-failure-issues' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $reviewerRoutingLib 'RepositoryFileAccess.ps1')
    . (Join-Path $reviewerRoutingLib 'ModuleOwners.ps1')
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

Describe 'Resolve-AvmWorkflowFailureRouting' {
    BeforeEach {
        $script:run = [pscustomobject]@{ name = 'avm.res.storage.storage-account'; conclusion = 'failure'; html_url = 'https://github.com/Azure/bicep-registry-modules/actions/runs/1' }
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
}

Describe 'Set-AvmWorkflowFailureIssueForRun' {
    BeforeEach {
        $script:run = [pscustomobject]@{ name = 'avm.res.storage.storage-account'; conclusion = 'failure'; html_url = 'https://github.com/Azure/bicep-registry-modules/actions/runs/1' }
        Mock Invoke-RepositoryGitHub { @('https://github.com/Azure/bicep-registry-modules/issues/99') }
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
}

Describe 'Workflow failure issue management workflow safety' {
    BeforeAll {
        $script:workflowPath = Join-Path $root '.github' 'workflows' 'repository-management-workflow-failure-issues.yml'
        $script:workflowText = Get-Content -Raw -Path $script:workflowPath
        $script:triggerBlock = [System.Text.RegularExpressions.Regex]::Match(
            $script:workflowText, '(?ms)^on:\r?\n(.*?)(?=^\S)').Groups[1].Value
    }

    It 'exists' {
        Test-Path $script:workflowPath | Should -BeTrue
    }

    It 'is triggered only by schedule and workflow_dispatch' {
        $script:triggerBlock | Should -Match '(?m)^\s{2}workflow_dispatch:'
        $script:triggerBlock | Should -Match '(?m)^\s{2}schedule:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}issues:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
        $script:triggerBlock | Should -Not -Match '(?m)^\s{2}workflow_run:'
    }

    It 'never interpolates ${{ }} expressions directly into a run: body' {
        $runBlocks = [System.Text.RegularExpressions.Regex]::Matches($script:workflowText, '(?m)^( +)run:\s*\|\r?\n((?:\1 .*\r?\n?)*)')
        $runBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $runBlocks) {
            $match.Groups[2].Value | Should -Not -Match '\$\{\{'
        }
    }
}
