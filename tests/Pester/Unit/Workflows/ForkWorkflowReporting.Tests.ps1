#Requires -Version 7.4

BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:module = Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru
    $script:path = Join-Path $script:root 'scripts' 'workflow-reporting' 'Invoke-AvmWorkflowReport.ps1'
    function Invoke-TestForkReport {
        & $script:module {
            param($Path, $Event)
            . $Path
            Invoke-AvmForkWorkflowReport -Event $Event -Repository 'Azure/bicep-registry-modules' -ServerUrl 'https://github.com'
        } $script:path $script:event
    }
}

Describe 'Trusted fork workflow reporting' {
    BeforeEach {
        $script:calls = [Collections.Generic.List[object]]::new()
        $script:event = @{
            repository = @{ default_branch = 'main' }
            workflow_run = @{
                id = 123; event = 'pull_request'; conclusion = 'failure'; head_sha = 'abc'
                head_branch = 'feature'; head_repository = @{ full_name = 'fork/repo' }
            }
        }
        $script:annotations = @(@{ annotation_level = 'failure'; message = 'Required E2E tests must run and pass before merging. Details.' })
        $script:current = @{
            number = 42; state = 'open'; base = @{ ref = 'main' }
            head = @{ sha = 'abc'; repo = @{ full_name = 'fork/repo' } }
        }
        $script:pull = @{ number = 42; head = @{ sha = 'abc'; repo = @{ full_name = 'fork/repo' } } }
        $script:comments = @()
        Mock -ModuleName Avm.Authoring Invoke-AvmGitHubApi {
            param($Endpoint, $Method = 'GET', $Body)
            $script:calls.Add(@{ Endpoint = $Endpoint; Method = $Method; Body = $Body })
            if ($Method -cne 'GET') { return @{} }
            switch -Wildcard ($Endpoint) {
                '*/actions/runs/*/jobs?*' { return @{ jobs = @(@{ id = 12; name = 'Report check status'; conclusion = 'failure' }) } }
                '*/check-runs/*/annotations?*' { return $script:annotations }
                '*/pulls/*' { return $script:current }
                '*/pulls?*' { return $script:pull }
                '*/issues/*/comments?*' { return $script:comments }
                default { throw "Unexpected endpoint: $Endpoint" }
            }
        }
    }

    It 'only enables fork reporting for a trusted workflow_run event' {
        Import-Module powershell-yaml -ErrorAction Stop
        $action = Get-Content -Raw (Join-Path $script:root '.github' 'actions' 'report-check-status' 'action.yml') | ConvertFrom-Yaml
        $action.inputs.'fork-run'.default | Should -BeExactly 'false'
        $action.runs.steps[0].run | Should -Match "GITHUB_EVENT_NAME -cne 'workflow_run'"
        $action.runs.steps[0].run | Should -Match 'Invoke-AvmForkWorkflowReport'
    }

    It 'posts a handoff comment for the matching failed fork run' {
        Invoke-TestForkReport
        $write = @($script:calls | Where-Object Method -EQ POST)
        $write | Should -HaveCount 1 -Because ($script:calls | ConvertTo-Json -Depth 10 -Compress)
        $write[0].Endpoint | Should -BeExactly 'repos/Azure/bicep-registry-modules/issues/42/comments'
        $write[0].Body.body | Should -Match 'cannot run with credentials from a fork'
        $write[0].Body.body | Should -Match 'release-branch handoff process'
    }

    It 'does not post for unrelated failures or a stale pull request' -ForEach @(
        @{ Case = 'unrelated' }, @{ Case = 'stale' }, @{ Case = 'retargeted' }, @{ Case = 'same-repo' }
    ) {
        if ($Case -ceq 'unrelated') { $script:annotations[0].message = 'Another check failed.' }
        if ($Case -ceq 'stale') { $script:current.head.sha = 'new' }
        if ($Case -ceq 'retargeted') { $script:current.base.ref = 'release/fork' }
        if ($Case -ceq 'same-repo') { $script:event.workflow_run.head_repository.full_name = 'Azure/bicep-registry-modules' }
        Invoke-TestForkReport
        @($script:calls | Where-Object Method -NE GET) | Should -HaveCount 0
    }

    It 'updates the existing bot-owned E2E comment' {
        $script:comments = @(
            @{ id = 3; user = @{ login = 'contributor' }; body = '<!-- avm-bicep-required-e2e-label-feedback -->' }
            @{ id = 4; user = @{ login = 'github-actions[bot]' }; body = '<!-- avm-bicep-required-e2e-label-feedback --> old' }
        )
        Invoke-TestForkReport
        $write = @($script:calls | Where-Object Method -EQ PATCH)
        $write | Should -HaveCount 1 -Because ($script:calls | ConvertTo-Json -Depth 10 -Compress)
        $write[0].Endpoint | Should -Match '/comments/4$'
    }
}
