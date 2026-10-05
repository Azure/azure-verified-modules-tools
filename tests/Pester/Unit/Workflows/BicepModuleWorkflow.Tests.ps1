#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:root 'scripts' 'bicep-workflows' 'Common.ps1')
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    $script:workflows = @{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:root '.github' 'workflows') -Filter 'bicep-module*.yml') {
        $script:workflows[$file.BaseName] = ConvertFrom-Yaml (Get-Content -LiteralPath $file.FullName -Raw)
    }
    $script:actions = @{}
    foreach ($directory in Get-ChildItem -LiteralPath (Join-Path $script:root '.github' 'actions') -Directory -Filter 'bicep-*') {
        $script:actions[$directory.Name] = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $directory.FullName 'action.yml') -Raw)
    }
}

Describe 'Bicep reusable workflow ownership and syntax' {
    It 'accounts for all six reusable responsibilities without adding automatic triggers' {
        $script:workflows.Count | Should -Be 6
        foreach ($workflow in $script:workflows.Values) {
            @($workflow.on.Keys) | Should -Be @('workflow_call')
            $workflow.name | Should -Match '^Reusable: Bicep Module'
            $workflow.permissions.Count | Should -Be 0
            foreach ($inputName in @('tools-ref', 'avm-authoring-version')) {
                $workflow.on.workflow_call.inputs[$inputName].required | Should -BeTrue
                $workflow.on.workflow_call.inputs[$inputName].Contains('default') | Should -BeFalse
            }
        }
    }

    It 'uses tools-owned support at the explicit immutable revision in every executable job' {
        foreach ($workflow in $script:workflows.Values) {
            foreach ($job in $workflow.jobs.Values) {
                if (-not $job.Contains('steps')) { continue }
                $usesSupport = @($job.steps | Where-Object { $_['uses'] -like './.avm-tools/*' })
                if ($usesSupport.Count -eq 0) { continue }
                foreach ($caller in $job.steps | Where-Object { $_['name'] -eq 'Check out caller' }) {
                    $caller.with.Contains('sparse-checkout') | Should -BeFalse
                }
                $checkout = @($job.steps | Where-Object { $_.Contains('with') -and $_.with['repository'] -eq 'Azure/azure-verified-modules-tools' })
                $checkout.Count | Should -Be 1
                $checkout[0].with.ref | Should -BeExactly '${{ inputs.tools-ref }}'
                $checkout[0].with.path | Should -BeExactly '.avm-tools'
                $checkout[0].with.'persist-credentials' | Should -BeFalse
                $checkout[0].with.'sparse-checkout' | Should -Match 'scripts/bicep-workflows'
                $checkout[0].with.'sparse-checkout' | Should -Not -Match '(?m)^src$|^tests$'
                foreach ($step in $usesSupport) {
                    $actionName = $step.uses.Split('/')[-1]
                    $script:actions.ContainsKey($actionName) | Should -BeTrue
                    foreach ($key in $step.with.Keys) {
                        $script:actions[$actionName].inputs.Contains($key) | Should -BeTrue
                    }
                }
            }
        }
    }

    It 'keeps nested reusable calls relative and forwards both immutable contracts' {
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish')) {
            $job = $script:workflows[$name].jobs.job_module_deploy_validation
            $job.uses | Should -BeExactly './.github/workflows/bicep-module-deployment.yml'
            $job.with.'tools-ref' | Should -BeExactly '${{ inputs.tools-ref }}'
            $job.with.'avm-authoring-version' | Should -BeExactly '${{ inputs.avm-authoring-version }}'
            $job.secrets | Should -BeExactly 'inherit'
        }
    }

    It 'keeps generic validation and nested deployment on the same explicit target commit' {
        foreach ($name in @('bicep-module-preview', 'bicep-module-publish', 'bicep-module-publish-only')) {
            foreach ($job in $script:workflows[$name].jobs.Values) {
                if (-not $job.Contains('steps')) { continue }
                foreach ($step in $job.steps | Where-Object { $_['name'] -eq 'Check out caller' }) {
                    $step.with.ref | Should -BeExactly '${{ inputs.targetCommit }}'
                    $step.with.'persist-credentials' | Should -BeFalse
                }
            }
        }
        foreach ($name in @('bicep-module-preview', 'bicep-module-publish')) {
            $script:workflows[$name].jobs.job_module_deploy_validation.with.targetCommit | Should -BeExactly '${{ inputs.targetCommit }}'
        }
        $inner = $script:workflows['bicep-module-deployment']
        $inner.on.workflow_call.inputs.targetCommit.required | Should -BeFalse
        ($inner.jobs.job_module_deploy_validation.steps | Where-Object { $_['name'] -eq 'Check out caller' }).with.ref |
            Should -BeExactly '${{ inputs.targetCommit || github.sha }}'
    }

    It 'resolves initializer implementations from the remote action checkout rather than the caller' {
        foreach ($name in @('bicep-workflow-input', 'bicep-module-test-files', 'bicep-workflow-matrix')) {
            $action = $script:actions[$name]
            foreach ($step in $action.runs.steps) {
                $step.env.AVM_ACTION_PATH | Should -BeExactly '${{ github.action_path }}'
                $step.run | Should -Match "Join-Path .env:AVM_ACTION_PATH '\.\.' '\.\.' '\.\.'"
                $step.run | Should -Match "Join-Path .root 'scripts' 'bicep-workflows'"
                $step.run | Should -Not -Match "Join-Path .env:GITHUB_WORKSPACE 'scripts'"
            }
        }
        @($script:actions['bicep-workflow-matrix'].outputs.Keys | Sort-Object) |
            Should -Be @('baseCommit', 'hasModules', 'includeAllVersionedModules', 'moduleMatrix', 'targetCommit', 'workflowInput')
    }

    It 'parses every embedded PowerShell script without interpolated workflow expressions' {
        $steps = @(
            foreach ($workflow in $script:workflows.Values) {
                foreach ($job in $workflow.jobs.Values) {
                    if ($job.Contains('steps')) { $job.steps }
                }
            }
            foreach ($action in $script:actions.Values) { $action.runs.steps }
        )
        foreach ($step in $steps) {
            if ($step.Contains('run')) {
                $step.shell | Should -Be 'pwsh'
                $step.run | Should -Not -Match '\$\{\{'
                $tokens = $null
                $parseErrors = $null
                $null = [Management.Automation.Language.Parser]::ParseInput($step.run, [ref]$tokens, [ref]$parseErrors)
                @($parseErrors).Count | Should -Be 0 -Because $step.name
            }
            if ($step['uses'] -and -not $step.uses.StartsWith('./')) {
                $step.uses | Should -Match '@[0-9a-f]{40}$'
            }
        }
    }

    It 'never resolves shared implementations through registry utilities or caller-local templates' {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts' 'bicep-workflows') -File)
        $files += @(Get-ChildItem -LiteralPath (Join-Path $script:root '.github' 'workflows') -Filter 'bicep-module*.yml')
        $files += @(Get-ChildItem -Path (Join-Path $script:root '.github' 'actions' 'bicep-*' 'action.yml') -File)
        foreach ($file in $files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $text | Should -Not -Match 'utilities[/\\]|\.github/actions/templates|bicep publish|avm publish|az deployment|Add-MpPreference'
        }
    }
}

