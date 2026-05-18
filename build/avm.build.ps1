<#
.SYNOPSIS
    Invoke-Build task graph for Avm.Authoring.

.DESCRIPTION
    Do not invoke this script directly. Run tasks from the repo root via
    `./build.ps1 <task>`, which forwards to Invoke-Build with this file.

    Tasks (Phase 0):
      layout      - Verify on-disk casing and manifest shape.
      lint        - Run PSScriptAnalyzer with repo settings.
      test        - Run Pester unit tests (excludes Integration and Smoke).
      coverage    - Run unit tests with coverage; fails below the spec §18 floor.
      build       - Stage a publishable module tree under ./out/Avm.Authoring.
      clean       - Remove ./out.
      pre-commit  - Composite: layout + lint + test. The recommended local gate.
      ci          - Composite invoked by the CI workflow: layout + lint + coverage.

    The default task (`.`) is `layout`.
#>

#Requires -Version 7.4

[CmdletBinding()]
param(
    [string] $Configuration = 'Debug'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:repoRoot     = Split-Path -Parent $PSScriptRoot
$script:moduleRoot   = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
$script:manifestPath = Join-Path $script:moduleRoot 'Avm.Authoring.psd1'
$script:testsRoot    = Join-Path $script:repoRoot 'tests' 'Pester'
$script:settingsPath = Join-Path $script:moduleRoot 'Resources' 'PSScriptAnalyzerSettings.psd1'
$script:outRoot      = Join-Path $script:repoRoot 'out'

# Single source of truth for the spec section 18 line-coverage floor. The CI
# job (`ci` task) runs `coverage` and fails below this number. Adjust here
# when the per-file ratchet lands; the spec lets us start at 70 and tighten.
$script:coverageFloor = 70

# --- helpers ----------------------------------------------------------------

function script:Assert-Module {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $MinimumVersion
    )
    $modules = Get-Module -ListAvailable -Name $Name
    if ($MinimumVersion) {
        $modules = $modules | Where-Object { $_.Version -ge [version]$MinimumVersion }
    }
    if (-not $modules) {
        $hint = if ($MinimumVersion) { " (>= $MinimumVersion)" } else { '' }
        throw "Required PowerShell module not installed: $Name$hint. Install with 'Install-PSResource $Name -Scope CurrentUser'."
    }
    $importArgs = @{ Name = $Name; Force = $true; ErrorAction = 'Stop' }
    if ($MinimumVersion) { $importArgs.MinimumVersion = $MinimumVersion }
    Import-Module @importArgs
}

# --- tasks ------------------------------------------------------------------

task layout {
    # Reuse the in-module helper so the build, CI, and any future smoke
    # tests assert the same invariants from a single implementation. The
    # helper lives under src/Avm.Authoring/Private/Layout and is loaded by
    # importing the module here.
    Import-Module $script:manifestPath -Force
    try {
        $manifest = & (Get-Module Avm.Authoring) { Test-AvmModuleLayout -ModuleRoot $args[0] } $script:moduleRoot
        Write-Build Green "  layout OK: $($manifest.Name) $($manifest.Version) (PS >= $($manifest.PowerShellVersion))"
    }
    finally {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }
}

task lint {
    script:Assert-Module -Name 'PSScriptAnalyzer'

    $params = @{
        Path    = $script:moduleRoot
        Recurse = $true
    }
    if (Test-Path -LiteralPath $script:settingsPath) {
        $params.Settings = $script:settingsPath
    }

    $results = Invoke-ScriptAnalyzer @params

    if (-not $results) {
        Write-Build Green '  lint OK: no findings'
        return
    }

    $results | Format-Table -AutoSize | Out-String | Write-Host

    $errors   = @($results | Where-Object { $_.Severity -in @('Error', 'ParseError') })
    $warnings = @($results | Where-Object { $_.Severity -eq 'Warning' })

    if ($errors.Count -gt 0) {
        throw "PSScriptAnalyzer reported $($errors.Count) error(s)."
    }
    if ($warnings.Count -gt 0) {
        Write-Warning "PSScriptAnalyzer reported $($warnings.Count) warning(s)."
    }
}

task test {
    script:Assert-Module -Name 'Pester' -MinimumVersion '5.5.0'

    $unitPath = Join-Path $script:testsRoot 'Unit'
    if (-not (Test-Path -LiteralPath $unitPath)) {
        Write-Build Yellow "  no unit tests found at $unitPath"
        return
    }

    $config = New-PesterConfiguration
    $config.Run.Path          = $unitPath
    $config.Run.PassThru      = $true
    $config.Run.Exit          = $false
    $config.Output.Verbosity  = 'Detailed'
    $config.TestResult.Enabled = $false
    $config.Filter.ExcludeTag  = @('Smoke', 'Integration')

    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) Pester test(s) failed."
    }
}

