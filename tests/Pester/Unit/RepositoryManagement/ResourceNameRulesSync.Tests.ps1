BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $workflowPath = Join-Path $root '.github' 'workflows' 'repository-management-resource-name-rules-sync.yml'
    $workflowText = Get-Content -Raw -Path $workflowPath
    $triggerBlock = [System.Text.RegularExpressions.Regex]::Match(
        $workflowText, '(?ms)^on:\r?\n(.*?)(?=^\S)').Groups[1].Value
    $runBlocks = [System.Text.RegularExpressions.Regex]::Matches(
        $workflowText, '(?ms)^        run:\s*\|\r?\n(?<body>.*?)(?=^      - |\z)')
}

Describe 'Resource name rules sync workflow safety' {
    It 'exists' {
        Test-Path $workflowPath | Should -BeTrue
    }

    It 'is triggered only by its weekly schedule and manual dispatch' {
        $triggerNames = @([System.Text.RegularExpressions.Regex]::Matches(
                $triggerBlock, '(?m)^  ([A-Za-z_]+):') |
            ForEach-Object { $_.Groups[1].Value })
        $triggerNames | Should -HaveCount 2
        $triggerNames | Should -Contain 'schedule'
        $triggerNames | Should -Contain 'workflow_dispatch'
        $triggerBlock | Should -Match "(?m)^    - cron: '23 6 \* \* 1'$"
        $triggerBlock | Should -Not -Match '(?m)^\s{2}issues:'
        $triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request:'
        $triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
        $triggerBlock | Should -Not -Match '(?m)^\s{2}workflow_run:'
    }

    It 'runs only from the trusted tools main workflow and serializes publishers' {
        $guard = [regex]::Match($workflowText,
            '(?ms)^  publish:\r?\n    name: [^\r\n]+\r?\n    if: >-\r?\n(?<body>.*?)(?=^    runs-on:)')
        $guard.Success | Should -BeTrue
        ($guard.Groups['body'].Value.Trim() -replace '\s+', ' ') | Should -BeExactly (
            "github.repository == 'Azure/azure-verified-modules-tools' && " +
            '!github.event.repository.fork && ' +
            "github.ref == 'refs/heads/main' && " +
            "github.workflow_ref == 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-resource-name-rules-sync.yml@refs/heads/main'")
        $workflowText | Should -Match '(?m)^permissions:\r?\n  contents: read$'
        $workflowText | Should -Match '(?m)^concurrency:\r?\n  group: repository-management-resource-name-rules-sync\r?\n  cancel-in-progress: false$'
        $workflowText | Should -Match '(?m)^    environment: avm$'
    }

    It 'uses a narrowly scoped app token and the naming repository default branch' {
        $workflowText | Should -Match '(?ms)repositories: terraform-azure-avm-utl-naming\s+permission-contents: write\s+permission-pull-requests: write'
        $workflowText | Should -Match "gh api repos/Azure/terraform-azure-avm-utl-naming --jq '.default_branch'"
        $workflowText | Should -Match 'git check-ref-format --branch \$branch'
        $workflowText | Should -Match '(?ms)repository: Azure/terraform-azure-avm-utl-naming\s+ref: \$\{\{ steps\.target\.outputs\.default-branch \}\}\s+token: \$\{\{ steps\.app-token\.outputs\.token \}\}'
        $workflowText | Should -Match '(?m)^\s{10}NAMING_RULES_BASE_BRANCH:\s*\$\{\{\s*steps\.target\.outputs\.default-branch\s*\}\}\s*$'
        $workflowText | Should -Not -Match 'secrets: inherit'
    }

    It 'runs the naming repository tests before publication and never interpolates expressions into run bodies' {
        $workflowText | Should -Match '(?ms)name: Test parser and mocked publication\s+working-directory: naming\s+run: \.\\scripts\\tests\\Test-ResourceNameRules\.ps1'
        $workflowText | Should -Match '(?ms)name: Regenerate runtime catalogs and propose changes\s+working-directory: naming\s+env:.*?run: \.\\scripts\\Publish-ResourceNameRules\.ps1'
        $runBlocks | Should -HaveCount 1
        $runBlocks[0].Groups['body'].Value | Should -Not -Match '\$\{\{'
    }
}
