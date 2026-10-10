#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:repoRoot 'build' 'avm.build.ps1'), [ref]$tokens, [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'script:Get-AvmScopedTestFile'
    }, $true)
    $definition | Should -Not -BeNullOrEmpty
    . ([scriptblock]::Create($definition.Extent.Text))
    $module = Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru
    $null = & $module { Import-AvmPowerShellModule -Name powershell-yaml -Global }
    $script:definitions = @{}
    foreach ($workflowFile in @('ci-authoring.yml', 'ci-workflows.yml', 'repository-management-config-test.yml')) {
        $text = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github' 'workflows' $workflowFile) -Raw
        $script:definitions[$workflowFile] = ConvertFrom-Yaml -Yaml $text
    }
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Independent CI workflows' {
    It 'uses matching native path filters for main pushes and pull requests, with independent manual dispatch' {
        foreach ($workflow in $script:definitions.Values) {
            $triggers = $workflow['on']
            @($triggers.Keys | Sort-Object) | Should -Be @('pull_request', 'push', 'workflow_dispatch')
            foreach ($eventName in @('push', 'pull_request')) {
                $triggers[$eventName].branches | Should -Be @('main')
                $triggers[$eventName].paths.Count | Should -BeGreaterThan 0
                $triggers[$eventName].Contains('paths-ignore') | Should -BeFalse
            }
            $triggers.push.paths | Should -Be $triggers.pull_request.paths
            $triggers.workflow_dispatch | Should -BeNullOrEmpty
            $workflow.concurrency.group | Should -BeExactly 'ci-${{ github.workflow }}-${{ github.ref }}'
            $workflow.concurrency['cancel-in-progress'] | Should -BeExactly '${{ github.event_name == ''pull_request'' }}'
            foreach ($job in $workflow.jobs.Values) {
                $job.Contains('uses') | Should -BeFalse
            }
        }
        foreach ($removed in @('.github/workflows/ci.yml', 'scripts/Get-AvmCiScope.ps1', 'build/AvmCi.ps1')) {
            Test-Path -LiteralPath (Join-Path $script:repoRoot $removed) | Should -BeFalse
        }
    }

    It 'includes source, tests and shared dependencies in the static filters for <File>' -ForEach @(
        @{ File = 'ci-authoring.yml'; Required = @(
            'src/Avm.Authoring/**', 'build/**', 'build.ps1', 'scripts/**', 'tests/**', 'docs/reference/**',
            '.github/workflows/ci-authoring.yml', '.github/workflows/terraform-module.yml', '.github/workflows/release.yml'
        ) }
        @{ File = 'ci-workflows.yml'; Required = @(
            '.github/workflows/**', '.github/dependabot.yml', 'tests/Pester/Unit/Workflows/**',
            'tests/Pester/Import-AvmTestModule.ps1', 'build/**', 'build.ps1',
            'scripts/Install-AvmBuildPrerequisites.ps1', 'scripts/Import-AvmNetworkRetry.ps1',
            'src/Avm.Authoring/Avm.Authoring.psd1', 'src/Avm.Authoring/Avm.Authoring.psm1',
            'src/Avm.Authoring/Resources/**', 'src/Avm.Authoring/Private/Tools/**',
            'src/Avm.Authoring/Private/Network/**', 'src/Avm.Authoring/Private/Process/**',
            'src/Avm.Authoring/Private/Output/**'
        ) }
        @{ File = 'repository-management-config-test.yml'; Required = @(
            'repository-management/**', 'infra/**', 'src/Avm.Authoring/**', 'build/**', 'build.ps1',
            'scripts/Install-AvmBuildPrerequisites.ps1', 'scripts/Import-AvmNetworkRetry.ps1',
            'tests/Pester/Unit/RepositoryManagement/**', 'tests/Pester/Unit/Module/TerraformInitUpgrade.Tests.ps1',
            'tests/Pester/Component/BicepModuleIdentities*.Tests.ps1', 'tests/Pester/Component/BicepTestTenantSync*.Tests.ps1',
            'tests/Pester/Component/ModuleCatalog*.Tests.ps1', 'tests/Pester/Component/Repository*.Tests.ps1',
            'tests/Pester/Component/TerraformCodeowners*.Tests.ps1', 'tests/Pester/Helpers/ModuleCatalogFixture.ps1',
            'tests/Pester/Import-AvmTestModule.ps1', 'tests/fixtures/TestTenant.ps1', 'tests/fixtures/BicepIdentities.ps1',
            '.github/workflows/repository-management-*.yml', '.github/workflows/module-metadata-sync.yml',
            '.github/workflows/terraform-module.yml'
        ) }
    ) {
        $paths = $script:definitions[$File]['on'].push.paths
        foreach ($pattern in @($Required) + @('.github/actions/**', '.gitattributes', '.gitignore')) {
            $paths | Should -Contain $pattern
        }
        $paths | Should -Not -Contain '**'
        $paths | Should -Not -Contain 'docs/**'
        $paths | Should -Not -Contain 'README.md'
        $paths | Should -Not -Contain 'docs/quality-spec.md'
    }

    It 'excludes unrelated test groups from authoring after its positive tests filter' {
        $paths = $script:definitions['ci-authoring.yml']['on'].push.paths
        foreach ($excluded in @(
            'tests/Pester/Unit/RepositoryManagement/**', 'tests/Pester/Unit/Workflows/**',
            'tests/Pester/Component/BicepModuleIdentities*.Tests.ps1', 'tests/Pester/Component/BicepTestTenantSync*.Tests.ps1',
            'tests/Pester/Component/ModuleCatalog*.Tests.ps1', 'tests/Pester/Component/Repository*.Tests.ps1',
            'tests/Pester/Component/TerraformCodeowners*.Tests.ps1', 'tests/Pester/Helpers/ModuleCatalogFixture.ps1',
            'tests/fixtures/TestTenant.ps1', 'tests/fixtures/BicepIdentities.ps1'
        )) {
            $paths.IndexOf("!$excluded") | Should -BeGreaterThan $paths.IndexOf('tests/**')
        }
        $paths | Should -Not -Contain 'repository-management/**'
        $paths | Should -Not -Contain 'infra/**'
        foreach ($file in @('ci-workflows.yml', 'repository-management-config-test.yml')) {
            $script:definitions[$file]['on'].push.paths | Should -Not -Contain 'tests/**'
        }
    }

    It 'runs every workflow-test and repository-management job on Ubuntu without an OS matrix' {
        foreach ($file in @('ci-workflows.yml', 'repository-management-config-test.yml')) {
            foreach ($job in $script:definitions[$file].jobs.Values) {
                $job['runs-on'] | Should -BeExactly 'ubuntu-latest'
                $job.Contains('strategy') | Should -BeFalse
                $job.Contains('environment') | Should -BeFalse
            }
        }
        $jobs = $script:definitions['repository-management-config-test.yml'].jobs
        @($jobs.Keys | Sort-Object) | Should -Be @('infra', 'pester', 'report', 'test')
        @($jobs.pester.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) |
            Should -Contain './build.ps1 test,component -TestGroup RepositoryManagement'
        @($jobs.infra.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) |
            Should -Contain './build.ps1 infra,test-tenant-terraform'
        $scripts = ($jobs.test.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) -join "`n"
        foreach ($name in @('Test-RepositoryConfig', 'Test-AvmPreCommit', 'Test-ManagedFilesUpgrade', 'Test-RepositorySyncInputs', 'Test-TeamsAndUsers')) {
            $scripts | Should -Match ([regex]::Escape("$name.ps1"))
        }
        $workflowJobs = $script:definitions['ci-workflows.yml'].jobs
        @($workflowJobs.Keys | Sort-Object) | Should -Be @('report', 'workflows')
        @($workflowJobs.workflows.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) |
            Should -Contain './build.ps1 test-workflows'
    }

    It 'preserves only the existing authoring unit, component and integration matrices' {
        $jobs = $script:definitions['ci-authoring.yml'].jobs
        @($jobs.Keys | Sort-Object) | Should -Be @('bicep-integration', 'component', 'integration', 'lint', 'report', 'unit')
        @($jobs.unit.strategy.matrix.include.os) | Should -Be @('ubuntu-latest', 'windows-latest', 'macos-latest')
        @($jobs.unit.strategy.matrix.include.task) | Should -Be @('ci-coverage', 'ci-unit', 'ci-unit')
        foreach ($jobName in @('component', 'integration', 'bicep-integration')) {
            $jobs[$jobName].strategy.matrix.os | Should -Be @('ubuntu-latest', 'windows-latest', 'macos-latest')
            $jobs[$jobName]['runs-on'] | Should -BeExactly '${{ matrix.os }}'
        }
        foreach ($jobName in @('integration', 'bicep-integration')) {
            $jobs[$jobName]['if'] | Should -BeExactly "github.event_name != 'push'"
        }
        $jobs.integration.strategy.matrix.fixture |
            Should -Be @('terraform-azure-avm-res-mock', 'terraform-azurerm-avm-res-mock')
        $jobs.lint['runs-on'] | Should -BeExactly 'ubuntu-latest'
    }

    It 'keeps reports and artifacts inside their own independent workflow' {
        $reports = @{
            'ci-authoring.yml' = @{ Needs = @('unit', 'component', 'integration', 'bicep-integration'); Name = 'Authoring test results' }
            'ci-workflows.yml' = @{ Needs = @('workflows'); Name = 'Workflow test results' }
            'repository-management-config-test.yml' = @{ Needs = @('pester'); Name = 'Repository test results' }
        }
        foreach ($file in $reports.Keys) {
            $report = $script:definitions[$file].jobs.report
            @($report.needs) | Should -Be $reports[$file].Needs
            $report['if'] | Should -BeExactly '${{ !cancelled() }}'
            $report.permissions.checks | Should -BeExactly 'write'
            $report.permissions['pull-requests'] | Should -BeExactly 'write'
            $report.permissions.Contains('id-token') | Should -BeFalse
            $report.steps | Should -HaveCount 2
            $report.steps[0].uses | Should -Match '^actions/download-artifact@'
            $report.steps[0].with.Contains('run-id') | Should -BeFalse
            $report.steps[1].uses | Should -Match '^EnricoMi/publish-unit-test-result-action@'
            $report.steps[1].with.check_name | Should -BeExactly $reports[$file].Name
            $report.steps[1].with.comment_title | Should -BeExactly $reports[$file].Name
            $report.steps[1].with.files | Should -BeExactly 'artifacts/**/*.xml'
            $report.steps[1].with.report_individual_runs | Should -BeExactly 'true'
        }
        $script:definitions['ci-authoring.yml'].jobs.report.steps[0].with.pattern | Should -BeExactly 'test-results-*'
        foreach ($file in @('ci-workflows.yml', 'repository-management-config-test.yml')) {
            $jobs = $script:definitions[$file].jobs
            $uploads = @($jobs.Values.steps | Where-Object { $_.Contains('uses') -and $_.uses -clike 'actions/upload-artifact@*' })
            $uploads | Should -HaveCount 1
            $jobs.report.steps[0].with.name | Should -BeExactly $uploads[0].with.name
        }
    }

    It 'retains read-only test defaults, action pins, checkout isolation and startup settings' {
        foreach ($workflow in $script:definitions.Values) {
            $workflow.name | Should -Match '^[A-Za-z]+: .+'
            @($workflow.permissions.Keys) | Should -Be @('contents')
            $workflow.permissions.contents | Should -BeExactly 'read'
            $workflow.env.DOTNET_MultiCoreJitMinNumCpus | Should -BeExactly '7fffffff'
            foreach ($job in $workflow.jobs.Values) {
                foreach ($step in $job.steps) {
                    if (-not $step.Contains('uses')) { continue }
                    $step.uses | Should -Match '@[a-f0-9]{40}$'
                    if ($step.uses -clike 'actions/checkout@*') {
                        $step.with['persist-credentials'] | Should -BeFalse
                    }
                    if ($step.uses -clike 'actions/upload-artifact@*') {
                        $step['if'] | Should -BeExactly 'always()'
                    }
                }
            }
        }
    }
}

