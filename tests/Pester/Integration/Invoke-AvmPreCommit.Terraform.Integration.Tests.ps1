#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Integration smoke for the Terraform engine wrappers. Exercises
# Invoke-AvmPreCommit, Invoke-AvmPrCheck, and Invoke-AvmCheckPolicy
# against a tiny fixture module via real subprocesses (pwsh-backed stub
# launchers on PATH) instead of cmdlet-level mocks. Proves the argv
# contracts for terraform, tflint, terraform-docs, and conftest hold
# end-to-end without the real binaries.
#
# How the harness works:
#   1. The four PowerShell stubs under tests/fixtures/bin/ are wrapped
#      as launcher binaries (cmd shim on Windows, exec script on Unix)
#      into a TestDrive subdir via tests/helpers/Install-AvmStubLauncher.ps1.
#   2. That dir is prepended to $env:PATH for the test's duration.
#   3. $env:AVM_HOME is pointed at a fresh TestDrive subdir so the
#      managed-cache lookup inside Resolve-AvmTool misses, forcing
#      -AllowPathFallback to take effect and the launchers to be used.
#   4. A minimal terraform module (main.tf + tests/ + README.md with
#      terraform-docs markers) is materialised under TestDrive/module.
#   5. The pinned-asset cache for avm-policy-aprl and avm-policy-avmsec
#      is pre-staged under $env:AVM_HOME/cache/assets/ (cache-hit
#      fast-path) and a matching .avm/config.json is written under the
#      fixture root so Invoke-AvmTerraformCheckPolicy resolves both
#      bundles without ever calling Invoke-AvmHttp.

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

    # Pre-stage pinned-asset cache so Invoke-AvmTerraformCheckPolicy's
    # Resolve-AvmPinnedAsset short-circuits via the cache-hit fast-path
    # without ever calling Invoke-AvmHttp. Deterministic fake SHA256s
    # are fine because Resolve-AvmPinnedAsset only re-verifies on
    # download, not on cache hit; both the schema validator and the
    # resolver accept any `^[0-9a-f]{64}$` string.
    $script:aprlSha = 'a' * 64
    $script:avmsecSha = 'b' * 64
    $cacheRoot = Join-Path $env:AVM_HOME 'cache'
    $aprlVersionDir = Join-Path (Join-Path (Join-Path $cacheRoot 'assets') 'avm-policy-aprl') $script:aprlSha
    $avmsecVersionDir = Join-Path (Join-Path (Join-Path $cacheRoot 'assets') 'avm-policy-avmsec') $script:avmsecSha
    $null = New-Item -ItemType Directory -Path $aprlVersionDir -Force
    $null = New-Item -ItemType Directory -Path $avmsecVersionDir -Force
    Set-Content -LiteralPath (Join-Path $aprlVersionDir '.verified') -Value '' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $avmsecVersionDir '.verified') -Value '' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $aprlVersionDir 'aprl-fixture.rego') -Value "package aprl`n" -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $avmsecVersionDir 'avmsec-fixture.rego') -Value "package avmsec`n" -Encoding utf8NoBOM

    # Repo-scoped pinned-asset config declaring both policy bundles. The
    # source URLs end in .zip to satisfy the archive-kind dispatch that
    # runs BEFORE the cache-hit short-circuit; they are never actually
    # fetched because the cache marker above already exists.
    $avmDir = Join-Path $script:fixtureRoot '.avm'
    $null = New-Item -ItemType Directory -Path $avmDir -Force
    $configJson = @"
{
  "schemaVersion": 1,
  "assets": {
    "avm-policy-aprl": {
      "source": "https://example.invalid/avm-policy-aprl.zip",
      "sha256": "$($script:aprlSha)"
    },
    "avm-policy-avmsec": {
      "source": "https://example.invalid/avm-policy-avmsec.zip",
      "sha256": "$($script:avmsecSha)"
    }
  }
}
"@
    Set-Content -LiteralPath (Join-Path $avmDir 'config.json') -Value $configJson -Encoding utf8NoBOM

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

    # Per-example exception .rego fixture so the integration smoke also
    # exercises Invoke-AvmTerraformCheckPolicy's per-example exceptions
    # discovery path end-to-end. The stub conftest does not load the
    # file; this only proves the engine builds argv without throwing.
    $exDir = Join-Path $script:fixtureRoot 'examples' 'foo' 'exceptions'
    $null = New-Item -ItemType Directory -Path $exDir -Force
    Set-Content -LiteralPath (Join-Path $exDir 'example.rego') -Value "package example`n" -Encoding utf8NoBOM
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

    It 'pr-check composes seven steps with the two architecturally-blocked engines reported as skipped' {
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

        foreach ($skipped in @('transform', 'check convention')) {
            $byName[$skipped].PSObject.Properties['Status'].Value | Should -Be 'skipped'
            $byName[$skipped].PSObject.Properties['Error'].Value | Should -Not -BeNullOrEmpty
        }

        foreach ($passing in @('format', 'lint', 'check policy', 'test', 'docs')) {
            $byName[$passing].PSObject.Properties['Status'].Value | Should -Be 'pass'
            $engineResult = $byName[$passing].PSObject.Properties['Result'].Value
            $engineResult.PSObject.Properties['ToolSource'].Value | Should -Be 'path'
            $engineResult.PSObject.Properties['Engine'].Value | Should -Be 'terraform'
        }

        # Tool-prefix assertions catch future engine-envelope regressions on
        # the just-wired check-policy engine, which the existing format/lint/
        # test/docs steps already pin for their respective tools.
        $byName['check policy'].PSObject.Properties['Result'].Value.PSObject.Properties['Tool'].Value | Should -Match '^conftest/'
    }

    It 'Invoke-AvmCheckPolicy resolves the conftest launcher, the pinned APRL and AVMSEC bundles, and reports pass with zero issues' {
        $result = Invoke-AvmCheckPolicy -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Engine'].Value | Should -Be 'terraform'
        $result.PSObject.Properties['Status'].Value | Should -Be 'pass'
        $result.PSObject.Properties['Tool'].Value | Should -Match '^conftest/'
        $result.PSObject.Properties['ToolSource'].Value | Should -Be 'path'
        $result.PSObject.Properties['ToolPath'].Value | Should -Not -BeNullOrEmpty
        $issues = $result.PSObject.Properties['Issues'].Value
        @($issues).Count | Should -Be 0
    }
}
