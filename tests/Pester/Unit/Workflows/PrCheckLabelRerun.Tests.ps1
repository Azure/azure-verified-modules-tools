#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    $script:module = Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru -Force
    $script:node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

    $script:action = ConvertFrom-Yaml (Get-Content -LiteralPath (
            Join-Path $script:root '.github' 'actions' 'pr-check-rerun' 'action.yml') -Raw)
    $script:workflow = ConvertFrom-Yaml (Get-Content -LiteralPath (
            Join-Path $script:root '.github' 'workflows' 'pr-check-label-rerun.yml') -Raw)
    $script:actionScript = $script:action.runs.steps[0].with.script

    $script:harness = @'
const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
const fixture = JSON.parse(process.env.AVM_FIXTURE);
const script = Buffer.from(process.env.AVM_SCRIPT, 'base64').toString('utf8');
const clone = value => JSON.parse(JSON.stringify(value));
const calls = [];
const outputs = {};
let pullRequestCall = 0;
let labelCall = 0;
let runCall = 0;
const labelsEndpoint = () => {};
const runsEndpoint = () => {};

function sleep(milliseconds) {
  calls.push({ kind: 'sleep', milliseconds });
  return Promise.resolve();
}
global.setTimeout = (callback, milliseconds) => {
  sleep(milliseconds).then(callback);
  return 0;
};

function currentPullRequest() {
  pullRequestCall++;
  const value = clone(fixture.pullRequest);
  if (fixture.headChangeAt && pullRequestCall >= fixture.headChangeAt) {
    value.head.sha = fixture.otherHeadSha;
  }
  if (fixture.baseChangeAt && pullRequestCall >= fixture.baseChangeAt) {
    value.base.sha = fixture.otherBaseSha;
  }
  if (fixture.fork) {
    value.head.repo.id += 1;
  }
  return value;
}

function currentRuns() {
  runCall++;
  if (fixture.noRuns) return [];
  return clone(fixture.runs).map(run => {
    const activeRunId = fixture.activeRunId ?? fixture.runs[0].id;
    if (fixture.activeUntilCall && runCall <= fixture.activeUntilCall && run.id === activeRunId) {
      run.status = 'in_progress';
    }
    return run;
  });
}

const github = {
  rest: {
    pulls: {
      get: async options => {
        calls.push({ kind: 'pull', options });
        if (fixture.apiErrorStage === 'pull') throw new Error('pull request unavailable');
        return { data: currentPullRequest() };
      }
    },
    issues: { listLabelsOnIssue: labelsEndpoint },
    actions: {
      getWorkflowRun: async options => {
        calls.push({ kind: 'dispatcher', options });
        if (fixture.apiErrorStage === 'dispatcher') throw new Error('dispatcher unavailable');
        return { data: clone(fixture.dispatcher) };
      },
      listWorkflowRuns: runsEndpoint,
      reRunWorkflow: async options => {
        calls.push({ kind: 'rerun', options });
        if (fixture.apiErrorStage === 'rerun') throw new Error('rerun denied');
        return { data: {} };
      }
    }
  },
  paginate: async (method, options) => {
    if (method === labelsEndpoint) {
      calls.push({ kind: 'labels', options });
      if (fixture.apiErrorStage === 'labels') throw new Error('labels unavailable');
      labelCall++;
      if (fixture.labelRemovedAt && labelCall >= fixture.labelRemovedAt) return [];
      return clone(fixture.labels);
    }
    if (method === runsEndpoint) {
      calls.push({ kind: 'runs', options });
      if (fixture.apiErrorStage === 'runs') throw new Error('runs unavailable');
      return currentRuns();
    }
    throw new Error('Unexpected pagination endpoint.');
  }
};
const core = {
  info: message => calls.push({ kind: 'info', message }),
  setOutput: (name, value) => { outputs[name] = value; }
};
process.env.PULL_REQUEST_NUMBER = String(fixture.pullRequestNumber);
process.env.EXPECTED_HEAD_SHA = fixture.expectedHeadSha;
process.env.EXPECTED_BASE_SHA = fixture.expectedBaseSha;
process.env.DISPATCHER_RUN_ID = String(fixture.dispatcherRunId);
process.env.WORKFLOW_PATH = fixture.workflowPath;
new AsyncFunction('github', 'core', 'context', script)(
  github,
  core,
  { repo: { owner: 'Azure', repo: 'example-module' } }
)
  .then(() => process.stdout.write(JSON.stringify({ outputs, calls })))
  .catch(error => { process.stderr.write(error.message); process.exitCode = 1; });