task coverage {
    script:Assert-Module -Name 'Pester' -MinimumVersion '5.5.0'

    $unitPath = Join-Path $script:testsRoot 'Unit'
    if (-not (Test-Path -LiteralPath $unitPath)) {
        Write-Build Yellow "  no unit tests found at $unitPath"
        return
    }

    $coverageOut = Join-Path $script:outRoot 'coverage'
    if (-not (Test-Path -LiteralPath $coverageOut)) {
        $null = New-Item -ItemType Directory -Path $coverageOut -Force
    }

    $config = New-PesterConfiguration
    $config.Run.Path                           = $unitPath
    $config.Run.PassThru                       = $true
    $config.Run.Exit                           = $false
    $config.Output.Verbosity                   = 'Detailed'
    $config.Filter.ExcludeTag                  = @('Smoke', 'Integration')
    $config.CodeCoverage.Enabled               = $true
    $config.CodeCoverage.Path                  = @(
        (Join-Path $script:moduleRoot 'Public'),
        (Join-Path $script:moduleRoot 'Private')
    )
    $config.CodeCoverage.OutputFormat          = 'JaCoCo'
    $config.CodeCoverage.OutputPath            = (Join-Path $coverageOut 'coverage.xml')
    $config.CodeCoverage.OutputEncoding        = 'UTF8'
    # Set Pester's own target so its run-end summary matches our floor; the
    # hard gate below is what actually fails the build.
    $config.CodeCoverage.CoveragePercentTarget = $script:coverageFloor

    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) Pester test(s) failed."
    }

    $covered  = [math]::Round([double]$result.CodeCoverage.CoveragePercent, 2)
    $analyzed = $result.CodeCoverage.CommandsAnalyzedCount
    $executed = $result.CodeCoverage.CommandsExecutedCount
    $files    = $result.CodeCoverage.FilesAnalyzedCount
    Write-Build Green "  coverage report: $($config.CodeCoverage.OutputPath.Value)"
    Write-Build Green "  coverage: $covered% ($executed of $analyzed commands across $files files); floor: $($script:coverageFloor)%"

    if ($covered -lt $script:coverageFloor) {
        # Per spec section 18 the CI build fails below the floor. Make the
        # failure message actionable: list every file under the floor so the
        # contributor knows where to add tests next.
        $missed = $result.CodeCoverage.CommandsMissed |
            Group-Object -Property File |
            ForEach-Object {
                $rel = $_.Name
                if ($rel.StartsWith($script:repoRoot)) {
                    $rel = $rel.Substring($script:repoRoot.Length).TrimStart('\','/')
                }
                '    {0}: {1} missed' -f $rel, $_.Count
            } |
            Sort-Object

        $detail = if ($missed) { "`n" + ($missed -join "`n") } else { '' }
        throw ("Coverage gate failed: $covered% < $($script:coverageFloor)% floor. " +
               "Add tests for the files below or raise coverage on existing ones.$detail")
    }
}

task build layout, {
    if (Test-Path -LiteralPath $script:outRoot) {
        Remove-Item -LiteralPath $script:outRoot -Recurse -Force
    }
    $stage = Join-Path $script:outRoot 'Avm.Authoring'
    $null = New-Item -ItemType Directory -Path $stage -Force

    # Copy everything except scratch and test scaffolding into the staged tree.
    Copy-Item -Path (Join-Path $script:moduleRoot '*') -Destination $stage -Recurse -Force

    # Verify the staged manifest still loads cleanly.
    $stagedManifest = Join-Path $stage 'Avm.Authoring.psd1'
    $null = Test-ModuleManifest -Path $stagedManifest
    Write-Build Green "  build OK: $stage"
}

task clean {
    if (Test-Path -LiteralPath $script:outRoot) {
        Remove-Item -LiteralPath $script:outRoot -Recurse -Force
    }
    Write-Build Green '  clean OK'
}

task 'pre-commit' layout, lint, test

# CI runs layout + lint + coverage (not pre-commit) so the spec section 18
# 70% line-coverage floor is enforced on every matrix combo. Coverage runs
# the same unit tests with CodeCoverage enabled, so we do not also run
# `test` here — it would be a wasted duplicate Pester invocation.
task ci layout, lint, coverage

task . layout
