#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:repoRoot 'build' 'AvmCi.ps1')
    $script:selector = Join-Path $script:repoRoot 'scripts' 'Get-AvmCiScope.ps1'
    $module = Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru
    $null = & $module { Import-AvmPowerShellModule -Name powershell-yaml -Global }
    $script:definitions = @{}
    foreach ($name in @('ci.yml', 'ci-authoring.yml', 'ci-workflows.yml', 'repository-management-config-test.yml')) {
        $text = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github' 'workflows' $name) -Raw
        $script:definitions[$name] = ConvertFrom-Yaml -Yaml $text
    }
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'CI path routing' {
    It 'selects <Expected> for <Path>' -ForEach @(
        @{ Path = 'src/Avm.Authoring/Public/Invoke-AvmFormat.ps1'; Expected = 'authoring,repository-management' }
        @{ Path = 'src/Avm.Authoring/Engines/Terraform/Invoke-AvmTerraformFormat.ps1'; Expected = 'authoring,repository-management' }
        @{ Path = 'tests/Pester/Unit/Public/Invoke-AvmFormat.Tests.ps1'; Expected = 'authoring' }
        @{ Path = 'tests/Pester/Component/BicepDocs.Component.Tests.ps1'; Expected = 'authoring' }
        @{ Path = 'tests/Pester/Integration/BicepFuture.Tests.ps1'; Expected = 'authoring' }
        @{ Path = 'tests/fixtures/modules/bicep-docs/main.bicep'; Expected = 'authoring' }
        @{ Path = 'tests/Pester/Helpers/BicepNativeWorkflow.ps1'; Expected = 'authoring' }
        @{ Path = 'scripts/Generate-AvmCmdletDocumentation.ps1'; Expected = 'authoring' }
        @{ Path = 'docs/reference/Invoke-AvmFormat.md'; Expected = 'authoring' }
        @{ Path = 'CHANGELOG.md'; Expected = 'authoring' }
        @{ Path = '.github/workflows/ci-authoring.yml'; Expected = 'authoring,workflows' }
        @{ Path = '.github/workflows/ci-workflows.yml'; Expected = 'workflows' }
        @{ Path = '.github/workflows/release.yml'; Expected = 'workflows' }
        @{ Path = '.github/dependabot.yml'; Expected = 'workflows' }
        @{ Path = 'tests/Pester/Unit/Workflows/ScopedCi.Tests.ps1'; Expected = 'workflows' }
        @{ Path = 'tests/Pester/Unit/Workflows/fixtures/example.yml'; Expected = 'workflows' }
        @{ Path = 'repository-management/bicep-test-tenant-sync/scripts/lib/ModuleIdentitySync.ps1'; Expected = 'repository-management' }
        @{ Path = 'repository-management/repository-sync/scripts/lib/RetryHelpers.ps1'; Expected = 'repository-management' }
        @{ Path = 'repository-management/workflow-failure-issues/scripts/lib/WorkflowFailureIssues.ps1'; Expected = 'repository-management' }
        @{ Path = 'tests/Pester/Unit/RepositoryManagement/WorkflowFailureIssues.Tests.ps1'; Expected = 'repository-management' }
        @{ Path = 'tests/Pester/Component/BicepModuleIdentities.Component.Tests.ps1'; Expected = 'repository-management' }
        @{ Path = 'tests/Pester/Component/BicepTestTenantSync.Component.Tests.ps1'; Expected = 'repository-management' }
        @{ Path = 'tests/Pester/Component/ModuleCatalog.Collection.Tests.ps1'; Expected = 'repository-management' }
        @{ Path = 'tests/Pester/Component/RepositorySyncGate.Component.Tests.ps1'; Expected = 'repository-management' }
        @{ Path = 'tests/Pester/Component/TerraformCodeowners.Component.Tests.ps1'; Expected = 'repository-management' }
        @{ Path = 'tests/fixtures/TestTenant.ps1'; Expected = 'repository-management' }
        @{ Path = 'tests/fixtures/BicepIdentities.ps1'; Expected = 'repository-management' }
        @{ Path = 'tests/Pester/Helpers/ModuleCatalogFixture.ps1'; Expected = 'repository-management' }
        @{ Path = 'infra/main.tf'; Expected = 'repository-management' }
        @{ Path = '.github/workflows/repository-management-sync.yml'; Expected = 'workflows,repository-management' }
        @{ Path = '.github/workflows/repository-management-config-test.yml'; Expected = 'workflows,repository-management' }
        @{ Path = '.github/workflows/module-metadata-sync.yml'; Expected = 'workflows,repository-management' }
        @{ Path = 'tests/Pester/Unit/Module/TerraformInitUpgrade.Tests.ps1'; Expected = 'authoring,repository-management' }
        @{ Path = '.github/workflows/terraform-module.yml'; Expected = 'authoring,workflows,repository-management' }
        @{ Path = 'README.md'; Expected = '' }
        @{ Path = 'docs/quality-spec.md'; Expected = '' }
        @{ Path = 'CONTRIBUTING.md'; Expected = '' }
    ) {
        $result = Get-AvmCiScope -ChangedPath $Path
        ($result.Keys | Where-Object { $result[$_] }) -join ',' | Should -BeExactly $Expected
    }

    It 'runs all suites for shared dependency <Path>' -ForEach @(
        @{ Path = 'build.ps1' }
        @{ Path = 'build/avm.build.ps1' }
        @{ Path = 'build/AvmCi.ps1' }
        @{ Path = 'build/AvmPesterSharding.ps1' }
        @{ Path = 'build/Invoke-AvmPesterShard.ps1' }
        @{ Path = 'scripts/Get-AvmCiScope.ps1' }
        @{ Path = 'scripts/Install-AvmBuildPrerequisites.ps1' }
        @{ Path = 'scripts/Import-AvmNetworkRetry.ps1' }
        @{ Path = 'src/Avm.Authoring/Avm.Authoring.psd1' }
        @{ Path = 'src/Avm.Authoring/Avm.Authoring.psm1' }
        @{ Path = 'src/Avm.Authoring/Resources/avm.pins.jsonc' }
        @{ Path = 'src/Avm.Authoring/Private/Tools/Import-AvmPowerShellModule.ps1' }
        @{ Path = 'src/Avm.Authoring/Private/Network/Invoke-AvmRetry.ps1' }
        @{ Path = 'src/Avm.Authoring/Private/Process/Invoke-AvmProcess.ps1' }
        @{ Path = 'src/Avm.Authoring/Private/Output/Write-AvmLog.ps1' }
        @{ Path = 'tests/Pester/Import-AvmTestModule.ps1' }
        @{ Path = 'tests/Pester/Helpers/FutureSharedHelper.ps1' }
        @{ Path = '.github/workflows/ci.yml' }
        @{ Path = '.gitattributes' }
        @{ Path = '.gitignore' }
    ) {
        (Get-AvmCiScope -ChangedPath $Path).Values | Should -Be @($true, $true, $true)
    }

    It 'unions mixed paths including both sides of a cross-scope rename' {
        $result = Get-AvmCiScope -ChangedPath @(
            'tests/Pester/Unit/Public/Old.Tests.ps1',
            'tests/Pester/Unit/RepositoryManagement/New.Tests.ps1'
        )
        $result.Values | Should -Be @($true, $false, $true)
    }

    It 'handles local path separators without broadening repository-only changes' {
        (Get-AvmCiScope -ChangedPath 'tests\Pester\Component\RepositorySyncLogging.Component.Tests.ps1').Values |
            Should -Be @($false, $false, $true)
    }

    It 'skips all suites on an empty automatic diff and rejects malformed paths or scopes' {
        (Get-AvmCiScope -ChangedPath @()).Values | Should -Be @($false, $false, $false)
        { Get-AvmCiScope -ChangedPath @('') } | Should -Throw '*must not be empty*'
        { Get-AvmCiScope -Scope unknown } | Should -Throw
    }
}

