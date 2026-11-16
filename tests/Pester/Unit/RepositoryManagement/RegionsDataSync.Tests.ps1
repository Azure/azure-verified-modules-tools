BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $workflowPath = Join-Path $root '.github' 'workflows' 'repository-management-regions-data-sync.yml'
    $workflowText = Get-Content -Raw -Path $workflowPath
    $triggerBlock = [System.Text.RegularExpressions.Regex]::Match(
        $workflowText, '(?ms)^on:\r?\n(.*?)(?=^\S)').Groups[1].Value
    $runBlocks = [System.Text.RegularExpressions.Regex]::Matches(
        $workflowText, '(?ms)^        run:\s*\|\r?\n(?<body>.*?)(?=^      - |\z)')
}

Describe 'Regions data sync workflow safety' {
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
        $triggerBlock | Should -Match "(?m)^    - cron: '15 4 \* \* 0'$"
        $triggerBlock | Should -Not -Match '(?m)^\s{2}issues:'
        $triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request:'
        $triggerBlock | Should -Not -Match '(?m)^\s{2}pull_request_target:'
        $triggerBlock | Should -Not -Match '(?m)^\s{2}workflow_run:'
    }

    It 'is disabled until the trusted tools main workflow is explicitly enabled' {
        $guard = [regex]::Match($workflowText,
            '(?ms)^  collect:\r?\n    name: [^\r\n]+\r?\n    if: >-\r?\n(?<body>.*?)(?=^    runs-on:)')
        $guard.Success | Should -BeTrue
        ($guard.Groups['body'].Value.Trim() -replace '\s+', ' ') | Should -BeExactly (
            "github.repository == 'Azure/azure-verified-modules-tools' && " +
            '!github.event.repository.fork && ' +
            "github.ref == 'refs/heads/main' && " +
            "github.workflow_ref == 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-regions-data-sync.yml@refs/heads/main' && " +
            "vars.REGIONS_DATA_SYNC_ENABLED == 'true'")
        $workflowText | Should -Match '(?m)^concurrency:\r?\n  group: repository-management-regions-data-sync\r?\n  cancel-in-progress: false$'
        $workflowText | Should -Match '(?m)^  id-token: write$'
        $workflowText | Should -Match '(?m)^    environment: regions-update-data$'
        $workflowText | Should -Match '(?m)^    environment: avm$'
    }

    It 'uses the dedicated collection identity and narrowly scoped publication token' {
        $workflowText | Should -Match '(?ms)client-id: \$\{\{ vars\.AZURE_CLIENT_ID \}\}\s+tenant-id: \$\{\{ vars\.AZURE_TENANT_ID \}\}\s+subscription-id: \$\{\{ vars\.AZURE_SUBSCRIPTION_ID \}\}'
        $workflowText | Should -Match '(?ms)repositories: terraform-azurerm-avm-utl-regions\s+permission-contents: write\s+permission-pull-requests: write'
        $workflowText | Should -Match '(?m)^\s{10}AVM_APP_SLUG:\s*\$\{\{\s*steps\.app-token\.outputs\.app-slug\s*\}\}\s*$'
        $workflowText | Should -Match "gh api repos/Azure/terraform-azurerm-avm-utl-regions --jq '.default_branch'"
        $workflowText | Should -Match 'git check-ref-format --branch \$branch'
        $workflowText | Should -Not -Match 'secrets: inherit'
    }

    It 'limits artifacts and publishing changes to the locations cache' {
        $workflowText | Should -Match '(?ms)name: regions-locations-data\s+path: regions/modules/cached-data/locations\.tf\.json'
        $workflowText | Should -Match "changedPaths\[0\] -cne 'modules/cached-data/locations.tf.json'"
        $workflowText | Should -Match "git add -- 'modules/cached-data/locations.tf.json'"
        $workflowText | Should -Match "headRefName -match '\^update\[0-9\]\+\$'"
    }

    It 'does not interpolate expressions into PowerShell run bodies' {
        $runBlocks.Count | Should -BeGreaterThan 0
        foreach ($match in $runBlocks) {
            $match.Groups['body'].Value | Should -Not -Match '\$\{\{'
        }
    }
}
