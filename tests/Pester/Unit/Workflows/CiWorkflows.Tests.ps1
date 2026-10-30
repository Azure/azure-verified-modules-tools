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
    foreach ($workflowFile in @('ci-authoring.yml', 'ci-package-qualification.yml', 'ci-workflows.yml', 'repository-management-config-test.yml')) {
        $text = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github' 'workflows' $workflowFile) -Raw
        $script:definitions[$workflowFile] = ConvertFrom-Yaml -Yaml $text
    }
    $script:testWorkflowPathSelection = {
        param(
            [Parameter(Mandatory)] [string[]] $Patterns,
            [Parameter(Mandatory)] [string] $Path
        )

        $selected = $false
        foreach ($pattern in $Patterns) {
            $excluded = $pattern.StartsWith('!')
            $candidate = if ($excluded) { $pattern.Substring(1) } else { $pattern }
            if ($Path -clike $candidate) {
                $selected = -not $excluded
            }
        }
        $selected
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
            'src/Avm.Authoring/**', 'build/**', 'build.ps1', 'scripts/Generate-AvmCmdletDocumentation.ps1',
            'tests/**', 'docs/reference/**',
            'repository-management/shared/TestTenant.ps1', 'repository-management/shared/GroupSettings.ps1',
            '.gitattributes', '.gitignore'
        ) }
        @{ File = 'ci-workflows.yml'; Required = @(
            '.github/workflows/**', '.github/dependabot.yml', 'tests/Pester/Unit/Workflows/**',
            'tests/Pester/Unit/Scripts/Install-AvmBuildPrerequisites.Tests.ps1',
            'tests/Pester/Component/AuthoringBootstrap.Component.Tests.ps1',
            'tests/Pester/Component/BicepWorkflowBootstrap.Component.Tests.ps1',
            'tests/Pester/Import-AvmTestModule.ps1', 'build/**', 'build.ps1',
            'scripts/Install-AvmBuildPrerequisites.ps1', 'scripts/Import-AvmNetworkRetry.ps1',
            'scripts/bicep-workflows/**', 'repository-management/shared/TestTenant.ps1',
            'repository-management/shared/GroupSettings.ps1',
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
            'tests/fixtures/repository-candidate-process.ps1',
            '.github/workflows/repository-management-*.yml', '.github/workflows/module-metadata-sync.yml',
            '.github/workflows/terraform-module.yml', '.gitattributes', '.gitignore'
        ) }
    ) {
        $paths = $script:definitions[$File]['on'].push.paths
        foreach ($pattern in $Required) {
            $paths | Should -Contain $pattern
        }
        $paths | Should -Not -Contain '**'
        $paths | Should -Not -Contain 'docs/**'
        $paths | Should -Not -Contain 'README.md'
        $paths | Should -Not -Contain 'docs/quality-spec.md'
    }

    It 'routes module, workflow and repository changes to their owned CI suites' {
        $routes = @(
            @{ Name = 'Authoring'; File = 'ci-authoring.yml' }
            @{ Name = 'Workflows'; File = 'ci-workflows.yml' }
            @{ Name = 'Repos'; File = 'repository-management-config-test.yml' }
        )
        $testCases = @(
            @{ Path = 'src/Avm.Authoring/Public/Invoke-Avm.ps1'; Expected = @('Authoring', 'Repos') }
            @{ Path = '.github/actions/install-avm-authoring/Install-AvmAuthoring.ps1'; Expected = @('Workflows') }
            @{ Path = '.github/workflows/ci-authoring.yml'; Expected = @('Workflows') }
            @{ Path = 'scripts/bicep-workflows/Common.ps1'; Expected = @('Workflows') }
            @{ Path = 'tests/Pester/Component/AuthoringBootstrap.Component.Tests.ps1'; Expected = @('Workflows') }
            @{ Path = 'tests/Pester/Unit/Scripts/Install-AvmBuildPrerequisites.Tests.ps1'; Expected = @('Workflows') }
            @{ Path = 'tests/Pester/Unit/Private/Config/Get-AvmConfig.Tests.ps1'; Expected = @('Authoring') }
            @{ Path = 'build/avm.build.ps1'; Expected = @('Authoring', 'Workflows', 'Repos') }
            @{ Path = 'docs/reference/Invoke-Avm.md'; Expected = @('Authoring') }
            @{ Path = 'repository-management/repository-sync/scripts/Test-RepositoryConfig.ps1'; Expected = @('Repos') }
        )

        foreach ($testCase in $testCases) {
            foreach ($eventName in @('push', 'pull_request')) {
                $selected = @(
                    foreach ($route in $routes) {
                        $patterns = $script:definitions[$route.File]['on'][$eventName].paths
                        if (& $script:testWorkflowPathSelection -Patterns $patterns -Path $testCase.Path) {
                            $route.Name
                        }
                    }
                )
                $selected | Should -Be $testCase.Expected
            }
        }
    }

    It 'excludes unrelated test groups from authoring after its positive tests filter' {
        $paths = $script:definitions['ci-authoring.yml']['on'].push.paths
        foreach ($excluded in @(
            'tests/Pester/Unit/RepositoryManagement/**', 'tests/Pester/Unit/Workflows/**',
            'tests/Pester/Unit/Scripts/Install-AvmBuildPrerequisites.Tests.ps1',
            'tests/Pester/Component/AuthoringBootstrap.Component.Tests.ps1',
            'tests/Pester/Component/BicepWorkflowBootstrap.Component.Tests.ps1',
            'tests/Pester/Component/BicepModuleIdentities*.Tests.ps1', 'tests/Pester/Component/BicepTestTenantSync*.Tests.ps1',
            'tests/Pester/Component/ModuleCatalog*.Tests.ps1', 'tests/Pester/Component/Repository*.Tests.ps1',
            'tests/Pester/Component/TerraformCodeowners*.Tests.ps1', 'tests/Pester/Helpers/ModuleCatalogFixture.ps1',
            'tests/fixtures/TestTenant.ps1', 'tests/fixtures/BicepIdentities.ps1',
            'tests/fixtures/repository-candidate-process.ps1'
        )) {
            $paths.IndexOf("!$excluded") | Should -BeGreaterThan $paths.IndexOf('tests/**')
        }
        $paths | Should -Not -Contain 'repository-management/**'
        $paths | Should -Not -Contain 'scripts/**'
        $paths | Should -Not -Contain '.github/actions/**'
        $paths | Should -Not -Contain '.github/workflows/ci-authoring.yml'
        $paths | Should -Not -Contain '.github/workflows/release.yml'
        @($paths | Where-Object { $_ -like 'repository-management/*' } | Sort-Object) |
            Should -Be @('repository-management/shared/GroupSettings.ps1', 'repository-management/shared/TestTenant.ps1')
        $paths | Should -Not -Contain 'infra/**'
        $paths | Should -Not -Contain '.github/workflows/terraform-module.yml'
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

    It 'preserves cross-platform acceptance and separates native compatibility from fixture matrices' {
        $jobs = $script:definitions['ci-authoring.yml'].jobs
        @($jobs.Keys | Sort-Object) | Should -Be @('bicep-integration', 'component', 'integration', 'lint', 'native-qualification', 'report', 'unit')
        @($jobs.unit.strategy.matrix.include.os) | Should -Be @('ubuntu-latest', 'windows-latest', 'macos-latest')
        @($jobs.unit.strategy.matrix.include.task) | Should -Be @('ci-coverage', 'ci-unit', 'ci-unit')
        foreach ($jobName in @('component', 'integration', 'bicep-integration', 'native-qualification')) {
            $jobs[$jobName].strategy.matrix.os | Should -Be @('ubuntu-latest', 'windows-latest', 'macos-latest')
            $jobs[$jobName]['runs-on'] | Should -BeExactly '${{ matrix.os }}'
        }
        foreach ($jobName in @('integration', 'bicep-integration', 'native-qualification')) {
            $jobs[$jobName]['if'] | Should -BeExactly "github.event_name != 'push'"
        }
        $jobs.integration.strategy.matrix.fixture |
            Should -Be @('terraform-azure-avm-res-mock', 'terraform-azurerm-avm-res-mock')
        $jobs.lint['runs-on'] | Should -BeExactly 'ubuntu-latest'
        $jobs.integration['timeout-minutes'] | Should -Be 30
        $native = $jobs['native-qualification']
        $native['timeout-minutes'] | Should -Be 30
        $native.strategy.matrix.Contains('fixture') | Should -BeFalse
        $native.Contains('environment') | Should -BeFalse
        $native.env.ARM_USE_OIDC | Should -BeExactly 'false'
        $native.env.MODTM_ENDPOINT | Should -BeExactly 'http://127.0.0.1:1'
        @($native.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) |
            Should -Contain './build.ps1 qualification -QualificationGroup Native'
    }

    It 'qualifies packages on relevant changes without Azure access or a module fixture matrix' {
        $workflow = $script:definitions['ci-package-qualification.yml']
        $paths = $workflow['on'].pull_request.paths
        foreach ($path in @(
                'src/Avm.Authoring/Resources/avm.pins.jsonc',
                'src/Avm.Authoring/Private/Tools/**',
                'src/Avm.Authoring/Private/Network/**',
                'tests/Pester/Qualification/Package/**',
                '.github/workflows/release.yml', 'build.ps1', 'build/**'
            )) {
            $paths | Should -Contain $path
        }
        $paths | Should -Not -Contain 'src/Avm.Authoring/**'
        $package = $workflow.jobs.package
        $package.strategy.matrix.os | Should -Be @('ubuntu-latest', 'windows-latest', 'macos-latest')
        $package.strategy.matrix.Contains('fixture') | Should -BeFalse
        $package.Contains('environment') | Should -BeFalse
        $package.Contains('permissions') | Should -BeFalse
        $package.env.ARM_USE_OIDC | Should -BeExactly 'false'
        ($package.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) -join "`n" |
            Should -Match 'build[.]ps1 qualification -QualificationGroup Package'
    }

    It 'admits packaged Bicep policy changes at <File> without broadening unrelated paths' -ForEach @(
        @{ File = 'src/Avm.Authoring/Engines/Bicep/Get-AvmBicepPolicyTestFile.ps1' }
        @{ File = 'src/Avm.Authoring/Engines/Bicep/Invoke-AvmBicepCheckPolicy.ps1' }
        @{ File = 'src/Avm.Authoring/Public/Invoke-AvmCheckPolicy.ps1' }
    ) {
        Test-Path -LiteralPath (Join-Path $script:repoRoot $File) | Should -BeTrue
        foreach ($eventName in @('push', 'pull_request')) {
            $paths = $script:definitions['ci-package-qualification.yml']['on'][$eventName].paths
            @($paths | Where-Object { $File -clike $_ }) | Should -Be @($File)
            foreach ($unrelated in @('README.md', 'docs/quality-spec.md', 'repository-management/repository-config/config.json')) {
                @($paths | Where-Object { $unrelated -clike $_ }) | Should -BeNullOrEmpty
            }
        }
    }

    It 'uses the repository-sync executor <Variable> in both provider and login settings' -ForEach @(
        @{ Name = 'ARM_CLIENT_ID'; LoginInput = 'client-id'; Variable = 'TEST_BAMI_CONTROLLER_CLIENT_ID' }
        @{ Name = 'ARM_TENANT_ID'; LoginInput = 'tenant-id'; Variable = 'TEST_BAMI_TENANT_ID' }
        @{ Name = 'ARM_SUBSCRIPTION_ID'; LoginInput = 'subscription-id'; Variable = 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID' }
    ) {
        $job = $script:definitions['ci-authoring.yml'].jobs.integration
        $login = @($job.steps | Where-Object { $_.Contains('uses') -and $_.uses -clike 'azure/login@*' })
        $login | Should -HaveCount 1
        $expected = '${{ vars.' + $Variable + ' }}'
        $job.env[$Name] | Should -BeExactly $expected
        $login[0].with[$LoginInput] | Should -BeExactly $expected
    }

    It 'requires authoring OIDC without backend, module identity or test-pool substitutions' {
        $job = $script:definitions['ci-authoring.yml'].jobs.integration
        $job.environment | Should -BeExactly 'avm'
        $job.permissions['id-token'] | Should -BeExactly 'write'
        $job.env.ARM_USE_OIDC | Should -BeExactly 'true'
        $job.env.ARM_USE_CLI | Should -BeExactly 'false'
        $job.env.ARM_USE_MSI | Should -BeExactly 'false'
        $login = @($job.steps | Where-Object { $_.Contains('uses') -and $_.uses -clike 'azure/login@*' })
        $login | Should -HaveCount 1
        $login[0].Contains('if') | Should -BeFalse
        $job.strategy['fail-fast'] | Should -BeFalse
        $job | ConvertTo-Json -Depth 30 |
            Should -Not -Match 'vars\.ARM_(CLIENT|TENANT|SUBSCRIPTION)_ID|ARM_BACKEND_|TEST_BAMI_(BICEP_CLIENT_ID|SUBSCRIPTION_IDS|PERSISTENT_SUBSCRIPTION_ID|AUTHORING_)|Get-AvmGeneralTestSubscription|test-subscription'
        @($job.steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run }) |
            Should -Contain './build.ps1 integration -IntegrationGroup Terraform'
    }

    It 'keeps reports and artifacts inside their own independent workflow' {
        $reports = @{
            'ci-authoring.yml' = @{ Needs = @('unit', 'component', 'integration', 'bicep-integration', 'native-qualification'); Name = 'Authoring test results' }
            'ci-package-qualification.yml' = @{ Needs = @('package'); Name = 'Package qualification results' }
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
        $workflows = @(Get-AvmScopedTestFile -Path $path -Tier Unit -Group Workflows)
        $all.Count | Should -BeGreaterThan 0
        @($authoring | Where-Object { $_.FullName -in $repositories.FullName }).Name |
            Should -Be @('TerraformInitUpgrade.Tests.ps1')
        @($authoring + $repositories | Where-Object { $_.FullName -in $workflows.FullName }) | Should -HaveCount 0
        $combined = @(@($authoring + $repositories + $workflows).FullName | Sort-Object -Unique)
        @(Compare-Object $all.FullName $combined) | Should -HaveCount 0
        $repositories.Name | Should -Contain 'WorkflowFailureIssues.Tests.ps1'
        $authoring.Name | Should -Contain 'ScriptAnalyzerRetry.Tests.ps1'
        $authoring.Name | Should -Contain 'Invoke-AvmProcess.Tests.ps1'
        $workflows.Name | Should -Contain 'Install-AvmBuildPrerequisites.Tests.ps1'
    }

    It 'partitions all component files including workflow bootstrap tests without overlap' {
        $path = Join-Path $script:repoRoot 'tests' 'Pester' 'Component'
        $all = @(Get-AvmScopedTestFile -Path $path -Tier Component)
        $authoring = @(Get-AvmScopedTestFile -Path $path -Tier Component -Group Authoring)
        $repositories = @(Get-AvmScopedTestFile -Path $path -Tier Component -Group RepositoryManagement)
        $workflows = @(Get-AvmScopedTestFile -Path $path -Tier Component -Group Workflows)
        @($authoring | Where-Object { $_.FullName -in $repositories.FullName }) | Should -HaveCount 0
        @($authoring + $repositories | Where-Object { $_.FullName -in $workflows.FullName }) | Should -HaveCount 0
        @(Compare-Object $all.FullName @($authoring.FullName + $repositories.FullName + $workflows.FullName)) | Should -HaveCount 0
        foreach ($name in @('BicepModuleIdentities.Component.Tests.ps1', 'BicepTestTenantSync.Component.Tests.ps1',
            'ModuleCatalog.Collection.Tests.ps1', 'RepositorySyncTerraform.Component.Tests.ps1',
            'RepositorySyncStateLock.Component.Tests.ps1', 'TerraformCodeowners.Component.Tests.ps1')) {
            $repositories.Name | Should -Contain $name
            $authoring.Name | Should -Not -Contain $name
        }
        $authoring.Name | Should -Contain 'TerraformRepositoryInitialization.Component.Tests.ps1'
        $workflows.Name | Should -Be @('AuthoringBootstrap.Component.Tests.ps1', 'BicepWorkflowBootstrap.Component.Tests.ps1')
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
        @(Get-AvmScopedTestFile -Path $root -Tier Unit -Group Workflows).Directory.Name |
            Should -Be @('Workflows')
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
        $build | Should -Match 'Get-AvmScopedTestFile -Path \(Join-Path \$script:testsRoot ''Unit''\) -Tier Unit -Group Workflows'
        $build | Should -Match 'Get-AvmScopedTestFile -Path \(Join-Path \$script:testsRoot ''Component''\) -Tier Component -Group Workflows'
        $build | Should -Match 'Invoke-AvmPesterShardedTier -Tier ''unit'' -File \$unitFiles'
        $build | Should -Match '(?s)Invoke-AvmPesterShardedTier\s+`?\s+-Tier ''component''\s+`?\s+-File \$componentFiles'
        ([regex]::Matches($build, 'Get-AvmScopedTestFile -Path \$unitPath -Tier Unit -Group \$TestGroup')).Count |
            Should -Be 2
        $build | Should -Not -Match 'Get-AvmCiScope|Get-AvmCiChangedPath|AvmCi\.ps1'
    }
}
