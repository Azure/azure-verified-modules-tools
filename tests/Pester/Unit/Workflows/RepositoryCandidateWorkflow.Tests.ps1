BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:workflow = Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'repository-management-sync.yml') -Raw
    $script:prepare = [regex]::Match($script:workflow,
        '(?ms)^  run-sync:\r?\n(?<body>.*?)(?=^  [a-z][a-z-]*:\r?\n|\z)').Groups['body'].Value
    $script:validate = [regex]::Match($script:workflow,
        '(?ms)^  validate-candidate:\r?\n(?<body>.*?)(?=^  [a-z][a-z-]*:\r?\n|\z)').Groups['body'].Value
    $script:publish = [regex]::Match($script:workflow,
        '(?ms)^  publish-candidate:\r?\n(?<body>.*?)(?=^  [a-z][a-z-]*:\r?\n|\z)').Groups['body'].Value
}

Describe 'Repository sync candidate workflow' {
    It 'defaults manual plan-only runs to the checked-out authoring source' {
        $script:workflow | Should -Match '(?ms)^      use_workflow_authoring_source:\r?\n.*?^        default:\s*true\s*$'
        $script:prepare | Should -Match '\$planOnly -and \$triggerType -eq ''workflow_dispatch'''
        $script:prepare | Should -Match '-authoringModulePath \$authoringModulePath'
        $script:prepare | Should -Match '-candidateOutputDirectory \$candidateDirectory'
    }

    It 'keeps candidate checks in a separate non-production OIDC environment without governance credentials' {
        $script:validate | Should -Match 'environment:\s*avm-validation'
        $script:validate | Should -Match 'needs:\s*\[generate-matrix, run-sync\]'
        $script:validate | Should -Match 'id-token:\s*write'
        $script:validate | Should -Match 'Invoke-RepositoryCandidate\.ps1 -Mode Validate'
        $script:validate | Should -Not -Match 'GH_TOKEN:|ARM_CLIENT_ID:|ARM_BACKEND_|azure/login@|create-github-app-token@'
        $script:validate | Should -Match 'name:\s*validated-\$\{\{ matrix\.repoName \}\}'
    }

    It 'publishes only after receipt download, and never on manual plan-only runs' {
        $script:publish | Should -Match 'needs:\s*\[generate-matrix, validate-candidate\]'
        $script:publish | Should -Match 'github\.event_name != ''workflow_dispatch'' \|\| !inputs\.plan_only'
        $script:publish | Should -Match 'name:\s*validated-\$\{\{ matrix\.repoName \}\}'
        $script:publish | Should -Match 'Invoke-RepositoryCandidate\.ps1 -Mode Publish'
        $script:publish | Should -Not -Match 'ARM_CLIENT_ID:|azure/login@'
        $script:prepare | Should -Match 'name:\s*candidate-\$\{\{ matrix\.repoName \}\}'
    }
}
