#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:root = Join-Path $TestDrive 'repository'
    $script:modulePath = 'avm/res/mock/widget'
    $module = Join-Path $script:root $script:modulePath
    $test = Join-Path $module 'tests' 'e2e' 'defaults'
    $ignored = Join-Path $module 'tests' 'e2e' 'waf-aligned'
    $null = New-Item -ItemType Directory -Path $test, $ignored -Force
    [IO.File]::WriteAllText((Join-Path $module 'main.bicep'), "metadata name = 'fixture'")
    [IO.File]::WriteAllText((Join-Path $test 'main.test.bicep'), '')
    [IO.File]::WriteAllText((Join-Path $ignored 'main.test.bicep'), '')
    [IO.File]::WriteAllText((Join-Path $ignored '.e2eignore'), '')
    [IO.File]::WriteAllText((Join-Path $script:root '.reserved-test-subscriptions.json'), '{}')

    & git -C $script:root init --quiet --initial-branch=main
    & git -C $script:root config user.name WorkflowFixture
    & git -C $script:root config user.email fixture@example.invalid
    & git -C $script:root add --all
    & git -C $script:root commit --quiet -m fixture
    $script:target = (& git -C $script:root rev-parse HEAD).Trim()
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    $gitDirectory = Join-Path $script:root '.git'
    if (Test-Path -LiteralPath $gitDirectory -PathType Container) {
        Get-ChildItem -LiteralPath $gitDirectory -File -Recurse -Force |
            ForEach-Object { $_.IsReadOnly = $false }
    }
}