Describe 'Bicep required checks and deployment guards' {
    It 'selects only the appropriate deployment steps when ignored is <Ignored>' -ForEach @(
        @{ Ignored = $true }
        @{ Ignored = $false }
    ) {
        $steps = $script:workflows['bicep-module-deployment'].jobs.job_module_deploy_validation.steps
        $selected = @(foreach ($step in $steps) {
                if ($step.name -eq 'Report skipped deployment') {
                    $step.if | Should -BeExactly 'fromJSON(inputs.testCase).e2eIgnore'
                    if ($Ignored) { $step }
                }
                else {
                    $step.if | Should -BeExactly '${{ !fromJSON(inputs.testCase).e2eIgnore }}'
                    if (-not $Ignored) { $step }
                }
            })
        if ($Ignored) {
            $selected.Count | Should -Be 1
            $selected[0].name | Should -BeExactly 'Report skipped deployment'
            $selected[0].run | Should -Match 'Deployment skipped'
            $selected[0].Contains('uses') | Should -BeFalse
            $selected[0].run | Should -Not -Match 'GITHUB_WORKSPACE|Initialize-AvmWorkflow|Import-Module'
        }
        else {
            $selected.Count | Should -Be 4
            $selected[-1].uses | Should -BeExactly './.avm-tools/.github/actions/bicep-deployment'
        }
    }

    It 'preserves stable jobs, required/advisory matrices, and skip/failure dependencies' {
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_module_static_validation.name | Should -BeExactly 'Static validation'
            $jobs.job_psrule_must.strategy.matrix.baseline.baselineName |
                Should -Be @('Azure.Pillar.Reliability', 'CB.AVM.WAF.Security')
            $jobs.job_psrule_opt.strategy.matrix.baseline.baselineName |
                Should -Be @('Azure.Default', 'Azure.Pillar.Security')
            foreach ($key in @('job_psrule_must', 'job_psrule_opt')) {
                $jobs[$key].strategy.'fail-fast' | Should -BeFalse
                $jobs[$key].if | Should -Match "!= '\[\]'"
                $jobs[$key].if | Should -Match "!= ''"
                $jobs[$key].Contains('continue-on-error') | Should -BeFalse
            }
            $jobs.job_module_deploy_validation.if | Should -Match '!cancelled\(\)'
            $jobs.job_module_deploy_validation.if | Should -Match "job_psrule_must.result != 'failure'"
            $jobs.job_module_deploy_validation.needs | Should -Not -Contain 'job_psrule_opt'
            $jobs.job_module_deploy_validation.if | Should -Match "moduleTestFilePaths != '\[\]'"
        }
    }

    It 'preserves environment-bound identity and whole-lifecycle shared and subscription locks' {
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_initialize_subscription_selection.environment | Should -BeExactly 'avm-validation'
            $jobs.job_initialize_subscription_selection.permissions.Contains('id-token') | Should -BeFalse
            $jobs.job_module_deploy_validation.concurrency.group | Should -Match 'avm-deploy-\{0\}-shared'
            $jobs.job_module_deploy_validation.concurrency.group | Should -Match 'run-\{1\}-\{2\}-\{3\}'
            $jobs.job_module_deploy_validation.concurrency.queue | Should -Be 'max'
        }
        $job = $script:workflows['bicep-module-deployment'].jobs.job_module_deploy_validation
        $job.environment | Should -BeExactly 'avm-validation'
        $job.permissions.'id-token' | Should -Be 'write'
        $job.concurrency.group | Should -BeExactly '${{ fromJSON(inputs.testCase).concurrencyGroup }}'
        foreach ($step in $job.steps | Where-Object name -NE 'Report skipped deployment') {
            $step.if | Should -Match '!fromJSON\(inputs.testCase\).e2eIgnore'
        }
    }

    It 'keeps fork static validation free of secrets, environments, login and publication' {
        $workflow = $script:workflows['bicep-module-static']
        @($workflow.jobs.Keys) | Should -Be @('job_module_static_validation')
        $text = Get-Content -LiteralPath (Join-Path $script:root '.github' 'workflows' 'bicep-module-static.yml') -Raw
        $text | Should -Not -Match 'secrets|id-token|azure/login|environment:|bicep-release-tags'
    }

    It 'preserves identifier precedence and confines secret credentials to exception authentication' {
        $pool = '${{ vars.VALIDATE_SUBSCRIPTION_IDS || vars.TEST_SUBSCRIPTION_IDS || secrets.VALIDATE_SUBSCRIPTION_IDS || secrets.TEST_SUBSCRIPTION_IDS }}'
        $managementGroup = '${{ vars.VALIDATE_MANAGEMENT_GROUP_ID || vars.ARM_MGMTGROUP_ID || secrets.VALIDATE_MANAGEMENT_GROUP_ID || secrets.ARM_MGMTGROUP_ID }}'
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_initialize_subscription_selection.steps[-1].env.TEST_SUBSCRIPTION_IDS | Should -BeExactly $pool
            foreach ($jobName in @('job_psrule_must', 'job_psrule_opt')) {
                $jobs[$jobName].steps[-1].env.TEST_SUBSCRIPTION_IDS | Should -BeExactly $pool
                $jobs[$jobName].steps[-1].env.ARM_MGMTGROUP_ID | Should -BeExactly $managementGroup
                $jobs[$jobName].steps[-1].env.Contains('AZURE_CREDENTIALS') | Should -BeFalse
            }
        }
        $deployment = $script:workflows['bicep-module-deployment'].jobs.job_module_deploy_validation.steps[-1].with
        $deployment.subscriptionPool | Should -BeExactly $pool
        $deployment.managementGroupId | Should -BeExactly $managementGroup
        $deployment.fallbackSubscriptionId | Should -BeExactly '${{ vars.VALIDATE_SUBSCRIPTION_ID || secrets.VALIDATE_SUBSCRIPTION_ID }}'
        $deployment.clientId | Should -BeExactly '${{ vars.VALIDATE_CLIENT_ID || secrets.VALIDATE_CLIENT_ID }}'
        $deployment.tenantId | Should -BeExactly '${{ vars.VALIDATE_TENANT_ID || secrets.VALIDATE_TENANT_ID }}'
        $deployment.azureCredentials | Should -BeExactly '${{ secrets.AZURE_CREDENTIALS }}'
        foreach ($name in @('bicep-module-preview', 'bicep-module-publish')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_module_deploy_validation.with.tokenNamePrefix | Should -BeExactly 'gci'
            $jobs.job_psrule_must.steps[-1].env.TOKEN_NAMEPREFIX | Should -BeExactly 'gci'
            $jobs.job_psrule_opt.steps[-1].env.TOKEN_NAMEPREFIX | Should -BeExactly 'gci'
        }
    }

    It 'confines CI contexts to native deployment and preserves renewal, failure and cancellation order' {
        $steps = $script:actions['bicep-deployment'].runs.steps
        $ids = @($steps | Where-Object { $_['id'] } | ForEach-Object id)
        $ids | Should -Be @('auth', 'setup', 'login_oidc', 'login_secret', 'context', 'deploy', 'renew_oidc', 'renew_secret', 'complete')
        foreach ($step in $steps) {
            if ($step.Contains('env') -and ($step.env['AVM_CI_SECRETS'] -or $step.env['AVM_CI_VARIABLES'])) { $step.id | Should -Be 'deploy' }
            if ($step['id'] -in @('renew_oidc', 'renew_secret', 'complete') -or $step.name -eq 'Recover unfinished native cleanup') {
                $step.if | Should -Match '!cancelled\(\)'
            }
        }
        $steps[-1].if | Should -Match 'always\(\)'
        $steps[-1].with.path | Should -Match 'avm-bicep-state'
        ($steps | Where-Object { $_['id'] -eq 'login_oidc' }).with.'subscription-id' |
            Should -BeExactly ($steps | Where-Object { $_['id'] -eq 'renew_oidc' }).with.'subscription-id'
        ($steps | Where-Object name -EQ 'Recover unfinished native cleanup').if | Should -Match "removeDeployment == 'true'"
    }

    It 'preserves deployment defaults when a custom location is supplied: <Provided>' -ForEach @(
        @{ Provided = $false }
        @{ Provided = $true }
    ) {
        $deploy = $script:actions['bicep-deployment'].runs.steps | Where-Object { $_['id'] -eq 'deploy' }
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($deploy.run, [ref]$tokens, [ref]$errors)
        $assignment = @($ast.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $_.Left.VariablePath.UserPath -eq 'parameters'
            })
        $assignment.Count | Should -Be 1
        $workflowInput = @{ removeDeployment = 'true' }
        if ($Provided) { $workflowInput.customLocation = 'northeurope' }
        $case = @{ path = 'tests/e2e/defaults/main.test.bicep' }
        $savedTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP')
        try {
            $env:RUNNER_TEMP = $TestDrive
            $parameters = & ([scriptblock]::Create($assignment[0].Extent.Text + "`n" + '$parameters'))
            $parameters.RemoveDeployment | Should -BeTrue
            $parameters.Example | Should -BeExactly $case.path
            if ($Provided) { $parameters.CustomLocation | Should -BeExactly 'northeurope' }
            else { $parameters.CustomLocation | Should -BeNullOrEmpty }
        }
        finally {
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $(if ($null -eq $savedTemp) { [NullString]::Value } else { $savedTemp }))
        }
    }
}