Describe 'CI test inventory selection' {
    It 'keeps every local unit file and shares only the cross-repository init guard between CI unit groups' {
        $path = Join-Path $script:repoRoot 'tests' 'Pester' 'Unit'
        $all = @(Get-AvmScopedTestFile -Path $path -Tier Unit)
        $authoring = @(Get-AvmScopedTestFile -Path $path -Tier Unit -Group Authoring)
        $repositories = @(Get-AvmScopedTestFile -Path $path -Tier Unit -Group RepositoryManagement)
        $workflows = @(Get-ChildItem -LiteralPath (Join-Path $path 'Workflows') -Filter '*.Tests.ps1' -File -Recurse)
        $all.Count | Should -BeGreaterThan 0
        @($authoring | Where-Object { $_.FullName -in $repositories.FullName }).Name |
            Should -Be @('TerraformInitUpgrade.Tests.ps1')
        @($authoring + $repositories | Where-Object { $_.FullName -in $workflows.FullName }) | Should -HaveCount 0
        $combined = @(@($authoring + $repositories + $workflows).FullName | Sort-Object -Unique)
        @(Compare-Object $all.FullName $combined) | Should -HaveCount 0
        $repositories.Name | Should -Contain 'WorkflowFailureIssues.Tests.ps1'
        $authoring.Name | Should -Not -Contain 'WorkflowFailureIssues.Tests.ps1'
        $authoring.Name | Should -Contain 'ScriptAnalyzerRetry.Tests.ps1'
        $authoring.Name | Should -Contain 'Invoke-AvmProcess.Tests.ps1'
    }

    It 'partitions all component files including catalog and identity tests without overlap' {
        $path = Join-Path $script:repoRoot 'tests' 'Pester' 'Component'
        $all = @(Get-AvmScopedTestFile -Path $path -Tier Component)
        $authoring = @(Get-AvmScopedTestFile -Path $path -Tier Component -Group Authoring)
        $repositories = @(Get-AvmScopedTestFile -Path $path -Tier Component -Group RepositoryManagement)
        @($authoring | Where-Object { $_.FullName -in $repositories.FullName }) | Should -HaveCount 0
        @(Compare-Object $all.FullName @($authoring.FullName + $repositories.FullName)) | Should -HaveCount 0
        foreach ($name in @('BicepModuleIdentities.Component.Tests.ps1', 'BicepTestTenantSync.Component.Tests.ps1',
                'ModuleCatalog.Collection.Tests.ps1', 'RepositorySyncTerraform.Component.Tests.ps1', 'TerraformCodeowners.Component.Tests.ps1')) {
            $repositories.Name | Should -Contain $name
            $authoring.Name | Should -Not -Contain $name
        }
        $authoring.Name | Should -Contain 'TerraformRepositoryInitialization.Component.Tests.ps1'
        $authoring.Name | Should -Contain 'Register-AvmFeature.Component.Tests.ps1'
    }

    It 'includes newly added tests by scope rather than by test title' {
        $root = Join-Path $TestDrive 'Unit'
        foreach ($group in @('Public', 'RepositoryManagement', 'Workflows')) {
            $directory = Join-Path $root $group
            $null = New-Item -ItemType Directory -Path $directory -Force
            [System.IO.File]::WriteAllText((Join-Path $directory 'Future.Tests.ps1'), '')
        }
        @(Get-AvmScopedTestFile -Path $root -Tier Unit) | Should -HaveCount 3
        @(Get-AvmScopedTestFile -Path $root -Tier Unit -Group Authoring).Directory.Name | Should -Be @('Public')
        @(Get-AvmScopedTestFile -Path $root -Tier Unit -Group RepositoryManagement).Directory.Name |
            Should -Be @('RepositoryManagement')
    }

    It 'fails rather than succeeding with an empty selected inventory' {
        $empty = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $empty -Force
        { Get-AvmScopedTestFile -Path $empty -Tier Unit -Group Authoring } | Should -Throw '*No Unit test files*'
        { Get-AvmScopedTestFile -Path $empty -Tier Component -Group RepositoryManagement } |
            Should -Throw '*No Component test files*'
    }

    It 'passes the same file selections to serial Pester, coverage and the existing shard runner' {
        $build = Get-Content -LiteralPath (Join-Path $script:repoRoot 'build' 'avm.build.ps1') -Raw
        $build | Should -Match 'task ''pre-commit'' ''docs-check'', layout, lint, test, component'
        $build | Should -Match '\[string\] \$TestGroup = ''All'''
        $build | Should -Match '\$config.Run.Path\s+= @\(\$unitFiles.FullName\)'
        $build | Should -Match '\$config.Run.Path\s+= @\(\$componentFiles.FullName\)'
        $build | Should -Match 'Invoke-AvmPesterShardedTier -Tier ''unit'' -File \$unitFiles'
        $build | Should -Match '(?s)Invoke-AvmPesterShardedTier\s+`?\s+-Tier ''component''\s+`?\s+-File \$componentFiles'
        ([regex]::Matches($build, 'Get-AvmScopedTestFile -Path \$unitPath -Tier Unit -Group \$TestGroup')).Count |
            Should -Be 2
    }
}

