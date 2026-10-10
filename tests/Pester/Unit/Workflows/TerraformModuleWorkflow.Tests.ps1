#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'terraform-module reusable workflow' {
    BeforeAll {
        $script:workflowPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'terraform-module.yml'
        $script:workflow = Get-Content -LiteralPath $script:workflowPath -Raw

        $jobMatch = [regex]::Match($script:workflow, '(?ms)^  e2e-test:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        if (-not $jobMatch.Success) { throw 'Could not isolate the e2e-test job block.' }
        $script:e2eJob = $jobMatch.Value
    }

    It 'uses the shared retrying installer and version input in <Job>' -ForEach @(
        @{ Job = 'unit-test'; Run = '&install-avm-authoring |' }
        @{ Job = 'pr-check-fork'; Run = '*install-avm-authoring' }
        @{ Job = 'pr-check'; Run = '*install-avm-authoring' }
        @{ Job = 'integration-test'; Run = '*install-avm-authoring' }
        @{ Job = 'discover-examples'; Run = '*install-avm-authoring' }
        @{ Job = 'e2e-test'; Run = '*install-avm-authoring' }
    ) {
        $jobPattern = '(?ms)^  ' + [regex]::Escape($Job) + ':\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)'
        $jobBlock = [regex]::Match($script:workflow, $jobPattern).Value
        $jobBlock | Should -Match (
            '(?m)^      - name: Install Avm\.Authoring\r?\n' +
            '        shell: pwsh\r?\n' +
            '        env:\r?\n' +
            '          AVM_AUTHORING_VERSION: \$\{\{ inputs\.avm-authoring-version \}\}\r?\n' +
            '        run: ' + [regex]::Escape($Run) + '\r?$'
        )
    }

    It 'passes the non-secret subscription ID as a job output without masking it' {
        $script:workflow | Should -Match '"subscriptionId=\$\(\$chosen\.id\)"'
        $script:workflow | Should -Not -Match '::add-mask::'
    }

    It 'publishes the full shuffled subscription list for the e2e fan-out' {
        $script:workflow | Should -Match 'subscriptionIds:\s*\$\{\{ steps\.pick\.outputs\.subscriptionIds \}\}'
        $script:workflow | Should -Match '"subscriptionIds=\$ordered"'
    }

    It 'discovers e2e examples with the machine-readable list surface' {
        $script:workflow | Should -Match 'avm test e2e --list'
        $script:workflow | Should -Match 'examples:\s*\$\{\{ steps\.list\.outputs\.examples \}\}'
        $script:workflow | Should -Match 'hasExamples:\s*\$\{\{ steps\.list\.outputs\.hasExamples \}\}'
    }

    It 'fans e2e out across a per-example matrix that does not fail fast' {
        $script:workflow | Should -Match 'fail-fast:\s*false'
        $script:workflow | Should -Match 'example:\s*\$\{\{ fromJson\(needs\.discover-examples\.outputs\.examples\) \}\}'
        $script:workflow | Should -Match 'name:\s*End-to-end tests \(\$\{\{ matrix\.example \}\}\)'
        $script:workflow | Should -Match 'avm test e2e --example'
    }

    It 'skips the e2e matrix when no runnable examples were discovered' {
        $script:workflow | Should -Match "needs\.discover-examples\.outputs\.hasExamples == 'true'"
    }

    It 'keeps the e2e environment static so one approval releases every matrix leg' {
        $script:workflow | Should -Match 'environment:\s*examples-test'
        $script:workflow | Should -Not -Match 'environment:\s*.*\$\{\{\s*matrix\.'
    }

    It 'gates the whole e2e matrix behind a single pending deployment' {
        # Environment protection is evaluated when a job becomes ready to dispatch,
        # not when the run starts. max-parallel releases the legs in waves, and each
        # wave raises a fresh pending deployment - so N legs become ceil(N/limit)
        # approvals. It is exactly the lever someone reaches for when the
        # subscription round-robin is not enough to stay inside Azure quota.
        $script:e2eJob | Should -Not -Match '(?m)^\s*max-parallel\s*:'
        ([regex]::Matches($script:e2eJob, '(?m)^\s*strategy:\s*$')).Count | Should -Be 1
    }

    It 'declares the e2e approval gate on exactly one job' {
        # A second job on examples-test would become ready at a different time and
        # raise its own pending deployment, which one approval would not release.
        ([regex]::Matches($script:workflow, '(?m)^\s*environment:\s*examples-test\s*$')).Count | Should -Be 1
        $script:e2eJob | Should -Match 'needs:\s*\[subscriptions, discover-examples\]'
    }

    It 'round-robins the subscription across matrix legs using strategy.job-index' {
        $script:workflow | Should -Match 'JOB_INDEX:\s*\$\{\{ strategy\.job-index \}\}'
        $script:workflow | Should -Match '\$subs\[\$index % \$subs\.Count\]'
    }

    It 'keeps the single-subscription fallback path for the matrix legs' {
        $script:workflow | Should -Match 'FALLBACK_SUBSCRIPTION_ID:\s*\$\{\{ needs\.subscriptions\.outputs\.subscriptionId \}\}'
    }

    It 'no longer lists per-example e2e targeting as a divergence' {
        $script:workflow | Should -Not -Match 'has no per-example targeting'
    }
}

