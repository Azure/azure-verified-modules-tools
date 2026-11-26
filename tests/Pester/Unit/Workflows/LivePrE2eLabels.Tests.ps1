#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    $script:callerCases = @(
        @{ Name = 'Bicep initializer action' }
        @{ Name = 'Bicep reusable workflow' }
        @{ Name = 'Terraform reusable workflow' }
    )
}

BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    $script:module = Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru -Force
    $script:node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

    $labelsAction = ConvertFrom-Yaml (Get-Content -LiteralPath (
            Join-Path $script:root '.github' 'actions' 'pull-request-labels' 'action.yml') -Raw)
    $initializer = ConvertFrom-Yaml (Get-Content -LiteralPath (
            Join-Path $script:root '.github' 'actions' 'bicep-pr-check-initializer' 'action.yml') -Raw)
    $bicep = ConvertFrom-Yaml (Get-Content -LiteralPath (
            Join-Path $script:root '.github' 'workflows' 'bicep-pr-check.yml') -Raw)
    $terraform = ConvertFrom-Yaml (Get-Content -LiteralPath (
            Join-Path $script:root '.github' 'workflows' 'terraform-module.yml') -Raw)
    $script:labelAction = $labelsAction
    $script:labelScript = $labelsAction.runs.steps[0].with.script

    $script:callers = @(
        [pscustomobject]@{
            Name = 'Bicep initializer action'
            Step = @($initializer.runs.steps | Where-Object { $_['id'] -ceq 'labels' })[0]
            Consumer = @($initializer.runs.steps | Where-Object { $_['id'] -ceq 'gate' })[0]
            RequiresPermission = $null
        }
        [pscustomobject]@{
            Name = 'Bicep reusable workflow'
            Step = @($bicep.jobs.initialize.steps | Where-Object { $_['id'] -ceq 'labels' })[0]
            Consumer = @($bicep.jobs.initialize.steps | Where-Object { $_['id'] -ceq 'initialize' })[0]
            RequiresPermission = $bicep.jobs.initialize.permissions.ContainsKey('issues') -and
                $bicep.jobs.initialize.permissions.issues -ceq 'read'
        }
        [pscustomobject]@{
            Name = 'Terraform reusable workflow'
            Step = @($terraform.jobs.'discover-examples'.steps | Where-Object { $_['id'] -ceq 'labels' })[0]
            Consumer = @($terraform.jobs.'discover-examples'.steps | Where-Object { $_['id'] -ceq 'list' })[0]
            RequiresPermission = $terraform.jobs.'discover-examples'.permissions.ContainsKey('issues') -and
                $terraform.jobs.'discover-examples'.permissions.issues -ceq 'read'
        }
    )

    $script:harness = @'
const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
const fixture = JSON.parse(process.env.AVM_FIXTURE);
const script = Buffer.from(process.env.AVM_SCRIPT, 'base64').toString('utf8');
const calls = [];
const endpoint = () => {};
const outputs = {};
const github = {
  rest: { issues: { listLabelsOnIssue: endpoint } },
  paginate: async (method, options) => {
    calls.push({ methodMatches: method === endpoint, options });
    if (fixture.apiError) throw new Error(fixture.apiError);
    return fixture.pages.flat();
  }
};
const core = { setOutput: (name, value) => { outputs[name] = value; } };
process.env.PR_NUMBER = fixture.number;
new AsyncFunction('github', 'core', 'context', script)(
  github,
  core,
  { repo: { owner: 'Azure', repo: 'example-module' } }
)
  .then(() => process.stdout.write(JSON.stringify({ outputs, calls })))
  .catch(error => { process.stderr.write(error.message); process.exitCode = 1; });
'@

    function Invoke-LiveLabelScript {
        param([Parameter(Mandatory)] [hashtable] $Fixture)
        $environment = @{
            AVM_FIXTURE = ConvertTo-Json -InputObject $Fixture -Depth 10 -Compress
            AVM_SCRIPT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:labelScript))
        }
        & $script:module {
            param($Node, $Harness, $Environment)
            Invoke-AvmProcess -FilePath $Node -ArgumentList @('-e', $Harness) `
                -EnvVars $Environment -IgnoreExitCode
        } $script:node $script:harness $environment
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Live pull request E2E label action' {
    It 'uses a pinned GitHub script with explicit pagination and output' {
        $step = $script:labelAction.runs.steps[0]
        $script:labelAction.inputs.pullRequestNumber.required | Should -BeTrue
        $script:labelAction.outputs.names.value | Should -BeExactly '${{ steps.labels.outputs.names }}'
        $step.uses | Should -Match '^actions/github-script@[0-9a-f]{40}$'
        $step.env.PR_NUMBER | Should -BeExactly '${{ inputs.pullRequestNumber }}'
        $step.with.script | Should -Match 'github\.paginate'
        $step.with.script | Should -Match 'per_page: 100'
        $step.with.script | Should -Match "core\.setOutput\('names'"
        $step.ContainsKey('continue-on-error') | Should -BeFalse
    }

    It 'returns all labels from the paginated API result' {
        $result = Invoke-LiveLabelScript -Fixture @{
            number = '42'
            pages = @(
                @(@{ name = 'PR: Run Required E2E Tests' }),
                @(@{ name = 'PR: Run All E2E Tests' })
            )
        }
        $result.ExitCode | Should -Be 0
        $output = $result.StdOut | ConvertFrom-Json
        $output.outputs.names | ConvertFrom-Json | Should -Be @(
            'PR: Run Required E2E Tests'
            'PR: Run All E2E Tests'
        )
        $output.calls | Should -HaveCount 1
        $output.calls[0].methodMatches | Should -BeTrue
        $output.calls[0].options.owner | Should -BeExactly 'Azure'
        $output.calls[0].options.repo | Should -BeExactly 'example-module'
        $output.calls[0].options.issue_number | Should -Be 42
        $output.calls[0].options.per_page | Should -Be 100
    }

    It 'fails explicitly when the label API fails' {
        $result = Invoke-LiveLabelScript -Fixture @{
            number = '42'
            pages = @()
            apiError = 'rate limit exceeded'
        }
        $result.ExitCode | Should -Not -Be 0
        $result.StdErr | Should -Match 'Failed to read current labels for Azure/example-module#42: rate limit exceeded'
    }

    It 'rejects malformed label responses' {
        $result = Invoke-LiveLabelScript -Fixture @{
            number = '42'
            pages = @( @(@{ description = 'missing name' }) )
        }
        $result.ExitCode | Should -Not -Be 0
        $result.StdErr | Should -Match 'invalid label at index 0'
    }
}

Describe 'Live pull request E2E label callers' {
    It 'uses the shared action instead of event labels for <Name>' -ForEach $script:callerCases {
        $caller = @($script:callers | Where-Object Name -CEQ $Name)[0]
        $caller.Step.uses | Should -BeExactly 'Azure/azure-verified-modules-tools/.github/actions/pull-request-labels@f336012d8b69f57ae65193f8a5c79141660078c5'
        $caller.Step.with.pullRequestNumber | Should -BeExactly '${{ github.event.pull_request.number }}'
        $caller.Step.if | Should -Match "github\.event_name == 'pull_request'"
        $caller.Step.if | Should -Match 'github\.repository|head\.repo\.fork'
        $caller.Consumer.env.PR_LABELS | Should -BeExactly '${{ steps.labels.outputs.names || ''[]'' }}'
        if ($null -ne $caller.RequiresPermission) {
            $caller.RequiresPermission | Should -BeTrue
        }
    }
}