Describe 'Bicep release-tag safety contracts' {
    It 'serializes every release variant and limits writes to actual publishing jobs' {
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish', 'bicep-module-publish-only')) {
            $jobName = if ($name -eq 'bicep-module-preview') { 'job_preview_module' } else { 'job_publish_module' }
            $job = $script:workflows[$name].jobs[$jobName]
            $job.concurrency.group | Should -BeExactly 'avm-publish-${{ inputs.modulePath }}'
            $job.concurrency.queue | Should -Be 'max'
            $job.if | Should -Match "github.repository == 'Azure/bicep-registry-modules'"
            $job.if | Should -Match "github.ref == 'refs/heads/main'"
            $job.permissions.Contains('id-token') | Should -BeFalse
            $job.permissions.contents | Should -Be $(if ($name -eq 'bicep-module-preview') { 'read' } else { 'write' })
        }
    }

    It 'preserves preview-only push behavior and explicit release approval' {
        $preview = $script:workflows['bicep-module-preview'].jobs.job_preview_module
        $preview.if | Should -Match "github.event_name == 'push'"
        $preview.if | Should -Match 'includeAllVersionedModules'
        $preview.steps[-1].with.preview | Should -Be 'true'
        foreach ($name in @('bicep-module-publish', 'bicep-module-publish-only')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_publish_approval.environment | Should -BeExactly 'publish-approval'
            $jobs.job_publish_module.if | Should -Match "job_publish_approval.result == 'success'"
        }
        $script:workflows['bicep-module-publish'].jobs.job_publish_module.if | Should -Match 'inputs.publishReleaseTag'
        @($script:workflows['bicep-module-publish-only'].jobs.Keys).Count | Should -Be 2
    }
}