'@

    function New-PrCheckRerunFixture {
        $pullRequest = [pscustomobject]@{
            state = 'open'
            head = [pscustomobject]@{
                sha = 'a' * 40
                ref = 'feature'
                repo = [pscustomobject]@{ id = 10 }
            }
            base = [pscustomobject]@{
                sha = 'b' * 40
                ref = 'main'
                repo = [pscustomobject]@{ id = 10 }
            }
        }
        $run = [pscustomobject]@{
            id = 100
            event = 'pull_request'
            path = '.github/workflows/pr-check.yml'
            head_sha = $pullRequest.head.sha
            head_branch = $pullRequest.head.ref
            status = 'completed'
            created_at = '2026-11-26T09:30:00Z'
            run_started_at = '2026-11-26T09:00:00Z'
            pull_requests = @(
                [pscustomobject]@{
                    number = 42
                    head = $pullRequest.head
                    base = $pullRequest.base
                }
            )
        }
        return @{
            pullRequestNumber = 42
            expectedHeadSha = $pullRequest.head.sha
            expectedBaseSha = $pullRequest.base.sha
            dispatcherRunId = 9000
            workflowPath = '.github/workflows/pr-check.yml'
            otherHeadSha = 'c' * 40
            otherBaseSha = 'd' * 40
            pullRequest = $pullRequest
            dispatcher = [pscustomobject]@{
                event = 'pull_request_target'
                run_started_at = '2026-11-26T10:00:00Z'
            }
            labels = @([pscustomobject]@{ name = 'PR: Run Required E2E Tests' })
            runs = @($run)
        }
    }

    function Invoke-PrCheckRerunScript {
        param([Parameter(Mandatory)] [hashtable] $Fixture)
        $environment = @{
            AVM_FIXTURE = ConvertTo-Json -InputObject $Fixture -Depth 20 -Compress
            AVM_SCRIPT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:actionScript))
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

Describe 'PR-check label rerun reusable workflow' {
    It 'keeps caller event wiring thin and owns all admitted rerun behavior' {
        @($script:workflow.on.Keys) | Should -Be @('workflow_call')
        $job = $script:workflow.jobs.'rerun-pr-check'
        $job.if | Should -Match "github\.event_name == 'pull_request_target'"
        $job.if | Should -Match '"labeled","unlabeled"'
        $job.if | Should -Match 'github\.event\.action'
        $job.if | Should -Match "'PR: Run Required E2E Tests'"
        $job.if | Should -Match "'PR: Run All E2E Tests'"
        $job.concurrency.group | Should -BeExactly 'pr-check-label-${{ github.event.pull_request.number }}'
        $job.concurrency.'cancel-in-progress' | Should -BeFalse
        $job.'timeout-minutes' | Should -Be 360
        @($job.permissions.Keys | Sort-Object) | Should -Be @('actions', 'contents', 'issues', 'pull-requests')
        $job.permissions.actions | Should -BeExactly 'write'
        $job.permissions.contents | Should -BeExactly 'read'
        $job.permissions.issues | Should -BeExactly 'read'
        $job.permissions.'pull-requests' | Should -BeExactly 'read'
    }

    It 'checks out only an immutable trusted Tools revision before using the local action' {
        $job = $script:workflow.jobs.'rerun-pr-check'
        $job.steps | Should -HaveCount 3
        $job.steps[0].run | Should -Match '\^\[0-9a-f\]\{40\}\$'
        $checkout = $job.steps[1]
        $checkout.uses | Should -Match '^actions/checkout@[0-9a-f]{40}$'
        $checkout.with.repository | Should -BeExactly 'Azure/azure-verified-modules-tools'
        $checkout.with.ref | Should -BeExactly '${{ inputs.tools-ref }}'
        $checkout.with.path | Should -BeExactly '.avm-tools'
        $checkout.with.'persist-credentials' | Should -BeFalse
        $checkout.with.ref | Should -Not -Match 'github\.event'
        $job.steps[2].uses | Should -BeExactly './.avm-tools/.github/actions/pr-check-rerun'
        $job.steps[2].with.expectedHeadSha | Should -BeExactly '${{ github.event.pull_request.head.sha }}'
        $job.steps[2].with.expectedBaseSha | Should -BeExactly '${{ github.event.pull_request.base.sha }}'
    }
}

