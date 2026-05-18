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
      integration - Run Pester tests under tests/Pester/Integration/ (real FS + real subprocess, no network).
      smoke       - Run Pester tests under tests/Pester/Smoke/ (real FS + REAL NETWORK). Not part of ci/pre-commit; release/on-demand only.
      build       - Stage a publishable module tree under ./out/Avm.Authoring.
      clean       - Remove ./out.
      pre-commit  - Composite: layout + lint + test. The recommended local gate.
      ci          - Composite invoked by the CI workflow: layout + lint + coverage + integration.

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

# Verifies that the staged module under out/Avm.Authoring/ exports exactly
# what the manifest declares: every name in FunctionsToExport / AliasesToExport
# is reachable after Import-Module, and nothing extra leaks out. Runs in a
# fresh child pwsh so we exercise the same import path a user would and so we
# do not pollute the build runspace. Returns the verified export sets so the
# build task can include counts in its success message.
function script:Test-AvmStagedModuleExports {
    param(
        [Parameter(Mandatory)] [string] $ManifestPath
    )

    $data = Import-PowerShellDataFile -LiteralPath $ManifestPath
    $expectedFns     = @($data.FunctionsToExport) | Sort-Object -Unique
    $expectedAliases = @($data.AliasesToExport)   | Sort-Object -Unique

    $pwsh = (Get-Process -Id $PID).Path
    $probe = @'
param([string]$Manifest)
$ErrorActionPreference = 'Stop'
Import-Module -Name $Manifest -Force -ErrorAction Stop
$mod = Get-Module -Name 'Avm.Authoring'
$avmAlias = if ($mod.ExportedAliases.ContainsKey('avm')) { $mod.ExportedAliases['avm'].Definition } else { $null }
[pscustomobject]@{
    Functions      = @($mod.ExportedFunctions.Keys)
    Aliases        = @($mod.ExportedAliases.Keys)
    AvmAliasTarget = $avmAlias
} | ConvertTo-Json -Compress
'@

    $probePath = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-build-verify-{0}.ps1" -f ([guid]::NewGuid()))
    try {
        [System.IO.File]::WriteAllText($probePath, $probe, (New-Object System.Text.UTF8Encoding $false))
        $out = & $pwsh -NoProfile -NoLogo -File $probePath -Manifest $ManifestPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to import staged manifest at ${ManifestPath} (pwsh exit ${LASTEXITCODE}):`n$($out -join "`n")"
        }
    }
    finally {
        Remove-Item -LiteralPath $probePath -ErrorAction SilentlyContinue
    }

    $report        = ($out | Out-String) | ConvertFrom-Json
    $actualFns     = @($report.Functions) | Sort-Object -Unique
    $actualAliases = @($report.Aliases)   | Sort-Object -Unique

    $missingFns     = @(Compare-Object -ReferenceObject $expectedFns -DifferenceObject $actualFns | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject)
    $extraFns       = @(Compare-Object -ReferenceObject $expectedFns -DifferenceObject $actualFns | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject)
    $missingAliases = @(Compare-Object -ReferenceObject $expectedAliases -DifferenceObject $actualAliases | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject)
    $extraAliases   = @(Compare-Object -ReferenceObject $expectedAliases -DifferenceObject $actualAliases | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject)

    $problems = @()
    if ($missingFns)     { $problems += "manifest declares but module did not export: $($missingFns -join ', ')" }
    if ($extraFns)       { $problems += "module exports but manifest did not declare: $($extraFns -join ', ')" }
    if ($missingAliases) { $problems += "manifest declares aliases but module did not export: $($missingAliases -join ', ')" }
    if ($extraAliases)   { $problems += "module exports aliases but manifest did not declare: $($extraAliases -join ', ')" }
    if (('avm' -in $expectedAliases) -and ($report.AvmAliasTarget -ne 'Invoke-Avm')) {
        $problems += "alias 'avm' resolves to '$($report.AvmAliasTarget)', expected 'Invoke-Avm'"
    }
    if ($problems) {
        throw ("Staged module export verification failed:`n  - " + ($problems -join "`n  - "))
    }

    [pscustomobject]@{
        Functions = $actualFns
        Aliases   = $actualAliases
    }
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

    # Verify exports beyond the manifest's structural validity: every name in
    # FunctionsToExport / AliasesToExport must actually be exported when the
    # staged module is imported, and nothing extra may leak out. Runs in a
    # fresh pwsh so the build runspace stays clean and we exercise the same
    # import path a downstream user would.
    $exports = script:Test-AvmStagedModuleExports -ManifestPath $stagedManifest
    $fnCount    = @($exports.Functions).Count
    $aliasCount = @($exports.Aliases).Count
    Write-Build Green "  build OK: $stage ($fnCount functions, $aliasCount aliases verified)"
}