Describe 'CI event selection' {
    BeforeAll {
        function Invoke-TestCiEvent {
            param([string] $Name, [hashtable] $Payload)
            $path = Join-Path $TestDrive 'event.json'
            $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
            & $script:selector -EventName $Name -EventPath $path
        }
    }

    BeforeEach {
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            if ($ArgumentList[0] -eq 'merge-base') {
                return [pscustomobject]@{ StdOut = (('a' * 40) + "`n") }
            }
            [pscustomobject]@{ StdOut = "repository-management/shared/TestTenant.ps1`0" }
        }
    }

    It 'defaults manual dispatch to all suites without inspecting a diff' {
        (Invoke-TestCiEvent -Name workflow_dispatch -Payload @{}).Values | Should -Be @($true, $true, $true)
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'honours the explicit manual <Scope> selection without a diff' -ForEach @(
        @{ Scope = 'authoring'; Expected = @($true, $false, $false) }
        @{ Scope = 'workflows'; Expected = @($false, $true, $false) }
        @{ Scope = 'repository-management'; Expected = @($false, $false, $true) }
        @{ Scope = 'all'; Expected = @($true, $true, $true) }
    ) {
        (Invoke-TestCiEvent -Name workflow_dispatch -Payload @{ inputs = @{ scope = $Scope } }).Values |
            Should -Be $Expected
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'compares the PR head with the merge base, not the synthetic merge commit' {
        $payload = @{ pull_request = @{ base = @{ sha = 'b' * 40 }; head = @{ sha = 'c' * 40 } } }
        (Invoke-TestCiEvent -Name pull_request -Payload $payload).Values | Should -Be @($false, $false, $true)
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            ($ArgumentList -join ' ') -ceq ('merge-base ' + ('b' * 40) + ' ' + ('c' * 40))
        }
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            ($ArgumentList -join ' ') -ceq (
                'diff --no-ext-diff --no-textconv --name-only -z --no-renames ' + ('a' * 40) + ' ' + ('c' * 40) + ' --')
        }
    }

    It 'compares every commit in a push with the previous tip and ignores manual-only inputs' {
        $payload = @{ before = 'b' * 40; after = 'c' * 40; inputs = @{ scope = 'all' } }
        (Invoke-TestCiEvent -Name push -Payload $payload).Values | Should -Be @($false, $false, $true)
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -ceq 'diff' -and $ArgumentList[-3] -ceq ('b' * 40) -and $ArgumentList[-2] -ceq ('c' * 40)
        }
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[0] -ceq 'merge-base'
        }
    }

    It 'runs everything on the first push with no previous tip' {
        (Invoke-TestCiEvent -Name push -Payload @{ before = '0' * 40; after = 'c' * 40 }).Values |
            Should -Be @($true, $true, $true)
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'does not truncate large diffs or split filenames on newlines' {
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            $paths = @(1..350 | ForEach-Object { "docs/file $_.md" })
            $paths += @("docs/line`nbreak.md", 'tests/Pester/Unit/Workflows/Future.Tests.ps1')
            [pscustomobject]@{ StdOut = ($paths -join "`0") + "`0" }
        }
        $paths = @(Get-AvmCiChangedPath -RepositoryRoot $script:repoRoot -Base ('b' * 40) -Head ('c' * 40))
        $paths | Should -HaveCount 352
        $paths[350] | Should -BeExactly "docs/line`nbreak.md"
        (Get-AvmCiScope -ChangedPath $paths).Values | Should -Be @($false, $true, $false)
    }

    It 'fails closed when git cannot establish the diff' {
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            throw [System.InvalidOperationException]::new('The base commit is unavailable.')
        }
        { Invoke-TestCiEvent -Name push -Payload @{ before = 'b' * 40; after = 'c' * 40 } } |
            Should -Throw '*base commit is unavailable*'
    }

    It 'rejects an invalid merge base, revision, manual auto selection, or event' {
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring { [pscustomobject]@{ StdOut = 'invalid' } }
        { Get-AvmCiChangedPath -RepositoryRoot $script:repoRoot -Base ('b' * 40) -Head ('c' * 40) -PullRequest } |
            Should -Throw '*one merge-base commit*'
        { Invoke-TestCiEvent -Name push -Payload @{ before = '--unsafe'; after = 'c' * 40 } } | Should -Throw
        { Invoke-TestCiEvent -Name workflow_dispatch -Payload @{ inputs = @{ scope = 'Auto' } } } |
            Should -Throw '*explicit scope*'
        { Invoke-TestCiEvent -Name pull_request_target -Payload @{} } | Should -Throw
    }
}