Describe 'terraform-module fork isolation' {
    BeforeAll {
        $workflowPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'terraform-module.yml'
        $script:workflow = Get-Content -LiteralPath $workflowPath -Raw
        $script:jobs = @{}
        foreach ($name in @('subscriptions', 'unit-test', 'unit-test-fork', 'pr-check', 'pr-check-fork', 'integration-test', 'discover-examples', 'e2e-test')) {
            $pattern = '(?ms)^  ' + [regex]::Escape($name) + ':\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)'
            $block = [regex]::Match($script:workflow, $pattern)
            if (-not $block.Success) { throw "Could not isolate the $name job block." }
            $script:jobs[$name] = $block.Value
        }
        $run = [regex]::Match(
            $script:jobs['pr-check-fork'],
            '(?m)^      - name: Run PR check without policy\r?\n        shell: pwsh\r?\n        run: \|\r?\n(?<code>(?:^          .*\r?\n|^\r?\n)*)')
        if (-not $run.Success -or [string]::IsNullOrWhiteSpace($run.Groups['code'].Value)) {
            throw 'Could not isolate the fork pr-check script.'
        }
        $script:forkCheckScript = [scriptblock]::Create(($run.Groups['code'].Value -replace '(?m)^          ', ''))
    }

    It 'runs <Job> independently with read-only permissions and no protected environment' -ForEach @(
        @{ Job = 'unit-test-fork' }
        @{ Job = 'pr-check-fork' }
    ) {
        $block = $script:jobs[$Job]
        $block | Should -Match '(?m)^    if: github\.event\.pull_request\.head\.repo\.fork == true\r?$'
        $block | Should -Match '(?m)^    runs-on: ubuntu-latest\r?$'
        $block | Should -Match '(?m)^    permissions:\r?\n      contents: read\r?\n    env:'
        $block | Should -Not -Match 'environment:|needs:|id-token:|azure/login@|SELECTED_SUBSCRIPTION|register-features'
        $block | Should -Not -Match '\$\{\{\s*(?:secrets|vars)\.'
    }

    It 'overrides inherited credential contexts and disables OIDC in both fork jobs' {
        $script:jobs['unit-test-fork'] | Should -Match (
            '(?m)^    env: &fork-environment\r?\n' +
            "      SECRETS_CONTEXT: '\{\}'\r?\n" +
            "      VARS_CONTEXT: '\{\}'\r?\n" +
            "      ARM_USE_OIDC: 'false'\r?$")
        $script:jobs['pr-check-fork'] | Should -Match '(?m)^    env: \*fork-environment\r?$'
    }

    It 'shares the unit-test steps but never prepares the environment on a fork' {
        $script:jobs['unit-test'] | Should -Match '(?m)^    steps: &unit-test-steps\r?$'
        $script:jobs['unit-test-fork'] | Should -Match '(?m)^    steps: \*unit-test-steps\r?$'
        $script:jobs['unit-test'] | Should -Match (
            '(?m)^      - name: Prepare test environment\r?\n' +
            '        if: github\.event\.pull_request\.head\.repo\.fork == false\r?$')
        $script:jobs['unit-test'] | Should -Match '(?m)^          avm test unit\r?$'
        $script:jobs['unit-test'] | Should -Match '(?m)^          persist-credentials: false\r?$'
    }

    It 'uses the existing cache setup and non-persistent checkout for fork pr-check' {
        $script:jobs['unit-test'] | Should -Match '(?m)^        run: &configure-avm-tool-cache \|\r?$'
        $script:jobs['pr-check-fork'] | Should -Match '(?m)^        run: \*configure-avm-tool-cache\r?$'
        $script:jobs['pr-check-fork'] | Should -Match '(?m)^          persist-credentials: false\r?$'
        $script:jobs['pr-check-fork'] | Should -Not -Match 'continue-on-error:|Prepare test environment'
    }

    It 'rejects an older module before invoking any checks' {
        & {
            function Import-Module {
                param([string] $Name)
                $Name | Should -Be 'Avm.Authoring'
            }
            function Invoke-AvmPrCheck { param([string] $Path) }
            function avm { throw 'Checks must not execute with an older module.' }

            { & $script:forkCheckScript } | Should -Throw '*Fork checks require an Avm.Authoring release with -ExcludeSteps*'
        }
    }

    It 'runs the composite command excluding only policy with a compatible module' {
        $result = & {
            function Import-Module {
                param([string] $Name)
                $Name | Should -Be 'Avm.Authoring'
            }
            function Invoke-AvmPrCheck { param([string[]] $ExcludeSteps) }
            function avm {
                param([string] $Verb, [string[]] $ExcludeSteps)
                [pscustomobject]@{ Verb = $Verb; Exclusions = $ExcludeSteps }
            }

            & $script:forkCheckScript
        }
        $result.Verb | Should -Be 'pr-check'
        $result.Exclusions | Should -Be @('check policy')
    }

    It 'retains the non-fork gate for <Job>' -ForEach @(
        @{ Job = 'subscriptions' }
        @{ Job = 'unit-test' }
        @{ Job = 'pr-check' }
        @{ Job = 'integration-test' }
        @{ Job = 'discover-examples' }
        @{ Job = 'e2e-test' }
    ) {
        $script:jobs[$Job] | Should -Match 'github\.event\.pull_request\.head\.repo\.fork == false'
    }

    It 'preserves normal-branch credentials, environments, and the full pr-check command' {
        $script:jobs['unit-test'] | Should -Match '(?m)^    environment: no-approval\r?$'
        $script:jobs['pr-check'] | Should -Match '(?m)^    environment: pr-check\r?$'
        $script:jobs['pr-check'] | Should -Match '(?m)^    needs: subscriptions\r?$'
        $script:jobs['pr-check'] | Should -Match '(?m)^      id-token: write\r?$'
        $script:jobs['pr-check'] | Should -Match '(?m)^          avm pr-check\r?$'
        $script:jobs['pr-check'] | Should -Not -Match 'ExcludeSteps|fork-environment'
        foreach ($job in @('unit-test', 'pr-check')) {
            $script:jobs[$job] | Should -Match 'ConvertFrom-Context \$env:SECRETS_CONTEXT'
            $script:jobs[$job] | Should -Match 'ConvertFrom-Context \$env:VARS_CONTEXT'
        }
    }
}