Describe 'CI test inventory selection' {
    It 'keeps every local unit file and shares only the init guard between authoring and repository groups' {
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
        $authoring.Name | Should -Contain 'ScriptAnalyzerRetry.Tests.ps1'
        $authoring.Name | Should -Contain 'Invoke-AvmProcess.Tests.ps1'
    }

    It 'partitions all component files including catalog, identity and lock recovery tests without overlap' {
        $path = Join-Path $script:repoRoot 'tests' 'Pester' 'Component'
        $all = @(Get-AvmScopedTestFile -Path $path -Tier Component)
        $authoring = @(Get-AvmScopedTestFile -Path $path -Tier Component -Group Authoring)
        $repositories = @(Get-AvmScopedTestFile -Path $path -Tier Component -Group RepositoryManagement)
        @($authoring | Where-Object { $_.FullName -in $repositories.FullName }) | Should -HaveCount 0
        @(Compare-Object $all.FullName @($authoring.FullName + $repositories.FullName)) | Should -HaveCount 0
        foreach ($name in @('BicepModuleIdentities.Component.Tests.ps1', 'BicepTestTenantSync.Component.Tests.ps1',
            'ModuleCatalog.Collection.Tests.ps1', 'RepositorySyncTerraform.Component.Tests.ps1',
            'RepositorySyncStateLock.Component.Tests.ps1', 'TerraformCodeowners.Component.Tests.ps1')) {
            $repositories.Name | Should -Contain $name
            $authoring.Name | Should -Not -Contain $name
        }
        $authoring.Name | Should -Contain 'TerraformRepositoryInitialization.Component.Tests.ps1'
    }

    It 'includes newly added files by test group without depending on test titles' {
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

    It 'preserves the complete local gate and identical serial, coverage and shard selections' {
        $build = Get-Content -LiteralPath (Join-Path $script:repoRoot 'build' 'avm.build.ps1') -Raw
        $build | Should -Match 'task ''pre-commit'' ''docs-check'', layout, lint, test, component'
        $build | Should -Match '\[string\] \$TestGroup = ''All'''
        $build | Should -Match '\$config.Run.Path\s+= @\(\$unitFiles.FullName\)'
        $build | Should -Match '\$config.Run.Path\s+= @\(\$componentFiles.FullName\)'
        $build | Should -Match 'Invoke-AvmPesterShardedTier -Tier ''unit'' -File \$unitFiles'
        $build | Should -Match '(?s)Invoke-AvmPesterShardedTier\s+`?\s+-Tier ''component''\s+`?\s+-File \$componentFiles'
        ([regex]::Matches($build, 'Get-AvmScopedTestFile -Path \$unitPath -Tier Unit -Group \$TestGroup')).Count |
            Should -Be 2
        $build | Should -Not -Match 'Get-AvmCiScope|Get-AvmCiChangedPath|AvmCi\.ps1'
    }
}