Describe 'Split CI workflow contract' {
    It 'always creates the dispatcher for main pushes and pull requests, with explicit manual choices' {
        $triggers = $script:definitions['ci.yml']['on']
        $triggers.Keys | Should -HaveCount 3
        foreach ($name in @('push', 'pull_request')) {
            $triggers[$name].branches | Should -Be @('main')
            $triggers[$name].Contains('paths') | Should -BeFalse
            $triggers[$name].Contains('paths-ignore') | Should -BeFalse
        }
        $scope = $triggers.workflow_dispatch.inputs.scope
        $scope.default | Should -BeExactly 'all'
        $scope.options | Should -Be @('all', 'authoring', 'workflows', 'repository-management')
    }

    It 'calls exactly the selected reusable workflows from the same commit' {
        $jobs = $script:definitions['ci.yml'].jobs
        $expected = @{
            authoring = 'ci-authoring.yml'
            workflows = 'ci-workflows.yml'
            'repository-management' = 'repository-management-config-test.yml'
        }
        foreach ($name in $expected.Keys) {
            $jobs[$name].needs | Should -Be 'changes'
            $jobs[$name]['if'] | Should -BeExactly "needs.changes.outputs.$name == 'true'"
            $jobs[$name].uses | Should -BeExactly "./.github/workflows/$($expected[$name])"
            @($script:definitions[$expected[$name]]['on'].Keys) | Should -Be @('workflow_call')
        }
        $jobs.changes.steps[0].with['fetch-depth'] | Should -Be 0
        $script:definitions['ci.yml'].concurrency['cancel-in-progress'] |
            Should -BeExactly '${{ github.event_name == ''pull_request'' }}'
    }

    It 'keeps the full repository-management matrix, configuration tests and mocked Terraform validation' {
        $jobs = $script:definitions['repository-management-config-test.yml'].jobs
        $jobs.pester.strategy.matrix.os | Should -Be @('ubuntu-latest', 'windows-latest', 'macos-latest')
        $jobs.pester.strategy.matrix.task | Should -Be @('test', 'component')
        $jobs.pester.strategy['fail-fast'] | Should -BeFalse
        @($jobs.pester.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) |
            Should -Contain './build.ps1 ${{ matrix.task }} -TestGroup RepositoryManagement'
        @($jobs.infra.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) |
            Should -Contain './build.ps1 infra,test-tenant-terraform'
        $scripts = ($jobs.test.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) -join "`n"
        foreach ($name in @('Test-RepositoryConfig', 'Test-AvmPreCommit', 'Test-ManagedFilesUpgrade', 'Test-RepositorySyncInputs', 'Test-TeamsAndUsers')) {
            $scripts | Should -Match ([regex]::Escape("$name.ps1"))
        }
    }

    It 'preserves PR/manual authoring integration while skipping both integration matrices on pushes' {
        foreach ($name in @('integration', 'bicep-integration')) {
            $script:definitions['ci-authoring.yml'].jobs[$name]['if'] | Should -BeExactly "github.event_name != 'push'"
        }
    }

    It 'retains safe permissions, checkout settings, action pins and startup settings across every split workflow' {
        foreach ($workflow in $script:definitions.Values) {
            $workflow.name | Should -Match '^[A-Za-z]+: .+'
            $workflow.permissions.contents | Should -BeExactly 'read'
            $workflow.env.DOTNET_MultiCoreJitMinNumCpus | Should -BeExactly '7fffffff'
            $workflow['on'].Contains('pull_request_target') | Should -BeFalse
            foreach ($job in $workflow.jobs.Values) {
                if (-not $job.Contains('steps')) { continue }
                foreach ($step in $job.steps) {
                    if (-not $step.Contains('uses')) { continue }
                    $step.uses | Should -Match '@[a-f0-9]{40}$'
                    if ($step.uses -clike 'actions/checkout@*') {
                        $step.with['persist-credentials'] | Should -BeFalse
                    }
                }
            }
        }
        $script:definitions['ci-workflows.yml'].permissions.Keys | Should -Be @('contents')
        $script:definitions['repository-management-config-test.yml'].permissions.Keys | Should -Be @('contents')
    }

    It 'reports all selected artifacts once and keeps a terminal CI result when every suite is skipped' {
        $jobs = $script:definitions['ci.yml'].jobs
        $jobs.report.name | Should -BeExactly 'CI result'
        $jobs.report.needs | Should -Be @('changes', 'authoring', 'workflows', 'repository-management')
        $jobs.report['if'] | Should -BeExactly '${{ !cancelled() }}'
        $jobs.report.Contains('environment') | Should -BeFalse
        $jobs.report.permissions.Contains('id-token') | Should -BeFalse
        @($jobs.report.steps | Where-Object { $_.Contains('uses') -and $_.uses -clike 'actions/checkout@*' }) |
            Should -HaveCount 0
        $jobs.report.steps[0].with.pattern | Should -BeExactly 'test-results-*'
        $jobs.report.steps[1].with.report_individual_runs | Should -BeExactly 'true'
        foreach ($step in @($jobs.report.steps[0], $jobs.report.steps[1])) {
            foreach ($name in @('authoring', 'workflows', 'repository-management')) {
                $step['if'] | Should -Match ([regex]::Escape("needs.changes.outputs.$name == 'true'"))
            }
        }
        $artifactNames = foreach ($workflow in $script:definitions.Values) {
            foreach ($job in $workflow.jobs.Values) {
                if (-not $job.Contains('steps')) { continue }
                foreach ($step in $job.steps) {
                    if ($step.Contains('uses') -and $step.uses -clike 'actions/upload-artifact@*') {
                        $step['if'] | Should -BeExactly 'always()'
                        $step.with.name
                    }
                }
            }
        }
        $artifactNames | Should -HaveCount 6
        @($artifactNames | Sort-Object -Unique) | Should -HaveCount 6
    }
}