Describe 'terraform-module required Azure feature registration' {
    BeforeAll {
        $workflowPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'terraform-module.yml'
        $script:workflow = Get-Content -LiteralPath $workflowPath -Raw
        $script:jobs = @{}
        foreach ($name in @('subscriptions', 'unit-test', 'pr-check', 'integration-test', 'e2e-test')) {
            $pattern = '(?ms)^  ' + [regex]::Escape($name) + ':\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)'
            $block = [regex]::Match($script:workflow, $pattern)
            if (-not $block.Success) {
                throw "Could not isolate the $name job block."
            }
            $script:jobs[$name] = $block.Value
        }
    }

    It 'never signs in to Azure or registers features in selector, unit, or pr-check jobs' -ForEach @(
        @{ Job = 'subscriptions' }
        @{ Job = 'unit-test' }
        @{ Job = 'pr-check' }
    ) {
        $script:jobs[$Job] | Should -Not -Match 'azure/login@|register-features|Register required features'
    }

    It 'adds pinned Azure login only to the two protected deployment test jobs' {
        ([regex]::Matches($script:workflow, 'uses: azure/login@7ddb5af1ef8758cf1353cf3b42f940aee27ba21c')).Count |
            Should -Be 2
        $script:jobs['integration-test'] | Should -Match '(?m)^    environment: integration-test\r?$'
        $script:jobs['e2e-test'] | Should -Match '(?m)^    environment: examples-test\r?$'
        $script:workflow | Should -Not -Match '(?i)feature unregister|provider unregister'
    }

    It 'uses the effective test identity and the correct selected subscription in <Job>' -ForEach @(
        @{ Job = 'integration-test'; Selection = 'needs.subscriptions.outputs.subscriptionId' }
        @{ Job = 'e2e-test'; Selection = 'steps.leg.outputs.subscriptionId' }
    ) {
        $block = $script:jobs[$Job]
        $block | Should -Match 'client-id: \$\{\{ env\.ARM_CLIENT_ID \}\}'
        $block | Should -Match 'tenant-id: \$\{\{ env\.ARM_TENANT_ID \}\}'
        $block | Should -Match ('subscription-id: \$\{\{ ' + [regex]::Escape($Selection) + ' \}\}')
        $block | Should -Match ('SELECTED_SUBSCRIPTION_ID: \$\{\{ ' + [regex]::Escape($Selection) + ' \}\}')
        ([regex]::Matches($block, "if: steps.required-features.outputs.required == 'true'")).Count |
            Should -Be 2
    }

    It 'checks manifest shape and effective subscription offline before allowing Azure login' {
        $block = $script:jobs['integration-test']
        $block | Should -Match "Test-Path -LiteralPath '.required-features.json' -PathType Leaf"
        $block | Should -Match 'ConvertFrom-Json.+-NoEnumerate'
        $block | Should -Match '\$features.Count -eq 0\) \{'
        $block | Should -Match '\$selected -ne \$effective'
        $block | Should -Match '\$env:ARM_CLIENT_ID'
        $block | Should -Match '\$env:ARM_TENANT_ID'
        $block | Should -Match 'Register-AvmFeature -SubscriptionId \$env:SELECTED_SUBSCRIPTION_ID -WhatIf'
        $block | Should -Match '\$preview.FeaturesTotal -ne \$features.Count'
        $block | Should -Match '''required=true'' \| Out-File -FilePath \$env:GITHUB_OUTPUT'
        $script:jobs['e2e-test'] | Should -Match 'run: \*check-required-features'
    }

    It 'installs the module, checks the per-job selection, logs in, registers, then tests in <Job>' -ForEach @(
        @{ Job = 'integration-test'; Test = 'Run integration tests' }
        @{ Job = 'e2e-test'; Test = 'Run end-to-end tests' }
    ) {
        $block = $script:jobs[$Job]
        $names = @(
            'Install Avm.Authoring'
            'Validate required features offline'
            'Azure login for required features'
            'Register required features'
            $Test
        )
        $positions = @($names | ForEach-Object { $block.IndexOf("- name: $_") })
        foreach ($position in $positions) {
            $position | Should -BeGreaterOrEqual 0
        }
        for ($index = 1; $index -lt $positions.Count; $index++) {
            $positions[$index] | Should -BeGreaterThan $positions[$index - 1]
        }
        $block | Should -Match 'avm register-features --subscription-id \$env:SELECTED_SUBSCRIPTION_ID|run: \*register-required-features'
    }
}

Describe 'CI workflow' {
    BeforeAll {
        $script:ciPath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'ci.yml'
        $script:ci = Get-Content -LiteralPath $script:ciPath -Raw
    }

    It 'disables shared startup JIT profiles before CI PowerShell processes start' {
        $globalEnvironment = [regex]::Match($script:ci, '(?ms)^env:\r?\n(?<body>.*?)(?=^\S|\z)')
        $globalEnvironment.Success | Should -BeTrue
        $globalEnvironment.Groups['body'].Value |
            Should -Match "(?m)^  DOTNET_MultiCoreJitMinNumCpus: '7fffffff'\r?$"
        ([regex]::Matches($script:ci, '(?m)^\s*DOTNET_MultiCoreJitMinNumCpus:')).Count | Should -Be 1
        $script:ci | Should -Match 'run: \./build\.ps1 \$\{\{ matrix\.task \}\}'
        $script:ci | Should -Match 'run: \./build\.ps1 ci-component'
        $script:ci | Should -Match 'run: \./build\.ps1 test-workflows'
        $script:ci | Should -Match 'run: \./build\.ps1 integration'
    }

    It 'keeps workflow-definition tests in a dedicated Ubuntu-only job' {
        $jobMatch = [regex]::Match($script:ci, '(?ms)^  workflows:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $jobMatch.Success | Should -BeTrue
        $jobBlock = $jobMatch.Value

        $jobBlock | Should -Match '(?m)^    runs-on: ubuntu-latest\r?$'
        $jobBlock | Should -Not -Match 'matrix:'
        $jobBlock | Should -Match 'run: \./build\.ps1 test-workflows'
        $jobBlock | Should -Match 'name: test-results-workflows-ubuntu-latest'

        $script:ci | Should -Match 'needs: \[unit, component, workflows, integration, bicep-integration\]'
    }

    It 'authenticates tflint plugin downloads so the shared macOS runner egress does not hit the GitHub API rate limit' {
        $script:ci | Should -Match 'GITHUB_TOKEN:\s*\$\{\{ github\.token \}\}'
    }

    It 'runs lint once in a dedicated Ubuntu job while retaining the three-OS test matrix' {
        $lint = [regex]::Match($script:ci, '(?ms)^  lint:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $unit = [regex]::Match($script:ci, '(?ms)^  unit:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $component = [regex]::Match($script:ci, '(?ms)^  component:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $lint.Success | Should -BeTrue
        $unit.Success | Should -BeTrue
        $component.Success | Should -BeTrue
        $lint.Value | Should -Match '(?m)^    runs-on: ubuntu-latest\r?$'
        $lint.Value | Should -Not -Match 'matrix:'
        $lint.Value | Should -Match 'Install-AvmBuildPrerequisites\.ps1 -IncludePSScriptAnalyzer'
        $lint.Value | Should -Match 'run: \./build\.ps1 lint'
        ([regex]::Matches($script:ci, '(?m)run: \./build\.ps1 lint\r?$')).Count | Should -Be 1
        $unit.Value | Should -Match 'os: ubuntu-latest'
        $unit.Value | Should -Match 'os: windows-latest'
        $unit.Value | Should -Match 'os: macos-latest'
        $unit.Value | Should -Match 'task: ci-coverage'
        $unit.Value | Should -Match 'task: ci-unit'
        $unit.Value | Should -Match 'run: \./build\.ps1 \$\{\{ matrix\.task \}\}'
        $unit.Value | Should -Match 'Upload coverage to GitHub'
        $unit.Value | Should -Match "matrix\.os == 'ubuntu-latest'"
        $unit.Value | Should -Match 'out/coverage/coverage\.cobertura\.xml'
        $component.Value | Should -Match 'os: \[ubuntu-latest, windows-latest, macos-latest\]'
        foreach ($job in @($unit, $component)) {
            $job.Value | Should -Match '(?m)^    timeout-minutes: 25\r?$'
            $job.Value | Should -Match 'Install-AvmBuildPrerequisites\.ps1 -IncludePSScriptAnalyzer'
        }
        $component.Value | Should -Match 'run: \./build\.ps1 ci-component'
    }

    It 'collects coverage in the Ubuntu unit leg without a duplicate test job' {
        $unit = [regex]::Match($script:ci, '(?ms)^  unit:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $unit.Success | Should -BeTrue
        $unit.Value | Should -Match 'task: ci-coverage'
        $unit.Value | Should -Match 'Upload coverage to GitHub'
        $script:ci | Should -Not -Match '(?m)^  coverage:\r?$'
        $script:ci | Should -Not -Match 'coverage-inputs'
        $script:ci | Should -Not -Match 'coverage-input\.zip'
    }

    It 'keeps both unit entry points behind the generated-documentation drift check' {
        $buildPath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'build' 'avm.build.ps1'
        $build = Get-Content -LiteralPath $buildPath -Raw
        $build | Should -Match "(?m)^task 'ci-unit' 'docs-check', layout, test\r?$"
        $build | Should -Match "(?m)^task 'ci-coverage' 'docs-check', layout, coverage\r?$"
    }

    It 'uses the prerequisite installer in every CI test job type' {
        ([regex]::Matches(
                $script:ci,
                '\./scripts/Install-AvmBuildPrerequisites\.ps1')).Count | Should -Be 6
    }

    It 'installs pinned Bicep policy dependencies before integration acceptance only' {
        $integration = [regex]::Match($script:ci, '(?ms)^  bicep-integration:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)')
        $integration.Success | Should -BeTrue
        $integration.Value | Should -Match 'Install-AvmBuildPrerequisites\.ps1 -IncludeBicepPolicy -Confirm:\$false'
        ([regex]::Matches($script:ci, '-IncludeBicepPolicy')).Count | Should -Be 1
        $integration.Value.IndexOf('-IncludeBicepPolicy') |
            Should -BeLessThan $integration.Value.IndexOf('./build.ps1 integration')
    }

    It 'runs Bicep once per OS without cloud credentials and reports every integration group' {
        $bicep = [regex]::Match($script:ci, '(?ms)^  bicep-integration:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)').Value
        $terraform = [regex]::Match($script:ci, '(?ms)^  integration:\r?\n.*?(?=^  [A-Za-z][\w-]*:\r?\n|\z)').Value
        $bicep | Should -Match 'os: \[ubuntu-latest, windows-latest, macos-latest\]'
        $bicep | Should -Match 'integration -IntegrationGroup Bicep'
        $terraform | Should -Match 'integration -IntegrationGroup Terraform'
        $bicep | Should -Not -Match 'environment:|id-token:|azure/login|Add-MpPreference|fixture:'
        $bicep | Should -Match 'if: always\(\)'
        $bicep | Should -Match 'test-results-bicep-integration-'
        $script:ci | Should -Match 'needs: \[unit, component, workflows, integration, bicep-integration\]'
    }
}

Describe 'Release workflow' {
    BeforeAll {
        $releasePath = Join-Path $PSScriptRoot '..' '..' '..' '..' '.github' 'workflows' 'release.yml'
        $script:release = Get-Content -LiteralPath $releasePath -Raw
    }

    It 'runs on ADO promotion and has a required manual release-tag fallback' {
        $script:release | Should -Match '(?m)^\s+types: \[released\]\r?$'
        $script:release | Should -Match '(?m)^  workflow_dispatch:\r?$'
        $script:release | Should -Match '(?ms)^      release_tag:\r?\n' +
            '        description: .+\r?\n' +
            '        required: true\r?\n' +
            '        type: string\r?$'
    }

    It 'converges both triggers on one selected release tag' {
        $selector = [regex]::Escape(
            '${{ github.event_name == ''release'' && github.event.release.tag_name || inputs.release_tag }}'
        )
        ([regex]::Matches($script:release, $selector)).Count | Should -Be 3
        ([regex]::Matches($script:release, '(?m)^\s+RELEASE_TAG:')).Count | Should -Be 1
    }

    It 'accepts only an existing published full release with the exact selected tag' {
        $script:release | Should -Match '--json tagName,isDraft,isPrerelease,publishedAt,databaseId'
        $script:release | Should -Match '\$release\.tagName -cne \$env:RELEASE_TAG'
        $script:release | Should -Match '\$release\.isDraft -or'
        $script:release | Should -Match '\$release\.isPrerelease -or'
        $script:release | Should -Match '\$release\.publishedAt'
    }

    It 'checks out trusted default-branch publisher code' {
        $script:release | Should -Match 'ref: \$\{\{ github\.event\.repository\.default_branch \}\}'
    }

    It 'downloads release assets and delegates publication to the validated script' {
        $script:release | Should -Match '\./scripts/Save-AvmAuthoringReleaseAssets\.ps1'
        $script:release | Should -Match '-ReleaseId \$release\.databaseId'
        $script:release | Should -Not -Match 'gh release download'
        $script:release | Should -Match '\./scripts/Publish-AvmAuthoring\.ps1'
    }

    It 'preserves environment approval and per-release concurrency' {
        $script:release | Should -Match '(?m)^\s+environment: psgallery\r?$'
        $script:release | Should -Match '(?m)^\s+group: psgallery-\$\{\{'
        $script:release | Should -Match '(?m)^\s+cancel-in-progress: false\r?$'
    }

    It 'does not rebuild, upload, create, edit, or promote the release' {
        $script:release | Should -Not -Match '\./build\.ps1'
        $script:release | Should -Not -Match 'gh release (create|upload|edit)'
        $script:release | Should -Not -Match 'contents: write'
    }
}
