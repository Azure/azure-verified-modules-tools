#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Component-tier coverage for the Terraform e2e-test tier
# (Invoke-AvmTestE2e -> Invoke-AvmTerraformTestE2e). Exercises the engine
# against a tiny fixture module via a real subprocess (pwsh-backed terraform
# stub launcher on PATH) instead of cmdlet-level mocks, proving the per-example
# 'init -> apply -> plan -> destroy' argv contracts hold end-to-end without the
# real binary.
#
# Harness mirrors Invoke-AvmTestIntegration.Terraform.Component.Tests.ps1:
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
        -LauncherDir (Join-Path $TestDrive 'bin')

    $script:originalPath = $env:PATH
    $script:originalAvmHome = $env:AVM_HOME
    $env:PATH = $script:launcherDir + [IO.Path]::PathSeparator + $env:PATH
    $env:AVM_HOME = Join-Path $TestDrive 'avm-home'

    $script:fixtureRoot = Join-Path $TestDrive 'module'
    $null = New-Item -ItemType Directory -Path $script:fixtureRoot -Force

    $mainTf = @(
        '# AVM e2e-test-tier fixture module',
        'terraform {',
        '  required_version = ">= 1.0"',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'main.tf') -Value $mainTf -Encoding utf8NoBOM

    # A bare tests/ directory satisfies Terraform module-path context detection
    # (*.tf + tests/); the e2e engine itself walks examples/, not tests/.
    $null = New-Item -ItemType Directory -Path (Join-Path $script:fixtureRoot 'tests') -Force

    $exampleDir = Join-Path $script:fixtureRoot 'examples' 'default'
    $null = New-Item -ItemType Directory -Path $exampleDir -Force
    $exampleTf = @(
        '# default example',
        'terraform {',
        '  required_version = ">= 1.0"',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $exampleDir 'main.tf') -Value $exampleTf -Encoding utf8NoBOM
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

Describe 'Component: Invoke-AvmTestE2e (terraform e2e tier end-to-end)' -Tag 'Component' {

    It 'deploys, checks idempotency, and destroys each example via the launcher-resolved stub' {
        $result = Invoke-AvmTestE2e -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Engine'].Value          | Should -Be 'terraform'
        $result.PSObject.Properties['Status'].Value          | Should -Be 'pass'
        $result.PSObject.Properties['Tool'].Value            | Should -Match '^terraform/'
        $result.PSObject.Properties['ToolSource'].Value      | Should -Be 'path'
        $result.PSObject.Properties['ToolPath'].Value        | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['FilesProcessed'].Value  | Should -Be 1
        @($result.PSObject.Properties['Issues'].Value).Count | Should -Be 0
    }

    It 'reports a clean pass with FilesProcessed=0 when the module ships no runnable examples' {
        $emptyModule = Join-Path $TestDrive 'empty-module'
        $null = New-Item -ItemType Directory -Path $emptyModule -Force
        $mainTf = @(
            'terraform {',
            '  required_version = ">= 1.0"',
            '}'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $emptyModule 'main.tf') -Value $mainTf -Encoding utf8NoBOM
        $null = New-Item -ItemType Directory -Path (Join-Path $emptyModule 'tests') -Force

        $result = Invoke-AvmTestE2e -Path $emptyModule -Ecosystem terraform -AllowPathFallback

        $result.PSObject.Properties['Status'].Value          | Should -Be 'pass'
        $result.PSObject.Properties['FilesProcessed'].Value  | Should -Be 0
        @($result.PSObject.Properties['Issues'].Value).Count | Should -Be 0
    }

    It 'runs per-example pre.ps1/post.ps1 hooks and skips hooks in .e2eignore examples' {
        $hookModule = Join-Path $TestDrive 'hook-module'
        $null = New-Item -ItemType Directory -Path $hookModule -Force
        $mainTf = @(
            'terraform {',
            '  required_version = ">= 1.0"',
            '}'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $hookModule 'main.tf') -Value $mainTf -Encoding utf8NoBOM
        $null = New-Item -ItemType Directory -Path (Join-Path $hookModule 'tests') -Force

        # An example that runs: pre.ps1 and post.ps1 each drop a marker file
        # (via $PSScriptRoot so the path is independent of the hook's cwd).
        $hookedDir = Join-Path $hookModule 'examples' 'hooked'
        $null = New-Item -ItemType Directory -Path $hookedDir -Force
        Set-Content -LiteralPath (Join-Path $hookedDir 'main.tf') -Value $mainTf -Encoding utf8NoBOM
        $preScript = @(
            '$marker = Join-Path $PSScriptRoot ''pre.marker''',
            'Set-Content -LiteralPath $marker -Value ''pre ran'' -Encoding utf8NoBOM',
            'exit 0'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $hookedDir 'pre.ps1') -Value $preScript -Encoding utf8NoBOM
        $postScript = @(
            '$marker = Join-Path $PSScriptRoot ''post.marker''',
            'Set-Content -LiteralPath $marker -Value ''post ran'' -Encoding utf8NoBOM',
            'exit 0'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $hookedDir 'post.ps1') -Value $postScript -Encoding utf8NoBOM

        # An example that must be skipped entirely: its pre.ps1 must NOT run.
        $skippedDir = Join-Path $hookModule 'examples' 'skipme'
        $null = New-Item -ItemType Directory -Path $skippedDir -Force
        Set-Content -LiteralPath (Join-Path $skippedDir 'main.tf') -Value $mainTf -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $skippedDir '.e2eignore') -Value '' -Encoding utf8NoBOM
        $skipPre = @(
            '$marker = Join-Path $PSScriptRoot ''pre.marker''',
            'Set-Content -LiteralPath $marker -Value ''should not run'' -Encoding utf8NoBOM',
            'exit 0'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $skippedDir 'pre.ps1') -Value $skipPre -Encoding utf8NoBOM

        $result = Invoke-AvmTestE2e -Path $hookModule -Ecosystem terraform -AllowPathFallback

        $result.PSObject.Properties['Status'].Value          | Should -Be 'pass'
        $result.PSObject.Properties['FilesProcessed'].Value  | Should -Be 1
        @($result.PSObject.Properties['Issues'].Value).Count | Should -Be 0

        Test-Path -LiteralPath (Join-Path $hookedDir 'pre.marker')  | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $hookedDir 'post.marker') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $skippedDir 'pre.marker') | Should -BeFalse
    }
}