Describe 'CI result enforcement' {
    BeforeAll {
        $script:verify = [scriptblock]::Create($script:definitions['ci.yml'].jobs.report.steps[-1].run)
    }

    BeforeEach {
        $script:previousNeeds = $env:CI_NEEDS
        $script:previousSummary = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'summary.md'
        $script:needs = @{
            changes = @{
                result = 'success'
                outputs = @{ authoring = 'false'; workflows = 'false'; 'repository-management' = 'false' }
            }
            authoring = @{ result = 'skipped' }
            workflows = @{ result = 'skipped' }
            'repository-management' = @{ result = 'skipped' }
        }
    }

    AfterEach {
        $env:CI_NEEDS = $script:previousNeeds
        $env:GITHUB_STEP_SUMMARY = $script:previousSummary
    }

    It 'succeeds with a summary when no suites are relevant' {
        $env:CI_NEEDS = $script:needs | ConvertTo-Json -Depth 5
        { & $script:verify } | Should -Not -Throw
        @(Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY) | Should -HaveCount 3
    }

    It 'accepts a selected suite only when it succeeds' {
        $script:needs.changes.outputs['repository-management'] = 'true'
        $script:needs['repository-management'].result = 'success'
        $env:CI_NEEDS = $script:needs | ConvertTo-Json -Depth 5
        { & $script:verify } | Should -Not -Throw
    }

    It 'rejects a selected suite with result <_>' -ForEach @('failure', 'cancelled', 'skipped') {
        $script:needs.changes.outputs.authoring = 'true'
        $script:needs.authoring.result = $_
        $env:CI_NEEDS = $script:needs | ConvertTo-Json -Depth 5
        { & $script:verify } | Should -Throw '*authoring*'
    }

    It 'fails when scope selection fails or omits an output' {
        $script:needs.changes.result = 'failure'
        $env:CI_NEEDS = $script:needs | ConvertTo-Json -Depth 5
        { & $script:verify } | Should -Throw '*could not determine*'
        $script:needs.changes.result = 'success'
        $script:needs.changes.outputs.workflows = ''
        $env:CI_NEEDS = $script:needs | ConvertTo-Json -Depth 5
        { & $script:verify } | Should -Throw '*workflows*'
    }
}