Describe 'PR-check label rerun action' {
    It 'exposes a narrow immutable action contract' {
        @($script:action.inputs.Keys | Sort-Object) | Should -Be @(
            'dispatcherRunId'
            'expectedBaseSha'
            'expectedHeadSha'
            'pullRequestNumber'
            'workflowPath'
        )
        @($script:action.outputs.Keys | Sort-Object) | Should -Be @('outcome', 'runId')
        $script:action.runs.steps[0].uses | Should -Match '^actions/github-script@[0-9a-f]{40}$'
        $script:action.runs.steps[0].with.script | Should -Match 'github\.paginate'
        $script:action.runs.steps[0].with.script | Should -Match 'per_page: 100'
        $script:action.runs.steps[0].with.script | Should -Not -Match 'actions/checkout|github\.head_ref|github\.sha'
    }

    It 'reruns the newest exactly matching completed pull_request run' {
        $result = Invoke-PrCheckRerunScript -Fixture (New-PrCheckRerunFixture)
        $result.ExitCode | Should -Be 0
        $output = $result.StdOut | ConvertFrom-Json
        $output.outputs.outcome | Should -BeExactly 'rerun-requested'
        $output.outputs.runId | Should -BeExactly '100'
        @($output.calls | Where-Object kind -EQ 'rerun') | Should -HaveCount 1
        @($output.calls | Where-Object kind -EQ 'labels')[0].options.per_page | Should -Be 100
        @($output.calls | Where-Object kind -EQ 'runs')[0].options.per_page | Should -Be 100
        @($output.calls | Where-Object kind -EQ 'runs')[0].options.workflow_id | Should -BeExactly 'pr-check.yml'
    }

    It 'waits for matching active runs before requesting a rerun' {
        $fixture = New-PrCheckRerunFixture
        $fixture.activeUntilCall = 1
        $result = Invoke-PrCheckRerunScript -Fixture $fixture
        $result.ExitCode | Should -Be 0
        $output = $result.StdOut | ConvertFrom-Json
        @($output.calls | Where-Object kind -EQ 'sleep') | Should -HaveCount 1
        @($output.calls | Where-Object kind -EQ 'rerun') | Should -HaveCount 1
    }

    It 'waits for an older active run before accepting a newer observed attempt' {
        $fixture = New-PrCheckRerunFixture
        $newer = $fixture.runs[0].PSObject.Copy()
        $newer.id = 101
        $newer.created_at = '2026-11-26T10:00:01Z'
        $newer.run_started_at = '2026-11-26T10:00:01Z'
        $fixture.runs = @($newer, $fixture.runs[0])
        $fixture.activeRunId = 100
        $fixture.activeUntilCall = 1
        $result = Invoke-PrCheckRerunScript -Fixture $fixture
        $result.ExitCode | Should -Be 0
        $output = $result.StdOut | ConvertFrom-Json
        $output.outputs.outcome | Should -BeExactly 'already-observed'
        @($output.calls | Where-Object kind -EQ 'sleep') | Should -HaveCount 1
        @($output.calls | Where-Object kind -EQ 'rerun') | Should -HaveCount 0
    }

    It 'does not duplicate a run that already observed the label event' {
        $fixture = New-PrCheckRerunFixture
        $fixture.runs[0].run_started_at = '2026-11-26T10:00:01Z'
        $fixture.runs[0].status = 'in_progress'
        $result = Invoke-PrCheckRerunScript -Fixture $fixture
        $result.ExitCode | Should -Be 0
        $output = $result.StdOut | ConvertFrom-Json
        $output.outputs.outcome | Should -BeExactly 'already-observed'
        @($output.calls | Where-Object kind -EQ 'rerun') | Should -HaveCount 0
    }

    It 'leaves a moved head to its synchronize run' {
        $fixture = New-PrCheckRerunFixture
        $fixture.headChangeAt = 1
        $result = Invoke-PrCheckRerunScript -Fixture $fixture
        $result.ExitCode | Should -Be 0
        $output = $result.StdOut | ConvertFrom-Json
        $output.outputs.outcome | Should -BeExactly 'head-changed'
        @($output.calls | Where-Object kind -EQ 'rerun') | Should -HaveCount 0
    }

    It 'rechecks labels immediately before rerun' {
        $fixture = New-PrCheckRerunFixture
        $fixture.labelRemovedAt = 2
        $result = Invoke-PrCheckRerunScript -Fixture $fixture
        $result.ExitCode | Should -Be 0
        $output = $result.StdOut | ConvertFrom-Json
        $output.outputs.outcome | Should -BeExactly 'label-removed'
        @($output.calls | Where-Object kind -EQ 'rerun') | Should -HaveCount 0
    }

    It 'reruns an E2E removal when another E2E label remains' {
        $fixture = New-PrCheckRerunFixture
        $fixture.labels = @([pscustomobject]@{ name = 'PR: Run Required E2E Tests' })
        $result = Invoke-PrCheckRerunScript -Fixture $fixture
        $result.ExitCode | Should -Be 0
        $output = $result.StdOut | ConvertFrom-Json
        $output.outputs.outcome | Should -BeExactly 'rerun-requested'
        @($output.calls | Where-Object kind -EQ 'rerun') | Should -HaveCount 1
    }

    It 'skips an E2E removal when no E2E label remains' {
        $fixture = New-PrCheckRerunFixture
        $fixture.labelRemovedAt = 1
        $result = Invoke-PrCheckRerunScript -Fixture $fixture
        $result.ExitCode | Should -Be 0
        $output = $result.StdOut | ConvertFrom-Json
        $output.outputs.outcome | Should -BeExactly 'label-removed'
        @($output.calls | Where-Object kind -EQ 'runs') | Should -HaveCount 0
        @($output.calls | Where-Object kind -EQ 'rerun') | Should -HaveCount 0
    }

    It 'fails closed for forks, base changes, missing runs, and API errors' -ForEach @(
        @{ Case = 'fork'; Change = { $fixture.fork = $true }; Error = '.*from a fork.*' }
        @{ Case = 'base change'; Change = { $fixture.baseChangeAt = 1 }; Error = '.*base changed.*' }
        @{ Case = 'missing run'; Change = { $fixture.noRuns = $true }; Error = '.*No PR-check run matched.*' }
        @{ Case = 'dispatcher API error'; Change = { $fixture.apiErrorStage = 'dispatcher' }; Error = '.*Failed to read dispatcher run.*dispatcher unavailable.*' }
        @{ Case = 'label API error'; Change = { $fixture.apiErrorStage = 'labels' }; Error = '.*Failed to read current labels.*labels unavailable.*' }
        @{ Case = 'run API error'; Change = { $fixture.apiErrorStage = 'runs' }; Error = '.*Failed to list PR-check runs.*runs unavailable.*' }
        @{ Case = 'rerun API error'; Change = { $fixture.apiErrorStage = 'rerun' }; Error = '.*Failed to rerun PR-check run.*rerun denied.*' }
    ) {
        $fixture = New-PrCheckRerunFixture
        & $Change
        $result = Invoke-PrCheckRerunScript -Fixture $fixture
        $result.ExitCode | Should -Not -Be 0
        $result.StdErr | Should -Match $Error
    }

    It 'ignores runs with a different <Case>' -ForEach @(
        @{ Case = 'workflow path'; Change = { $fixture.runs[0].path = '.github/workflows/other.yml' } }
        @{ Case = 'event'; Change = { $fixture.runs[0].event = 'workflow_dispatch' } }
        @{ Case = 'head SHA'; Change = { $fixture.runs[0].head_sha = 'e' * 40 } }
        @{ Case = 'head branch'; Change = { $fixture.runs[0].head_branch = 'other' } }
        @{ Case = 'pull request number'; Change = { $fixture.runs[0].pull_requests[0].number = 99 } }
        @{
            Case = 'associated base'
            Change = {
                $fixture.runs[0].pull_requests[0].base = [pscustomobject]@{
                    sha = $fixture.pullRequest.base.sha
                    ref = 'other'
                    repo = [pscustomobject]@{ id = 10 }
                }
            }
        }
        @{
            Case = 'associated repository'
            Change = {
                $fixture.runs[0].pull_requests[0].head = [pscustomobject]@{
                    sha = $fixture.pullRequest.head.sha
                    ref = $fixture.pullRequest.head.ref
                    repo = [pscustomobject]@{ id = 99 }
                }
            }
        }
    ) {
        $fixture = New-PrCheckRerunFixture
        & $Change
        $result = Invoke-PrCheckRerunScript -Fixture $fixture
        $result.ExitCode | Should -Not -Be 0
        $result.StdErr | Should -Match 'No PR-check run matched'
    }
}
