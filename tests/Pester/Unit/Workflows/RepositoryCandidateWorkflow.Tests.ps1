BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:dispatcher = Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'repository-management-sync.yml') -Raw
    $script:workflow = Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'repository-management-sync-repository.yml') -Raw
    $script:configChecks = Get-Content -LiteralPath (Join-Path $root '.github' 'workflows' 'repository-management-config-test.yml') -Raw
    $script:caller = [regex]::Match($script:dispatcher,
        '(?ms)^  sync-repository:\r?\n(?<body>.*)\z').Groups['body'].Value
    $script:worker = [regex]::Match($script:workflow,
        '(?ms)^  run-sync:\r?\n(?<body>.*?)(?=^  [a-z][a-z-]*:\r?\n|\z)').Groups['body'].Value
    $script:prepare = [regex]::Match($script:worker,
        '(?ms)\A.*?(?=^      - name: Configure validation tool cache\r?$)').Value
    $script:validate = [regex]::Match($script:worker,
        '(?ms)^      - name: Configure validation tool cache\r?\n.*?(?=^      - name: Inspect candidate\r?$)').Value
    $script:publish = [regex]::Match($script:worker,
        '(?ms)^      - name: Inspect candidate\r?\n.*\z').Value
}

Describe 'Repository sync candidate workflow' {
    It 'keeps configuration checks wired to the moved workflow and candidate entry points' {
        foreach ($pattern in @(
                '.github/workflows/repository-management-*.yml',
                'repository-management/**'
            )) {
            $script:configChecks | Should -Match ('(?m)^      - ''' + [regex]::Escape($pattern) + '''\r?$') -Because $pattern
        }
    }

    It 'runs one reusable worker job for every repository in the matrix' {
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
        $jobs = [regex]::Match($script:workflow, '(?ms)^jobs:\r?\n(?<body>.*)\z').Groups['body'].Value
        @([regex]::Matches($jobs, '(?m)^  ([a-z][a-z-]*):\r?$') |
            ForEach-Object { $_.Groups[1].Value }) | Should -Be @('run-sync')
        $script:worker | Should -Match ([regex]::Escape('name: Sync ${{ inputs.repo_name }}'))
        $script:worker | Should -Match '(?m)^    environment: avm\r?$'
        $script:worker | Should -Match ([regex]::Escape('group: repository-sync-state-${{ inputs.repo_id }}'))
        $script:worker | Should -Match '(?m)^      cancel-in-progress: false\r?$'
        $ids = @([regex]::Matches($script:worker, '(?m)^        id: (.+)\r?$') |
                ForEach-Object { $_.Groups[1].Value.Trim() })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'keeps the phases ordered on one checkout without artifact downloads' {
        foreach ($phase in @($script:prepare, $script:validate, $script:publish)) {
            $phase | Should -Not -BeNullOrEmpty
        }
        ([regex]::Matches($script:worker, 'uses: actions/checkout@')).Count | Should -Be 1
        $script:worker | Should -Not -Match 'uses: actions/download-artifact@|(?m)^    needs:'
        $script:prepare | Should -Match '(?m)^      - name: Prepare repository candidate\r?$'
        $script:prepare | Should -Match '(?m)^          persist-credentials: false\r?$'
        foreach ($phase in @($script:validate, $script:publish)) {
            $phase | Should -Match ([regex]::Escape(
                    'CANDIDATE_DIRECTORY: ${{ runner.temp }}/avm-sync-candidates/${{ inputs.repo_name }}'))
            $phase | Should -Match ([regex]::Escape(
                    'RECEIPT_DIRECTORY: ${{ runner.temp }}/avm-sync-validation/${{ inputs.repo_name }}'))
        }
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
        $script:prepare | Should -Match '-repoId \$env:REPO_ID'
        $script:prepare | Should -Match 'REPO_ID: \$\{\{ inputs\.repo_id \}\}'
        $script:prepare | Should -Match '-repoUrl \$env:REPO_URL'
        $script:prepare | Should -Match 'REPO_URL: \$\{\{ inputs\.repo_url \}\}'
        $script:caller | Should -Match ([regex]::Escape(
                'force_file_update: ${{ github.event_name == ''workflow_dispatch'' && inputs.force_file_update }}'))
        $script:caller | Should -Match ([regex]::Escape(
                'sync_project_items: ${{ github.event_name != ''workflow_dispatch'' || inputs.sync_project_items }}'))
    }

    It 'shares the guarded source selection with bootstrap and optional project synchronization' {
        $script:prepare | Should -Match ([regex]::Escape(
                'USE_WORKFLOW_AUTHORING_SOURCE: ${{ github.event_name == ''workflow_dispatch'' && inputs.plan_only && inputs.use_workflow_authoring_source }}'))
        foreach ($name in @('Load Avm.Authoring', 'Add repository items to the AVM All Up project')) {
            $step = [regex]::Match($script:prepare,
                '(?ms)^      - name: ' + [regex]::Escape($name) + '\r?\n(?<body>.*?)(?=^      - name:|\z)')
            $step.Success | Should -BeTrue
            $step.Groups['body'].Value | Should -Match '\$env:USE_WORKFLOW_AUTHORING_SOURCE -eq ''true'''
            $step.Groups['body'].Value | Should -Match ([regex]::Escape(
                    "Join-Path `$env:GITHUB_WORKSPACE 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'"))
            $step.Groups['body'].Value | Should -Match 'Import-Module -Name \$moduleToLoad -Force -ErrorAction Stop'
        }
        $script:prepare | Should -Match '\$planOnly -and \$triggerType -eq ''workflow_dispatch'' -and\s+\$env:USE_WORKFLOW_AUTHORING_SOURCE -eq ''true'''
    }

    It 'stops validation after preparation failures without passing preparation credentials to checks' {
        $script:validate | Should -Not -Match 'always\(\)'
        $script:validate | Should -Not -Match 'continue-on-error:'
        $script:worker | Should -Match '(?m)^      id-token:\s*write\r?$'
        $script:validate | Should -Match 'Invoke-RepositoryCandidate\.ps1 -Mode Validate'
        $script:validate | Should -Not -Match 'GH_TOKEN:|ARM_CLIENT_ID:|ARM_BACKEND_|azure/login@|create-github-app-token@'
        $script:validate | Should -Match 'name:\s*validated-\$\{\{ inputs\.repo_name \}\}'
        $checks = [regex]::Match($script:validate,
            '(?ms)^      - name: Validate repository candidate\r?\n(?<body>.*?)(?=^      - name:|\z)').Groups['body'].Value
        $checks | Should -Not -Match '(?m)^        if:'
        $checks | Should -Match '(?m)^        id: validate-candidate\r?$'
    }

    It 'authenticates candidate tool downloads with the read-only job token' {
        $step = [regex]::Match($script:validate,
            '(?ms)^      - name: Validate repository candidate\r?\n(?<body>.*?)(?=^      - name:|\z)')
        $step.Success | Should -BeTrue
        $step.Groups['body'].Value | Should -Match '(?m)^          GITHUB_TOKEN: \$\{\{ github\.token \}\}\r?$'
        $script:worker | Should -Match '(?m)^      contents:\s*read\r?$'
        $script:worker | Should -Not -Match 'contents:\s*write'
    }

    It 'requires only the candidate profile without adding an integration or E2E gate' {
        $script:validate | Should -Match 'Invoke-RepositoryCandidate\.ps1 -Mode Validate'
        $script:validate | Should -Not -Match 'avm test (integration|e2e)|Invoke-AvmTest(Integration|E2E)'
        $script:workflow | Should -Not -Match '(?m)^  (integration-test|e2e-test):'
    }

    It 'publishes only after this repository validation passes and never for plan-only' {
        $script:publish | Should -Not -Match 'always\(\)'
        $script:publish | Should -Not -Match 'continue-on-error:'
        $step = [regex]::Match($script:publish,
            '(?ms)^      - name: Publish validated candidate\r?\n(?<body>.*?)(?=^      - name:|\z)')
        $step.Success | Should -BeTrue
        $step.Groups['body'].Value | Should -Match ([regex]::Escape(
                "if: `${{ !inputs.plan_only && steps.validate-candidate.outcome == 'success' }}"))
        $script:publish | Should -Match 'Invoke-RepositoryCandidate\.ps1 -Mode Publish'
        $script:publish | Should -Not -Match 'ARM_CLIENT_ID:|azure/login@'
        $script:prepare | Should -Match 'name:\s*candidate-\$\{\{ inputs\.repo_name \}\}'
    }

    Context 'Candidate change output' {
        BeforeAll {
            $step = [regex]::Match($script:publish,
                '(?ms)^      - name: Inspect candidate\r?\n(?<body>.*?)(?=^      - name:|\z)')
            $step.Success | Should -BeTrue
            $step.Groups['body'].Value | Should -Match '(?m)^        id: candidate\r?$'
            $run = [regex]::Match($step.Groups['body'].Value,
                '(?ms)^        run: \|\r?\n(?<body>(?: {10}[^\r\n]*\r?\n|\r?\n)*)')
            $run.Success | Should -BeTrue
            $script:inspectCandidate = [scriptblock]::Create(($run.Groups['body'].Value -replace '(?m)^ {10}', ''))
        }

        BeforeEach {
            $script:previousCandidateEnvironment = @{}
            foreach ($name in @('CANDIDATE_DIRECTORY', 'GITHUB_OUTPUT')) {
                $script:previousCandidateEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            $env:CANDIDATE_DIRECTORY = Join-Path $TestDrive 'candidate'
            $env:GITHUB_OUTPUT = 'candidate-output'
            $script:candidateOutput = [System.Collections.Generic.List[string]]::new()
            Mock Get-Content {
                ConvertTo-Json -InputObject @{ hasChanges = $script:candidateHasChanges } -Compress
            }
            Mock Out-File {
                param($InputObject)
                $script:candidateOutput.Add([string]$InputObject)
            } -RemoveParameterType Encoding
        }

        AfterEach {
            foreach ($name in $script:previousCandidateEnvironment.Keys) {
                $value = $script:previousCandidateEnvironment[$name]
                [Environment]::SetEnvironmentVariable($name, ($null -eq $value ? [NullString]::Value : $value), 'Process')
            }
        }

        It 'writes the exact lowercase output for hasChanges=<HasChanges>' -ForEach @(
            @{ HasChanges = $true; Expected = 'true' }
            @{ HasChanges = $false; Expected = 'false' }
        ) {
            $script:candidateHasChanges = $HasChanges
            & $script:inspectCandidate
            $script:candidateOutput | Should -HaveCount 1
            $script:candidateOutput[0] | Should -BeExactly "has-changes=$Expected"
            Should -Invoke Get-Content -Exactly 1 -ParameterFilter {
                $LiteralPath -eq (Join-Path $env:CANDIDATE_DIRECTORY 'candidate.json') -and $Raw
            }
            Should -Invoke Out-File -Exactly 1 -ParameterFilter {
                $FilePath -eq $env:GITHUB_OUTPUT -and $Append -and $Encoding -eq 'utf8'
            }
        }

        It 'requests a publication token only for changed candidates and passes it to publication' {
            $token = [regex]::Match($script:publish,
                '(?ms)^      - name: Create publication GitHub App token\r?\n(?<body>.*?)(?=^      - name:|\z)')
            $token.Success | Should -BeTrue
            $token.Groups['body'].Value | Should -Match ([regex]::Escape(
                    "if: `${{ !inputs.plan_only && steps.validate-candidate.outcome == 'success' && steps.candidate.outputs.has-changes == 'true' }}"))
            $token.Groups['body'].Value | Should -Match '(?m)^        id: publication-token\r?$'
            $script:publish | Should -Match '(?m)^          GH_TOKEN: \$\{\{ steps\.publication-token\.outputs\.token \}\}\r?$'
        }
    }

    It 'propagates validation errors and uploads receipts only after successful checks' {
        $script:validate | Should -Not -Match 'continue-on-error:'
        $checks = [regex]::Match($script:validate,
            '(?ms)^      - name: Validate repository candidate\r?\n(?<body>.*?)(?=^      - name:|\z)').Groups['body'].Value
        $checks | Should -Match '(?m)^        shell: pwsh\r?$'
        $checks | Should -Match 'Invoke-RepositoryCandidate\.ps1 -Mode Validate'
        $checks | Should -Not -Match '(?i)\btry\s*\{|\bcatch\s*\{|\bexit\s+0\b|SilentlyContinue'
        $upload = [regex]::Match($script:validate,
            '(?ms)^      - name: Upload validation receipt\r?\n(?<body>.*?)(?=^      - name:|\z)').Groups['body'].Value
        $upload | Should -Match '(?m)^        if: success\(\)\r?$'
        $upload | Should -Match '(?m)^          if-no-files-found: error\r?$'
        $upload | Should -Match 'name: validated-\$\{\{ inputs\.repo_name \}\}'
        $script:worker.IndexOf('Validate repository candidate') |
            Should -BeLessThan $script:worker.IndexOf('Upload validation receipt')
        $script:worker.IndexOf('Upload validation receipt') |
            Should -BeLessThan $script:worker.IndexOf('Publish validated candidate')
    }
}
