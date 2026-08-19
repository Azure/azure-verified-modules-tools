#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Component-tier coverage for the Terraform unit-test tier
# (Invoke-AvmTestUnit -> Invoke-AvmTerraformTestSuite -Tier unit).
# Exercises the engine against a tiny fixture module via a real
# subprocess (pwsh-backed terraform stub launcher on PATH) instead of
# cmdlet-level mocks, proving the 'terraform init' + 'terraform test'
# argv contracts hold end-to-end without the real binary.
#
# Harness mirrors Invoke-AvmPreCommit.Terraform.Component.Tests.ps1:
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
        '# AVM unit-test-tier fixture module',
        'terraform {',
        '  required_version = ">= 1.0"',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'main.tf') -Value $mainTf -Encoding utf8NoBOM

    $unitDir = Join-Path $script:fixtureRoot 'tests' 'unit'
    $null = New-Item -ItemType Directory -Path $unitDir -Force
    $tftest = @(
        'run "smoke" {',
        '  command = plan',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $unitDir 'unit.tftest.hcl') -Value $tftest -Encoding utf8NoBOM
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

Describe 'Component: Invoke-AvmTestUnit (terraform unit tier end-to-end)' -Tag 'Component' {

    It 'auto-inits and runs terraform test against tests/unit via the launcher-resolved stub' {
        $result = Invoke-AvmTestUnit -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Engine'].Value     | Should -Be 'terraform'
        $result.PSObject.Properties['Status'].Value     | Should -Be 'pass'
        $result.PSObject.Properties['Tool'].Value        | Should -Match '^terraform/'
        $result.PSObject.Properties['ToolSource'].Value  | Should -Be 'path'
        $result.PSObject.Properties['ToolPath'].Value    | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['FilesProcessed'].Value | Should -Be 1
        @($result.PSObject.Properties['Issues'].Value).Count | Should -Be 0
    }

    It 'F40: reports skipped with zero runs when the module ships no tests/unit tier' {
        $emptyModule = Join-Path $TestDrive 'empty-module'
        $null = New-Item -ItemType Directory -Path $emptyModule -Force
        $mainTf = @(
            'terraform {',
            '  required_version = ">= 1.0"',
            '}'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $emptyModule 'main.tf') -Value $mainTf -Encoding utf8NoBOM

        # A bare tests/ directory satisfies Terraform module-path context
        # detection (*.tf + tests/) while genuinely shipping no tests/unit tier,
        # so the engine enumerates zero *.tftest.hcl files and short-circuits.
        $null = New-Item -ItemType Directory -Path (Join-Path $emptyModule 'tests') -Force

        $result = Invoke-AvmTestUnit -Path $emptyModule -Ecosystem terraform -AllowPathFallback

        $result.PSObject.Properties['Status'].Value          | Should -Be 'skipped'
        $result.PSObject.Properties['FilesProcessed'].Value  | Should -Be 0
        $result.PSObject.Properties['RunsTotal'].Value       | Should -Be 0
        @($result.PSObject.Properties['Issues'].Value).Count | Should -Be 0
    }
}
