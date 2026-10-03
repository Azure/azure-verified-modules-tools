BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:dispatcher = Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'repository-management-sync.yml') -Raw
    $script:workflow = Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'repository-management-sync-repository.yml') -Raw
    $script:caller = [regex]::Match($script:dispatcher,
        '(?ms)^  sync-repository:\r?\n(?<body>.*)\z').Groups['body'].Value
    $script:prepare = [regex]::Match($script:workflow,
        '(?ms)^  run-sync:\r?\n(?<body>.*?)(?=^  [a-z][a-z-]*:\r?\n|\z)').Groups['body'].Value
    $script:validate = [regex]::Match($script:workflow,
        '(?ms)^  validate-candidate:\r?\n(?<body>.*?)(?=^  [a-z][a-z-]*:\r?\n|\z)').Groups['body'].Value
    $script:publish = [regex]::Match($script:workflow,
        '(?ms)^  publish-candidate:\r?\n(?<body>.*?)(?=^  [a-z][a-z-]*:\r?\n|\z)').Groups['body'].Value
}

Describe 'Repository sync candidate workflow' {
    It 'runs an independent reusable job chain for every repository in the matrix' {
        $script:dispatcher | Should -Match '(?m)^  generate-matrix:\s*$'
        $script:caller | Should -Match 'fail-fast:\s*false'
        $script:caller | Should -Match 'include:\s*\$\{\{ fromJson\(needs\.generate-matrix\.outputs\.matrix\) \}\}'
        $script:caller | Should -Match 'uses:\s*\./\.github/workflows/repository-management-sync-repository\.yml'
        $script:caller | Should -Match 'secrets:\s*inherit'
        foreach ($binding in @(
                'repo_id: ${{ matrix.repoId }}',
                'repo_name: ${{ matrix.repoName }}',
                'repo_url: ${{ matrix.repoUrl }}',
                'repo_metadata_json: ${{ toJson(matrix.repoMetaData) }}'
            )) {
            $script:caller | Should -Match ([regex]::Escape($binding))
        }
        $script:workflow | Should -Match '(?m)^  workflow_call:\s*$'
        $script:workflow | Should -Not -Match 'matrix\.|needs\.generate-matrix'
    }

    It 'defaults manual plan-only runs to the checked-out authoring source' {
        $script:dispatcher | Should -Match '(?ms)^      use_workflow_authoring_source:\r?\n.*?^        default:\s*true\s*$'
        $script:caller | Should -Match ([regex]::Escape(
                'use_workflow_authoring_source: ${{ github.event_name == ''workflow_dispatch'' && inputs.plan_only && inputs.use_workflow_authoring_source }}'))
        $script:caller | Should -Match ([regex]::Escape(
                'plan_only: ${{ github.event_name == ''workflow_dispatch'' && inputs.plan_only }}'))
        $script:prepare | Should -Match '\$planOnly -and \$triggerType -eq ''workflow_dispatch'''
        $script:prepare | Should -Match '-authoringModulePath \$authoringModulePath'
        $script:prepare | Should -Match '-candidateOutputDirectory \$candidateDirectory'
        $script:prepare | Should -Match 'REPO_META_DATA_JSON: \$\{\{ inputs\.repo_metadata_json \}\}'
        $script:prepare | Should -Match '-repoId "\$\{\{ inputs\.repo_id \}\}"'
        $script:caller | Should -Match ([regex]::Escape(
                'force_file_update: ${{ github.event_name == ''workflow_dispatch'' && inputs.force_file_update }}'))
        $script:caller | Should -Match ([regex]::Escape(
                'sync_project_items: ${{ github.event_name != ''workflow_dispatch'' || inputs.sync_project_items }}'))
    }

    It 'skips only this repository when its preparation fails and isolates its validation identity' {
        $script:validate | Should -Match 'environment:\s*avm-validation'
        $script:validate | Should -Match 'needs:\s*run-sync'
        $script:validate | Should -Match ([regex]::Escape("if: `${{ needs.run-sync.result == 'success' }}"))
        $script:validate | Should -Not -Match 'always\(\)'
        $script:validate | Should -Match 'id-token:\s*write'
        $script:validate | Should -Match 'Invoke-RepositoryCandidate\.ps1 -Mode Validate'
        $script:validate | Should -Not -Match 'GH_TOKEN:|ARM_CLIENT_ID:|ARM_BACKEND_|azure/login@|create-github-app-token@'
        $script:validate | Should -Match 'name:\s*validated-\$\{\{ inputs\.repo_name \}\}'
    }

    It 'publishes only after this repository validation passes and never for plan-only' {
        $script:publish | Should -Match 'needs:\s*validate-candidate'
        $script:publish | Should -Match ([regex]::Escape("if: `${{ needs.validate-candidate.result == 'success' && !inputs.plan_only }}"))
        $script:publish | Should -Not -Match 'always\(\)'
        $script:publish | Should -Match 'name:\s*validated-\$\{\{ inputs\.repo_name \}\}'
        $script:publish | Should -Match 'Invoke-RepositoryCandidate\.ps1 -Mode Publish'
        $script:publish | Should -Not -Match 'ARM_CLIENT_ID:|azure/login@'
        $script:prepare | Should -Match 'name:\s*candidate-\$\{\{ inputs\.repo_name \}\}'
    }
}