task clean {
    if (Test-Path -LiteralPath $script:outRoot) {
        Remove-Item -LiteralPath $script:outRoot -Recurse -Force
    }
    Write-Build Green '  clean OK'
}

# Spec section 18 Integration tier: real FS + real subprocess, no network.
# Tests live under tests/Pester/Integration/ and are tagged `Integration` so
# they are excluded from `test` / `coverage` (which run the Unit tier only).
# This task runs them in isolation, with no coverage instrumentation -- the
# coverage floor is a Unit-tier contract.
task integration {
    script:Assert-Module -Name 'Pester' -MinimumVersion '5.5.0'

    $integrationPath = Join-Path $script:testsRoot 'Integration'
    if (-not (Test-Path -LiteralPath $integrationPath)) {
        Write-Build Yellow "  no integration tests found at $integrationPath"
        return
    }

    $config = New-PesterConfiguration
    $config.Run.Path           = $integrationPath
    $config.Run.PassThru       = $true
    $config.Run.Exit           = $false
    $config.Output.Verbosity   = 'Detailed'
    $config.TestResult.Enabled = $false
    $config.Filter.Tag         = @('Integration')
    $config.Filter.ExcludeTag  = @('Smoke')

    $result = Invoke-Pester -Configuration $config
    if ($result.TotalCount -eq 0) {
        throw "No Integration-tagged tests ran from $integrationPath. Tag your It / Describe with -Tag 'Integration'."
    }
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) Integration test(s) failed."
    }
    Write-Build Green "  integration OK: $($result.PassedCount) passed, $($result.SkippedCount) skipped"
}

# Spec section 18 Smoke tier: real FS + real network. Tests live under
# tests/Pester/Smoke/ and are tagged `Smoke`. The smoke task is the only
# entry point that runs them; it is NOT part of `pre-commit` or `ci` so
# routine builds never touch the network. Wire this into a release-branch
# workflow or invoke on demand. Honours `$env:AVM_OFFLINE` indirectly --
# the tests themselves Skip when offline rather than fail.
task smoke {
    script:Assert-Module -Name 'Pester' -MinimumVersion '5.5.0'

    $smokePath = Join-Path $script:testsRoot 'Smoke'
    if (-not (Test-Path -LiteralPath $smokePath)) {
        Write-Build Yellow "  no smoke tests found at $smokePath"
        return
    }

    $config = New-PesterConfiguration
    $config.Run.Path           = $smokePath
    $config.Run.PassThru       = $true
    $config.Run.Exit           = $false
    $config.Output.Verbosity   = 'Detailed'
    $config.TestResult.Enabled = $false
    $config.Filter.Tag         = @('Smoke')

    $result = Invoke-Pester -Configuration $config
    if ($result.TotalCount -eq 0) {
        throw "No Smoke-tagged tests ran from $smokePath. Tag your It / Describe with -Tag 'Smoke'."
    }
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) Smoke test(s) failed."
    }
    Write-Build Green "  smoke OK: $($result.PassedCount) passed, $($result.SkippedCount) skipped"
}

task 'pre-commit' layout, lint, test

# CI runs layout + lint + coverage + integration. Coverage runs the Unit tier
# with CodeCoverage enabled (so we get the spec section 18 70% floor) and
# `integration` runs the real-subprocess tier separately. `pre-commit` (the
# local gate) skips both coverage and integration to stay fast.
task ci layout, lint, coverage, integration

task . layout
