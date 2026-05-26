#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Integration smoke for the Terraform engine wrappers. Exercises
# Invoke-AvmPreCommit and Invoke-AvmPrCheck against a tiny fixture module
# via real subprocesses (pwsh-backed stub launchers on PATH) instead of
# cmdlet-level mocks. Proves the argv contracts for terraform, tflint,
# and terraform-docs hold end-to-end without the real binaries.
#
# How the harness works:
#   1. The three PowerShell stubs under tests/fixtures/bin/ are wrapped
#      as launcher binaries (cmd shim on Windows, exec script on Unix)
#      into a TestDrive subdir via tests/helpers/Install-AvmStubLauncher.ps1.
#   2. That dir is prepended to $env:PATH for the test's duration.
#   3. $env:AVM_HOME is pointed at a fresh TestDrive subdir so the
#      managed-cache lookup inside Resolve-AvmTool misses, forcing
#      -AllowPathFallback to take effect and the launchers to be used.
#   4. A minimal terraform module (main.tf + tests/ + README.md with
#      terraform-docs markers) is materialised under TestDrive/module.

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
    $null = New-Item -ItemType Directory -Path (Join-Path $script:fixtureRoot 'tests') -Force

    $mainTf = @(
        '# AVM integration fixture module',
        'terraform {',
        '  required_version = ">= 1.0"',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'main.tf') -Value $mainTf -Encoding utf8NoBOM

    $readme = @(
        '# Fixture',
        '',
        '<!-- BEGIN_TF_DOCS -->',
        '<!-- END_TF_DOCS -->'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'README.md') -Value $readme -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'tests' '.keep') -Value '' -Encoding utf8NoBOM
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

Describe 'Integration: Invoke-AvmPreCommit + Invoke-AvmPrCheck (terraform engine end-to-end)' -Tag 'Integration' {

    It 'pre-commit composes four steps end-to-end via launcher-resolved stubs' {
        $result = Invoke-AvmPreCommit -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Ecosystem'].Value | Should -Be 'terraform'
        $result.PSObject.Properties['Status'].Value | Should -Be 'pass'

        $steps = $result.PSObject.Properties['Steps'].Value
        $steps.Count | Should -Be 4
        ($steps | ForEach-Object { $_.PSObject.Properties['Step'].Value }) | Should -Be @('format', 'lint', 'test', 'docs')

        foreach ($s in $steps) {
            $s.PSObject.Properties['Status'].Value | Should -Be 'pass'
            $s.PSObject.Properties['Error'].Value | Should -BeNullOrEmpty
            $engineResult = $s.PSObject.Properties['Result'].Value
            $engineResult | Should -Not -BeNullOrEmpty
            $engineResult.PSObject.Properties['ToolSource'].Value | Should -Be 'path'
            $engineResult.PSObject.Properties['Engine'].Value | Should -Be 'terraform'
        }
    }

    It 'pr-check composes seven steps with the three unimplemented engines reported as skipped' {
        $result = Invoke-AvmPrCheck -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Ecosystem'].Value | Should -Be 'terraform'
        $result.PSObject.Properties['Status'].Value | Should -Be 'pass'

        $steps = $result.PSObject.Properties['Steps'].Value
        $steps.Count | Should -Be 7
        $expected = @('format', 'transform', 'lint', 'check policy', 'check convention', 'test', 'docs')
        ($steps | ForEach-Object { $_.PSObject.Properties['Step'].Value }) | Should -Be $expected

        $byName = @{}
        foreach ($s in $steps) { $byName[$s.PSObject.Properties['Step'].Value] = $s }

        foreach ($skipped in @('transform', 'check policy', 'check convention')) {
            $byName[$skipped].PSObject.Properties['Status'].Value | Should -Be 'skipped'
            $byName[$skipped].PSObject.Properties['Error'].Value | Should -Not -BeNullOrEmpty
        }

        foreach ($passing in @('format', 'lint', 'test', 'docs')) {
            $byName[$passing].PSObject.Properties['Status'].Value | Should -Be 'pass'
            $engineResult = $byName[$passing].PSObject.Properties['Result'].Value
            $engineResult.PSObject.Properties['ToolSource'].Value | Should -Be 'path'
            $engineResult.PSObject.Properties['Engine'].Value | Should -Be 'terraform'
        }
    }
}
