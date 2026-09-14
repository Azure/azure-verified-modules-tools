BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:syncRoot = Join-Path $script:root 'repository-management' 'bicep-codeowners-sync'
    $script:workflowPath = Join-Path $script:root '.github' 'workflows' 'repository-management-bicep-sync.yml'
    $script:workflow = Get-Content -LiteralPath $script:workflowPath -Raw
    $script:existing = Get-Content -LiteralPath (Join-Path $script:root '.github' 'workflows' 'repository-management-sync.yml') -Raw
}

Describe 'Bicep CODEOWNERS workflow contract' {
    It 'uses the generic Bicep workflow name without retaining a second workflow' {
        $script:workflow | Should -Match '(?m)^name: Repository Management - Bicep Sync$'
        $script:workflow | Should -Match '(?m)^  group: bicep-sync$'
        Test-Path -LiteralPath (Join-Path $script:root '.github' 'workflows' 'repository-management-codeowners-sync.yml') |
            Should -BeFalse
        $script:existing | Should -Match '(?m)^name: Repository Management - Terraform Sync$'
    }

    It 'runs daily every four hours two hours after the existing repository-sync slots' {
        $script:existing | Should -Match "cron: '33 \*/4 \* \* 1-5'"
        $script:workflow | Should -Match "cron: '33 2-23/4 \* \* \*'"
    }

    It 'offers reviewable plan-only dispatch by default with no target or credential overrides' {
        $script:workflow | Should -Match '(?s)workflow_dispatch:\s+inputs:\s+plan_only:.*?default: true\s+type: boolean'
        $script:workflow | Should -Match 'Create or update the CODEOWNERS pull request for review, but never merge it'
        $script:workflow | Should -Match "PLAN_ONLY:.*github.event_name == 'workflow_dispatch' && inputs.plan_only"
        $script:workflow | Should -Not -Match 'pull_request:|pull_request_target:|repository_dispatch:'
    }

    It 'restricts credentials to trusted tools main and requires explicit scheduled enablement' {
        $script:workflow | Should -Match "github.repository == 'Azure/azure-verified-modules-tools'"
        $script:workflow | Should -Match "github.ref == 'refs/heads/main'"
        $script:workflow | Should -Match "vars.AVM_CODEOWNERS_SYNC_ENABLED == 'true'"
        $script:workflow | Should -Match 'environment: avm'
        $script:workflow | Should -Match '(?m)^\s+ref: main$'
        $script:workflow | Should -Match 'persist-credentials: false'
        $script:workflow | Should -Match 'cancel-in-progress: false'
    }

    It 'reuses the existing pinned App action and scopes its write token to the target only' {
        $script:workflow | Should -Match 'client-id: \$\{\{ vars.AVM_APP_CLIENT_ID \}\}'
        $script:workflow | Should -Match 'private-key: \$\{\{ secrets.AVM_APP_PRIVATE_KEY \}\}'
        $script:workflow | Should -Match '(?m)^\s+owner: Azure$'
        $script:workflow | Should -Match '(?m)^\s+repositories: bicep-registry-modules$'
        $script:workflow | Should -Match 'permission-contents: write'
        $script:workflow | Should -Match 'permission-pull-requests: write'
        $script:workflow | Should -Not -Match 'permission-administration|id-token: write|secrets\.[A-Z_]*PAT'
        $script:workflow | Should -Match '(?m)^permissions:\s+contents: read'
        foreach ($action in @('actions/checkout', 'actions/create-github-app-token')) {
            $pattern = [regex]::Escape($action) + '@([0-9a-f]{40})'
            $expected = [regex]::Match($script:existing, $pattern)
            $actual = [regex]::Match($script:workflow, $pattern)
            $actual.Success | Should -BeTrue
            $actual.Groups[1].Value | Should -BeExactly $expected.Groups[1].Value
        }
    }

    It 'never interpolates workflow inputs directly into executable PowerShell' {
        $run = [regex]::Match($script:workflow, '(?s)        run: \|\r?\n(.*)$').Groups[1].Value
        $run | Should -Not -Match '\$\{\{'
        $run | Should -Match "-PlanOnly:\(\`$env:PLAN_ONLY -eq 'true'\)"
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($run, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -HaveCount 0
    }

    It 'keeps the local export entry point independent of remote synchronization' {
        $export = Get-Content -LiteralPath (Join-Path $script:syncRoot 'scripts' 'Export-BicepCodeowners.ps1') -Raw
        $export | Should -Match 'Get-AvmBicepCodeownersSnapshot'
        $export | Should -Not -Match 'Invoke-AvmBicepCodeownersSync|Merge-AvmCodeownersPullRequest'
    }

    It 'parses all sync scripts and never checks out or executes target repository code' {
        foreach ($file in Get-ChildItem -LiteralPath $script:syncRoot -Filter '*.ps1' -Recurse -File) {
            $tokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            $parseErrors | Should -HaveCount 0
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $text | Should -Not -Match 'Invoke-Expression|\biex\b|git checkout|git clone|pr checkout|auth login|auth setup-git|--auto|--delete-branch'
        }
    }

    It 'keeps the source template and workflow in UTF-8 without BOM and LF format' {
        foreach ($path in @($script:workflowPath, (Join-Path $script:syncRoot 'CODEOWNERS.template'))) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            ($bytes[0..2] -join ',') | Should -Not -Be '239,187,191'
            $bytes | Should -Not -Contain ([byte]13)
        }
    }
}