Describe 'Public: Bicep workflow package APIs' -Tag Unit {
    It 'returns structured test and policy metadata without workflow scripts' {
        $result = Get-AvmBicepWorkflowTestFiles -Root $script:root -ModulePath $script:modulePath -SkipModuleVersionCheck

        $result.TestFiles.Count | Should -Be 2
        @($result.TestFiles | Where-Object path -EQ 'tests/e2e/waf-aligned/main.test.bicep').e2eIgnore | Should -BeTrue
        @($result.PolicyTestFiles.path) | Should -Be @(
            'tests/e2e/defaults/main.test.bicep',
            'tests/e2e/waf-aligned/main.test.bicep'
        )
    }

    It 'filters README changes while preserving manual selections and test metadata' {
        $changed = Get-AvmBicepWorkflowModuleMatrix -Root $script:root `
            -ChangedFiles @("$script:modulePath/README.md") -SkipModuleVersionCheck
        $manual = Get-AvmBicepWorkflowModuleMatrix -Root $script:root -ModulePaths $script:modulePath -SkipModuleVersionCheck

        $changed.Include.Count | Should -Be 0
        $manual.Include.Count | Should -Be 1
        $manual.Include[0].ModulePath | Should -BeExactly $script:modulePath
        $manual.Include[0].TestFiles.Count | Should -Be 2
    }

    It 'returns a structured manual matrix from the package with no workflow script loaded' {
        $result = Initialize-AvmBicepWorkflowMatrix -Root $script:root -EventName workflow_dispatch `
            -TargetCommit $script:target -ModulePaths $script:modulePath -DeploymentValidation:$false -SkipModuleVersionCheck

        $result.TargetCommit | Should -BeExactly $script:target
        $result.BaseCommit | Should -BeNullOrEmpty
        $result.HasModules | Should -BeTrue
        $result.ModuleMatrix.Include[0].ModulePath | Should -BeExactly $script:modulePath
        $result.WorkflowInput.deploymentValidation | Should -BeExactly 'false'
    }

    It 'rejects a non-merge pull request target before selecting modules' {
        {
            Initialize-AvmBicepWorkflowMatrix -Root $script:root -EventName pull_request `
                -TargetCommit $script:target -PullRequestHeadCommit $script:target -SkipModuleVersionCheck
        } | Should -Throw '*exactly two parents*'
    }

    It 'exports guarded release APIs with default-off changelog compatibility' {
        foreach ($name in @(
                'Get-AvmBicepWorkflowTestFiles',
                'Get-AvmBicepWorkflowModuleMatrix',
                'Initialize-AvmBicepWorkflowMatrix',
                'Get-AvmBicepPendingReleasePlan',
                'Initialize-AvmBicepReleaseMatrix',
                'Set-AvmBicepReleaseTags',
                'Get-AvmBicepE2eDeploymentMatrix',
                'Get-AvmBicepE2eTestContext'
            )) {
            (Get-Command $name -Module Avm.Authoring).Parameters['SkipModuleVersionCheck'].SwitchParameter |
                Should -BeTrue
        }
        $release = Get-Command Set-AvmBicepReleaseTags -Module Avm.Authoring
        $release.Parameters['RequireChangelog'].SwitchParameter | Should -BeTrue
        $release.Parameters['PendingRelease'].SwitchParameter | Should -BeTrue
    }

    It 'builds and revalidates package-only E2E context with empty CI maps' {
        $subscription = '11111111-2222-4333-8444-555555555555'
        $tenant = '11111111-2222-4333-8444-666666666666'
        $mapping = '{"avm/res/mock/widget":"10000000-0000-4000-8000-000000000006"}'
        $savedVariables = $env:AVM_CI_VARIABLES
        $savedSecrets = $env:AVM_CI_SECRETS
        $env:AVM_CI_VARIABLES = '{}'
        $env:AVM_CI_SECRETS = '{}'
        try {
            Mock Get-AvmModuleContext -ModuleName Avm.Authoring { [pscustomobject]@{ Ecosystem = 'bicep' } }
            Mock Get-AvmTool -ModuleName Avm.Authoring { [pscustomobject]@{ Status = 'installed'; Path = 'fixture-bicep' } }
            Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
                [pscustomobject]@{ ExitCode = 0; StdOut = '{"resources":[]}' ; StdErr = '' }
            }
            $matrix = @(Get-AvmBicepE2eDeploymentMatrix -Root $script:root -ModulePath $script:modulePath `
                    -TestFiles @([pscustomobject]@{ path = 'tests/e2e/defaults/main.test.bicep'; name = 'defaults'; e2eIgnore = $false }) `
                    -FallbackSubscriptionId $subscription -ModuleClientIds $mapping -TenantId $tenant -SkipModuleVersionCheck)
            $context = Get-AvmBicepE2eTestContext -Root $script:root -ModulePath $script:modulePath -TestCase $matrix[0] `
                -FallbackSubscriptionId $subscription -ModuleClientIds $mapping -TenantId $tenant -SkipModuleVersionCheck

            $matrix[0].IsolationMode | Should -BeExactly 'fallback'
            $matrix[0].SubscriptionModulePath | Should -BeExactly $script:modulePath
            $context.SubscriptionId | Should -BeExactly $subscription
            $context.TenantId | Should -BeExactly $tenant
            $context.ModulePath | Should -BeExactly $script:modulePath
            $context.Example | Should -BeExactly 'tests/e2e/defaults/main.test.bicep'
            $context.NamePrefix | Should -BeNullOrEmpty
            $context.ArtifactKey | Should -Match '^bicep-e2e-[0-9a-f]{64}-0$'
            $context.RequireResourceIsolation | Should -BeFalse
            Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 2
        }
        finally {
            $env:AVM_CI_VARIABLES = $savedVariables
            $env:AVM_CI_SECRETS = $savedSecrets
        }
    }

    It 'keeps every decoded E2E test record as an individual matrix input' {
        $subscription = '11111111-2222-4333-8444-555555555555'
        $tenant = '11111111-2222-4333-8444-666666666666'
        $mapping = '{"avm/res/mock/widget":"10000000-0000-4000-8000-000000000006"}'
        Mock Get-AvmModuleContext -ModuleName Avm.Authoring { [pscustomobject]@{ Ecosystem = 'bicep' } }
        Mock Get-AvmTool -ModuleName Avm.Authoring { [pscustomobject]@{ Status = 'installed'; Path = 'fixture-bicep' } }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"resources":[]}' ; StdErr = '' }
        }
        $records = @(
            ConvertFrom-Json -InputObject @'
[
  {"path":"tests/e2e/defaults/main.test.bicep","name":"defaults","e2eIgnore":false},
  {"path":"tests/e2e/waf-aligned/main.test.bicep","name":"waf-aligned","e2eIgnore":true}
]
'@ -AsHashtable
        )

        $matrix = @(Get-AvmBicepE2eDeploymentMatrix -Root $script:root -ModulePath $script:modulePath `
                -TestFiles $records -FallbackSubscriptionId $subscription -ModuleClientIds $mapping `
                -TenantId $tenant -SkipModuleVersionCheck)

        $matrix | Should -HaveCount 2
        $matrix.E2eIgnore | Should -Be @($false, $true)
        $matrix.Path | Should -Be @(
            'tests/e2e/defaults/main.test.bicep',
            'tests/e2e/waf-aligned/main.test.bicep'
        )
    }
}
