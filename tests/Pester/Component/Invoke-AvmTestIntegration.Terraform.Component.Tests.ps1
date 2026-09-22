#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Component-tier coverage for the Terraform integration-test tier
# (Invoke-AvmTestIntegration -> Invoke-AvmTerraformTestSuite -Tier integration).
# Exercises the shared engine against a tiny fixture module via a real
# subprocess (pwsh-backed terraform stub launcher on PATH) instead of
# cmdlet-level mocks, proving the 'terraform init' + 'terraform test'
# argv contracts hold end-to-end without the real binary.
#
# Harness mirrors Invoke-AvmTestUnit.Terraform.Component.Tests.ps1:
#   1. Wrap the PowerShell stubs under tests/fixtures/bin/ as launcher
#      binaries into a TestDrive subdir via Install-AvmStubLauncher.ps1.
#   2. Prepend that dir to $env:PATH for the test's duration.
#   3. Point $env:AVM_HOME at a fresh TestDrive subdir so the managed
#      cache lookup inside Resolve-AvmTool misses, forcing
#      -AllowPathFallback to select the launcher.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module -Name $script:moduleManifest -Force

    $stubDir = Join-Path $script:repoRoot 'tests' 'fixtures' 'bin'
    $helper = Join-Path $script:repoRoot 'tests' 'helpers' 'Install-AvmStubLauncher.ps1'
    . $helper

    $script:launcherDir = Install-AvmStubLauncher `
        -StubDir $stubDir `
        -LauncherDir (Join-Path $TestDrive 'bin') `
        -PinsPath (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Resources' 'avm.pins.jsonc')

    $script:originalPath = $env:PATH
    $script:originalAvmHome = $env:AVM_HOME
    $env:PATH = $script:launcherDir + [IO.Path]::PathSeparator + $env:PATH
    $env:AVM_HOME = Join-Path $TestDrive 'avm-home'

    $script:fixtureRoot = Join-Path $TestDrive 'module'
    $null = New-Item -ItemType Directory -Path $script:fixtureRoot -Force

    $mainTf = @(
        '# AVM integration-test-tier fixture module',
        'terraform {',
        '  required_version = ">= 1.0"',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'main.tf') -Value $mainTf -Encoding utf8NoBOM

    $integrationDir = Join-Path $script:fixtureRoot 'tests' 'integration'
    $null = New-Item -ItemType Directory -Path $integrationDir -Force
    $tftest = @(
        'run "smoke" {',
        '  command = plan',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $integrationDir 'integration.tftest.hcl') -Value $tftest -Encoding utf8NoBOM

    function New-RetryFixture {
        param([string] $Name, [string] $Mode = 'region', [switch] $InheritFilter)
        $root = Join-Path $TestDrive $Name
        $testDirectory = Join-Path $root 'tests' 'integration'
        $null = New-Item -ItemType Directory -Path $testDirectory -Force
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Value 'terraform {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $testDirectory 'deploy.tftest.hcl') -Value 'run "deploy" {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $testDirectory 'unselected.tftest.hcl') -Value 'run "unselected" {}' -Encoding utf8NoBOM
        @(
            'AVM_STUB_TERRAFORM_TEST_REGIONS=["restricted-test-region","eligible-test-region"]'
            "AVM_STUB_TERRAFORM_TEST_MODE=$Mode"
            "AVM_STUB_TERRAFORM_TRACE=$(Join-Path $root 'stub-trace.jsonl')"
            if (-not $InheritFilter) { 'TF_CLI_ARGS_test=-filter=tests/integration/deploy.tftest.hcl' }
        ) | Set-Content -LiteralPath (Join-Path $root '.env') -Encoding utf8NoBOM
        return $root
    }
}

AfterAll {
    if ($null -ne $script:originalPath) { $env:PATH = $script:originalPath }
    if ($null -eq $script:originalAvmHome) {
        Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
    }
    else {
        $env:AVM_HOME = $script:originalAvmHome
    }
    Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Invoke-AvmTestIntegration (terraform integration tier end-to-end)' -Tag 'Component' {

    It 'auto-inits and runs terraform test against tests/integration via the launcher-resolved stub' {
        $result = Invoke-AvmTestIntegration -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Engine'].Value     | Should -Be 'terraform'
        $result.PSObject.Properties['Status'].Value     | Should -Be 'pass'
        $result.PSObject.Properties['Tool'].Value        | Should -Match '^terraform/'
        $result.PSObject.Properties['ToolSource'].Value  | Should -Be 'path'
        $result.PSObject.Properties['ToolPath'].Value    | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['FilesProcessed'].Value | Should -Be 1
        @($result.PSObject.Properties['Issues'].Value).Count | Should -Be 0
    }

    It 'F40: reports skipped with zero runs when the module ships no tests/integration tier' {
        $emptyModule = Join-Path $TestDrive 'empty-module'
        $null = New-Item -ItemType Directory -Path $emptyModule -Force
        $mainTf = @(
            'terraform {',
            '  required_version = ">= 1.0"',
            '}'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $emptyModule 'main.tf') -Value $mainTf -Encoding utf8NoBOM

        # A bare tests/ directory satisfies Terraform module-path context
        # detection (*.tf + tests/) while genuinely shipping no
        # tests/integration tier, so the engine enumerates zero
        # *.tftest.hcl files and short-circuits.
        $null = New-Item -ItemType Directory -Path (Join-Path $emptyModule 'tests') -Force

        $result = Invoke-AvmTestIntegration -Path $emptyModule -Ecosystem terraform -AllowPathFallback

        $result.PSObject.Properties['Status'].Value          | Should -Be 'skipped'
        $result.PSObject.Properties['FilesProcessed'].Value  | Should -Be 0
        $result.PSObject.Properties['RunsTotal'].Value       | Should -Be 0
        @($result.PSObject.Properties['Issues'].Value).Count | Should -Be 0
    }

    It 'recreates a fixture in another eligible region only after the failed attempt cleans up' {
        $root = New-RetryFixture -Name 'region-retry' -InheritFilter
        $originalDirectory = (Get-Location).Path
        $originalFilter = $env:TF_CLI_ARGS_test

        try {
            $env:TF_CLI_ARGS_test = '-filter=tests/integration/deploy.tftest.hcl'
            $result = Invoke-AvmTestIntegration -Path $root -Ecosystem terraform -AllowPathFallback
            $env:TF_CLI_ARGS_test | Should -Be '-filter=tests/integration/deploy.tftest.hcl'
        }
        finally {
            $env:TF_CLI_ARGS_test = $originalFilter
        }

        $result.Status | Should -Be 'pass'
        $result.RunsTotal | Should -Be 3
        $result.RunsPassed | Should -Be 3
        $result.RunsFailed | Should -Be 0
        @($result.Issues | Where-Object Severity -eq 'warning').Count | Should -Be 2
        @($result.Issues | Where-Object Severity -eq 'error').Count | Should -Be 0
        $trace = @(Get-Content -LiteralPath (Join-Path $root 'stub-trace.jsonl') | ConvertFrom-Json)
        $selected = @($trace | Where-Object Command -eq 'test-region')
        ($selected.Region -join ',') | Should -Be 'restricted-test-region,eligible-test-region'
        ($trace.Command -join ',') | Should -Be 'init,test,test-region,test-cleanup,test,test-region,test-cleanup'
        foreach ($selection in $selected) {
            $selection.Filter | Should -Be '-filter=tests/integration/deploy.tftest.hcl'
            $selection.Directory | Should -Be $root
        }
        Test-Path -LiteralPath (Join-Path $root 'stub-owned-resource.txt') | Should -BeFalse
        (Get-Location).Path | Should -Be $originalDirectory
        $env:TF_CLI_ARGS_test | Should -Be $originalFilter
    }

    It 'preserves failed Terraform-owned cleanup and never starts another attempt' {
        $root = New-RetryFixture -Name 'cleanup-failure' -Mode cleanup

        $result = Invoke-AvmTestIntegration -Path $root -Ecosystem terraform -AllowPathFallback

        $result.Status | Should -Be 'fail'
        ($result.Issues | Where-Object Code -eq 'test_cleanup').Message | Should -Match 'manual cleanup is required'
        $trace = @(Get-Content -LiteralPath (Join-Path $root 'stub-trace.jsonl') | ConvertFrom-Json)
        @($trace | Where-Object Command -eq 'test').Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $root 'stub-owned-resource.txt') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $root 'stub-owned-resource.txt') -Raw | Should -Match 'restricted-test-region'
    }

    It 'never hides a failed assertion behind an available successful second region' {
        $root = New-RetryFixture -Name 'assertion-failure' -Mode assertion

        $result = Invoke-AvmTestIntegration -Path $root -Ecosystem terraform -AllowPathFallback

        $result.Status | Should -Be 'fail'
        $result.RunsFailed | Should -Be 1
        ($result.Issues.Message -join "`n") | Should -Match 'Test assertion failed'
        $trace = @(Get-Content -LiteralPath (Join-Path $root 'stub-trace.jsonl') | ConvertFrom-Json)
        @($trace | Where-Object Command -eq 'test').Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $root 'stub-owned-resource.txt') | Should -BeFalse
    }

    It 'honors the CLI no-retry override and propagates the original region error' {
        $root = New-RetryFixture -Name 'cli-no-retry'

        { avm test integration --path $root --ecosystem terraform --allow-path-fallback --max-retry 0 } |
            Should -Throw -ExpectedMessage '*RequestDisallowedByAzure*'

        $trace = @(Get-Content -LiteralPath (Join-Path $root 'stub-trace.jsonl') | ConvertFrom-Json)
        @($trace | Where-Object Command -eq 'test').Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $root 'stub-owned-resource.txt') | Should -BeFalse
    }
}
