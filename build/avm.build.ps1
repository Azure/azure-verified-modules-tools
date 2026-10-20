<#
.SYNOPSIS
    Invoke-Build task graph for Avm.Authoring.

.DESCRIPTION
    Do not invoke this script directly. Run tasks from the repo root via
    `./build.ps1 <task>`, which forwards to Invoke-Build with this file.

    Tasks (Phase 0):
      layout      - Verify on-disk casing and manifest shape.
      lint        - Run PSScriptAnalyzer with repo settings.
      test        - Run Pester unit tests (excludes Component and Integration).
                    By default this tier shards across up to 6 pwsh child
                    processes. Set AVM_UNIT_SHARD_COUNT to override.
      coverage    - Run unit and component tests with coverage; fails below the spec §18 floor.
      test-workflows - Run workflow-definition unit tests.
      component   - Run Pester tests under tests/Pester/Component/ (real FS + real subprocess, stub binaries, no network).
                    By default this tier shards across up to 6 pwsh child
                    processes. Set AVM_COMPONENT_SHARD_COUNT to override.
      integration - Run packaged public-command acceptance with real binaries.
      qualification - Run focused native compatibility or package/bootstrap qualification.
      build       - Stage a publishable module tree under ./out/Avm.Authoring.
                    Version stamping and release notes are applied by the ADO
                    release pipeline, not here; the in-repo manifest is never
                    modified.
      clean       - Remove ./out.
      docs        - Generate docs/reference from public comment-based help.
      docs-check  - Fail when docs/reference is missing, stale, or has extra pages.
      pre-commit  - Composite: docs-check + layout + lint + test + component.
      ci          - Full local CI gate: docs-check + layout + lint + coverage + component.
      ci-unit     - CI unit-test matrix leg: docs-check + layout + unit tests.
      ci-coverage - CI Ubuntu unit-test matrix leg with coverage.
      ci-component - CI component-test matrix leg.
      ci-tests    - Matrix CI gate: docs-check + layout + test + component. CI lints once
                    in a separate Ubuntu job and runs workflow tests separately.

    The test, coverage, component, and integration tasks write an NUnit result
    file per tier under out/test-results/. The split CI workflows upload it as
    an artifact and publish their own test reports.
    Locally this is just a file write under the gitignored out/ tree.

    TestGroup selects All (the local default), Authoring, or RepositoryManagement
    for unit and component tasks, including the unit coverage task. Workflow
    tests run separately in CI. The local pre-commit task still runs every group.

    The default task (`.`) is `layout`.
#>

#Requires -Version 7.4

[CmdletBinding()]
param(
    [string] $Configuration = 'Debug',

    [string[]] $TestName = @(),

    [ValidateSet('All', 'Authoring', 'RepositoryManagement')]
    [string] $TestGroup = 'All',

    [ValidateSet('All', 'Bicep', 'Terraform')]
    [string] $IntegrationGroup = 'All',

    [ValidateSet('All', 'Native', 'Package')]
    [string] $QualificationGroup = 'All'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:repoRoot     = Split-Path -Parent $PSScriptRoot
$script:moduleRoot   = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
$script:manifestPath = Join-Path $script:moduleRoot 'Avm.Authoring.psd1'
$script:testsRoot    = Join-Path $script:repoRoot 'tests' 'Pester'
$script:workflowUnitTestsRoot = Join-Path $script:testsRoot 'Unit' 'Workflows'
$script:settingsPath = Join-Path $script:moduleRoot 'Resources' 'PSScriptAnalyzerSettings.psd1'
$script:outRoot      = Join-Path $script:repoRoot 'out'
$script:cmdletDocsGenerator = Join-Path $script:repoRoot 'scripts' 'Generate-AvmCmdletDocumentation.ps1'
$script:testNameFilter = $TestName

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

function script:Import-AvmBuildPester {
    $module = Import-Module -Name $script:manifestPath -PassThru -ErrorAction Stop
    try {
        $null = & $module { Import-AvmPowerShellModule -Name Pester -Global }
    }
    finally {
        Remove-Module -ModuleInfo $module -Force
    }
    script:Initialize-AvmPesterRegistryRoot
}

function script:Invoke-AvmPester {
    param(
        [Parameter(Mandatory)] [object] $Configuration
    )

    if ($script:testNameFilter.Count -gt 0) {
        $Configuration.Filter.FullName = $script:testNameFilter
        # Positive Pester filters are ORed; Run.Path already selects the tier.
        $Configuration.Filter.Tag = @()
    }
    $previousTestRunId = $env:AVM_TEST_RUN_ID
    $previousTestSkip = $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK
    $previousActions = $env:GITHUB_ACTIONS
    $previousStepSummary = $env:GITHUB_STEP_SUMMARY
    $testRunId = [guid]::NewGuid().ToString()
    $logToken = script:Start-AvmPesterLogIsolation
    try {
        $env:AVM_TEST_RUN_ID = $testRunId
        $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = $testRunId
        $env:GITHUB_ACTIONS = ''
        $env:GITHUB_STEP_SUMMARY = ''
        $result = Invoke-Pester -Configuration $Configuration
        if ($result.FailedContainersCount -gt 0) {
            $paths = @($result.Containers | Where-Object Result -eq 'Failed' | ForEach-Object { $_.Item })
            throw "$($result.FailedContainersCount) Pester test file(s) failed to load or run: $($paths -join ', ')"
        }
        if ($result.FailedBlocksCount -gt 0) {
            $names = @($result.FailedBlocks | ForEach-Object Name)
            throw "$($result.FailedBlocksCount) Pester setup or teardown block(s) failed: $($names -join ', ')"
        }
        if ($script:testNameFilter.Count -gt 0 -and $result.TotalCount -eq 0) {
            throw "No tests matched TestName: $($script:testNameFilter -join ', ')."
        }
        return $result
    }
    finally {
        if ($null -eq $previousTestRunId) {
            Remove-Item Env:AVM_TEST_RUN_ID -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_TEST_RUN_ID = $previousTestRunId
        }
        if ($null -eq $previousTestSkip) {
            Remove-Item Env:AVM_TEST_SKIP_MODULE_VERSION_CHECK -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = $previousTestSkip
        }
        $env:GITHUB_ACTIONS = $previousActions
        $env:GITHUB_STEP_SUMMARY = $previousStepSummary
        script:Stop-AvmPesterLogIsolation -Token $logToken
    }
}

function script:Invoke-ScriptAnalyzerSerial {
    param(
        [Parameter(Mandatory)] [hashtable] $Params
    )

    $ruleNames = @(Get-ScriptAnalyzerRule -ErrorAction Stop | Select-Object -ExpandProperty RuleName -Unique | Sort-Object)
    if ($ruleNames.Count -eq 0) {
        throw [System.InvalidOperationException]::new('PSScriptAnalyzer returned no built-in rules.')
    }

    $partitions = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($ruleName in $ruleNames) {
        $partition = $Params.Clone()
        $partition.IncludeRule = @($ruleName)
        $partitions.Add($partition)
    }
    if ($Params.ContainsKey('CustomRulePath')) {
        $partition = $Params.Clone()
        $partition.ExcludeRule = $ruleNames
        if ($Params.ContainsKey('ExcludeRule')) {
            $partition.ExcludeRule = @($Params['ExcludeRule']) + $ruleNames
        }
        $partitions.Add($partition)
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $firstPartition = $true
    foreach ($partition in $partitions) {
        foreach ($diagnostic in @(Invoke-ScriptAnalyzer @partition)) {
            $isParserDiagnostic = $diagnostic -is [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord] -and
                $diagnostic.Severity -eq 'ParseError'
            if ($firstPartition -or -not $isParserDiagnostic) {
                $results.Add($diagnostic)
            }
        }
        $firstPartition = $false
    }
    return $results.ToArray()
}

function script:Invoke-ScriptAnalyzerWithRetry {
    param(
        [Parameter(Mandatory)] [hashtable] $Params
    )

    $max = if ($env:AVM_LINT_MAX_ATTEMPTS) { [int]$env:AVM_LINT_MAX_ATTEMPTS } else { 8 }
    if ($max -lt 1) { $max = 1 }

    for ($attempt = 1; $attempt -le $max; $attempt++) {
        try {
            return Invoke-ScriptAnalyzerSerial -Params $Params
        }
        catch {
            $retryReason = $null
            $ex = $_.Exception
            while ($ex) {
                if ($ex -is [System.NullReferenceException] -or
                    $ex.Message -match 'Object reference not set to an instance of an object') {
                    $retryReason = 'threw NullReferenceException'
                    break
                }
                if ($ex -is [System.Management.Automation.CommandNotFoundException] -and
                    $ex.CommandName -ceq 'Get-Command') {
                    $retryReason = 'could not resolve Get-Command'
                    break
                }
                $ex = $ex.InnerException
            }
            if (-not $retryReason -or $attempt -eq $max) { throw }
            Write-Information ("PSScriptAnalyzer {0} on attempt {1}/{2}; retrying." -f $retryReason, $attempt, $max) -InformationAction Continue
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
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

# Returns the absolute path of the NUnit test-result file for a given tier,
# creating out/test-results/ on demand. Pester writes this file when
# TestResult is enabled; the CI workflows upload it as a build artifact so the
# results are downloadable and machine-readable per run. out/ is gitignored.
function script:Get-AvmTestResultPath {
    param(
        [Parameter(Mandatory)] [string] $Tier
    )
    $dir = Join-Path $script:outRoot 'test-results'
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    Join-Path $dir ("{0}.xml" -f $Tier)
}

function script:Get-AvmScopedTestFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('Unit', 'Component')] [string] $Tier,
        [ValidateSet('All', 'Authoring', 'RepositoryManagement')] [string] $Group = 'All'
    )

    $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.Tests.ps1' -File -Recurse |
        Where-Object {
            $relative = [System.IO.Path]::GetRelativePath($Path, $_.FullName).Replace('\', '/')
            $repositoryTest = $Tier -eq 'Unit' ?
                $relative -clike 'RepositoryManagement/*' :
                $relative -cmatch '^(BicepModuleIdentities|BicepTestTenantSync|ModuleCatalog|Repository|TerraformCodeowners)[^/]*\.Tests\.ps1$'
            $sharedTest = $Tier -eq 'Unit' -and $relative -ceq 'Module/TerraformInitUpgrade.Tests.ps1'
            $workflowTest = $Tier -eq 'Unit' -and $relative -clike 'Workflows/*'
            $Group -eq 'All' -or $sharedTest -or
                ($Group -eq 'RepositoryManagement' -and $repositoryTest) -or
                ($Group -eq 'Authoring' -and -not $repositoryTest -and -not $workflowTest)
        } | Sort-Object -Property FullName)
    if ($files.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new("No $Tier test files found for group '$Group' in '$Path'.")
    }
    $files
}

. (Join-Path $PSScriptRoot 'AvmPesterSharding.ps1')

# --- tasks ------------------------------------------------------------------

task layout {
    # Reuse the in-module helper so the build, CI, and any future integration
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
    script:Import-AvmBuildPester
    script:Assert-Module -Name 'PSScriptAnalyzer'

    $params = @{
        Path    = $script:moduleRoot
        Recurse = $true
    }
    if (Test-Path -LiteralPath $script:settingsPath) {
        $params.Settings = $script:settingsPath
    }

    # Custom PSSA rules ship under src/Avm.Authoring/Resources/CustomRules/.
    # Each rule is a Measure-Avm* function in a .psm1 module file. Pointing
    # -CustomRulePath at the directory loads every rule module under it.
    $customRulesPath = Join-Path $script:moduleRoot 'Resources' 'CustomRules'
    if (Test-Path -LiteralPath $customRulesPath) {
        $params.CustomRulePath        = $customRulesPath
        $params.RecurseCustomRulePath = $true
    }

    $results = script:Invoke-ScriptAnalyzerWithRetry -Params $params

    if (-not $results) {
        Write-Build Green '  lint OK: no findings'
        return
    }

    $results | Format-Table -AutoSize | Out-String | Write-Host

    $errors   = @($results | Where-Object { $_.Severity -in @('Error', 'ParseError') })
    $warnings = @($results | Where-Object { $_.Severity -eq 'Warning' })
    $information = @($results | Where-Object { $_.Severity -eq 'Information' })

    if ($errors.Count -gt 0) {
        throw "PSScriptAnalyzer reported $($errors.Count) error(s)."
    }
    if ($warnings.Count -gt 0) {
        throw "PSScriptAnalyzer reported $($warnings.Count) warning(s)."
    }
    if ($information.Count -gt 0) {
        throw "PSScriptAnalyzer reported $($information.Count) informational finding(s)."
    }
}

task 'test-repository-management' {
    script:Import-AvmBuildPester
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $script:testsRoot 'Unit' 'RepositoryManagement'
    $config.Run.PassThru = $true
    $config.Run.Exit = $false
    $config.Output.Verbosity = 'Detailed'
    $config.Output.StackTraceVerbosity = 'Full'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = script:Get-AvmTestResultPath -Tier 'repository-management'
    $result = script:Invoke-AvmPester -Configuration $config
    if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) {
        throw 'Repository management tests failed.'
    }
}

task infra {
    $infraRoot = Join-Path $script:repoRoot 'infra'
    $initArguments = @('init', '-backend=false', '-input=false')
    foreach ($arguments in @(
        @('fmt', '-check', '-diff'),
        $initArguments,
        @('validate', '-no-color')
    )) {
        & terraform "-chdir=$infraRoot" @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform state bootstrap validation failed: $($arguments[0])."
        }
    }
    Write-Build Green '  infra OK: Terraform AVM bootstrap validated (no deployment)'
}

. (Join-Path $script:repoRoot 'repository-management' 'repository-management.build.ps1')

task test {
    script:Import-AvmBuildPester

    $unitPath = Join-Path $script:testsRoot 'Unit'
    if (-not (Test-Path -LiteralPath $unitPath)) {
        Write-Build Yellow "  no unit tests found at $unitPath"
        return
    }

    $unitFiles = @(Get-AvmScopedTestFile -Path $unitPath -Tier Unit -Group $TestGroup)
    $config = New-PesterConfiguration
    $config.Run.Path                = @($unitFiles.FullName)
    $config.Run.PassThru            = $true
    $config.Run.Exit                = $false
    $config.Output.Verbosity        = 'Detailed'
    $config.TestResult.Enabled      = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath   = script:Get-AvmTestResultPath -Tier 'unit'
    $config.Filter.ExcludeTag       = @('Integration', 'Component')

    $shardCount = script:Get-AvmPesterShardCount -Tier 'unit'
    if ($script:testNameFilter.Count -gt 0 -or $shardCount -eq 1) {
        script:Clear-AvmTierTestResult -Tier 'unit'
        $result = script:Invoke-AvmPester -Configuration $config
    }
    else {
        $result = @(
            script:Invoke-AvmPesterShardedTier -Tier 'unit' -File $unitFiles -ShardCount $shardCount
        )[-1]
        if ($result.TotalCount -eq 0) {
            throw "No unit tests ran from $unitPath."
        }
    }
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) Pester test(s) failed."
    }
}

task coverage {
    script:Import-AvmBuildPester

    $unitPath = Join-Path $script:testsRoot 'Unit'
    if (-not (Test-Path -LiteralPath $unitPath)) {
        Write-Build Yellow "  no unit tests found at $unitPath"
        return
    }

    $coverageOut = Join-Path $script:outRoot 'coverage'
    if (-not (Test-Path -LiteralPath $coverageOut)) {
        $null = New-Item -ItemType Directory -Path $coverageOut -Force
    }

    $unitFiles = @(Get-AvmScopedTestFile -Path $unitPath -Tier Unit -Group $TestGroup | Where-Object {
            $relative = [System.IO.Path]::GetRelativePath($unitPath, $_.FullName).Replace('\', '/')
            $relative -cnotlike 'Workflows/*'
        })
    $componentCoverage = @(
        'TerraformCheckPolicy.Component.Tests.ps1'
        'TerraformTransform.Component.Tests.ps1'
        'TerraformUnitTestMigration.Component.Tests.ps1'
        'TerraformUtilityMigration.Component.Tests.ps1'
    )
    $componentFiles = @(Get-AvmScopedTestFile -Path (Join-Path $script:testsRoot 'Component') -Tier Component -Group $TestGroup |
        Where-Object Name -CIn $componentCoverage)
    $config = New-PesterConfiguration
    $config.Run.Path                           = @($unitFiles.FullName) + @($componentFiles.FullName)
    $config.Run.PassThru                       = $true
    $config.Run.Exit                           = $false
    $config.Output.Verbosity                   = if ($env:AVM_COVERAGE_VERBOSE -eq '1') { 'Detailed' } else { 'Minimal' }
    $config.Filter.ExcludeTag                  = @('Integration', 'Qualification')
    $config.TestResult.Enabled                 = $true
    $config.TestResult.OutputFormat            = 'NUnitXml'
    $config.TestResult.OutputPath              = script:Get-AvmTestResultPath -Tier 'unit'
    script:Clear-AvmTierTestResult -Tier 'unit'
    $config.CodeCoverage.Enabled               = $true
    $config.CodeCoverage.Path                  = @(
        (Join-Path $script:moduleRoot 'Public'),
        (Join-Path $script:moduleRoot 'Private')
    )
    $config.CodeCoverage.OutputFormat          = 'Cobertura'
    $config.CodeCoverage.OutputPath            = (Join-Path $coverageOut 'coverage.cobertura.xml')
    $config.CodeCoverage.OutputEncoding        = 'UTF8'
    # Set Pester's own target so its run-end summary matches our floor; the
    # hard gate below is what actually fails the build.
    $config.CodeCoverage.CoveragePercentTarget = $script:coverageFloor

    $result = script:Invoke-AvmPester -Configuration $config
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

task 'test-workflows' {
    script:Import-AvmBuildPester

    if (-not (Test-Path -LiteralPath $script:workflowUnitTestsRoot)) {
        Write-Build Yellow "  no workflow unit tests found at $script:workflowUnitTestsRoot"
        return
    }

    $config = New-PesterConfiguration
    $config.Run.Path                = $script:workflowUnitTestsRoot
    $config.Run.PassThru            = $true
    $config.Run.Exit                = $false
    $config.Output.Verbosity        = 'Detailed'
    $config.TestResult.Enabled      = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath   = script:Get-AvmTestResultPath -Tier 'workflow-unit'
    $config.Filter.ExcludeTag       = @('Integration', 'Component')

    $result = script:Invoke-AvmPester -Configuration $config
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) workflow Pester test(s) failed."
    }
}

task build layout, {
    $stage = Join-Path $script:outRoot 'Avm.Authoring'
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ProgressAction SilentlyContinue
    }
    $null = New-Item -ItemType Directory -Path $stage -Force

    # Copy everything except scratch and test scaffolding into the staged tree.
    Copy-Item `
        -Path (Join-Path $script:moduleRoot '*') `
        -Destination $stage `
        -Recurse `
        -Force `
        -ProgressAction SilentlyContinue

    $stagedManifest = Join-Path $stage 'Avm.Authoring.psd1'

    # Verify the staged manifest still loads cleanly.
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
        Remove-Item -LiteralPath $script:outRoot -Recurse -Force -ProgressAction SilentlyContinue
    }
    Write-Build Green '  clean OK'
}

task docs {
    & $script:cmdletDocsGenerator
    Write-Build Green '  docs OK: generated docs/reference'
}

task 'docs-check' {
    & $script:cmdletDocsGenerator -Check
    Write-Build Green '  docs-check OK: generated reference is current'
}

# Spec section 18 Component tier: real FS + real subprocess, stub binaries on
# PATH, no network. Tests live under tests/Pester/Component/ and are tagged
# `Component` so they are excluded from `test` / `coverage` (which run the Unit
# tier only). This task runs them in isolation, with no coverage instrumentation
# -- the coverage floor is a Unit-tier contract.
task component {
    script:Import-AvmBuildPester

    $componentPath = Join-Path $script:testsRoot 'Component'
    if (-not (Test-Path -LiteralPath $componentPath)) {
        Write-Build Yellow "  no component tests found at $componentPath"
        return
    }

    $componentFiles = @(Get-AvmScopedTestFile -Path $componentPath -Tier Component -Group $TestGroup)

    $config = New-PesterConfiguration
    $config.Run.Path                = @($componentFiles.FullName)
    $config.Run.PassThru            = $true
    $config.Run.Exit                = $false
    $config.Output.Verbosity        = 'Detailed'
    $config.TestResult.Enabled      = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath   = script:Get-AvmTestResultPath -Tier 'component'
    $config.Filter.Tag              = @('Component')

    $shardCount = script:Get-AvmPesterShardCount -Tier 'component'
    if ($script:testNameFilter.Count -gt 0 -or $shardCount -eq 1) {
        if ($script:testNameFilter.Count -gt 0) {
            Write-Build Gray '  component : using single-process runner because -TestName is active'
        }
        else {
            Write-Build Gray '  component : using single-process runner because AVM_COMPONENT_SHARD_COUNT is 1'
        }
        script:Clear-AvmTierTestResult -Tier 'component'
        $result = script:Invoke-AvmPester -Configuration $config
    }
    else {
        $result = @(
            script:Invoke-AvmPesterShardedTier `
                -Tier 'component' `
                -File $componentFiles `
                -ShardCount $shardCount
        )[-1]
    }

    if ($result.TotalCount -eq 0) {
        throw "No Component-tagged tests ran from $componentPath. Tag your It / Describe with -Tag 'Component'."
    }
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) Component test(s) failed."
    }
    Write-Build Green "  component OK: $($result.PassedCount) passed, $($result.SkippedCount) skipped"
}

task integration build, {
    script:Import-AvmBuildPester

    $integrationPath = Join-Path $script:testsRoot 'Integration'
    if (-not (Test-Path -LiteralPath $integrationPath)) {
        Write-Build Yellow "  no integration tests found at $integrationPath"
        return
    }

    $config = New-PesterConfiguration
    $config.Run.Path                = @(Get-AvmIntegrationTestFile -Path $integrationPath -Group $IntegrationGroup)
    $config.Run.PassThru            = $true
    $config.Run.Exit                = $false
    $config.Output.Verbosity        = 'Detailed'
    $config.TestResult.Enabled      = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath   = script:Get-AvmTestResultPath -Tier 'integration'
    $config.Filter.Tag              = @('Integration')

    $result = script:Invoke-AvmPester -Configuration $config
    if ($result.TotalCount -eq 0) {
        throw "No Integration-tagged tests ran from $integrationPath. Tag your It / Describe with -Tag 'Integration'."
    }
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) Integration test(s) failed."
    }
    Write-Build Green "  integration OK: $($result.PassedCount) passed, $($result.SkippedCount) skipped"
}

task qualification build, {
    script:Import-AvmBuildPester
    if ($env:AVM_OFFLINE -eq '1') {
        throw 'Qualification requires verified native tools and package downloads; do not run it with AVM_OFFLINE=1.'
    }
    $path = Join-Path $script:testsRoot 'Qualification'
    if ($QualificationGroup -cne 'All') { $path = Join-Path $path $QualificationGroup }
    $files = @(Get-ChildItem -LiteralPath $path -Filter '*.Tests.ps1' -File -Recurse)
    if ($files.Count -eq 0) { throw "No qualification tests found in '$path'." }
    $config = New-PesterConfiguration
    $config.Run.Path = @($files.FullName)
    $config.Run.PassThru = $true
    $config.Run.Exit = $false
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = script:Get-AvmTestResultPath -Tier 'qualification'
    $config.Filter.Tag = @('Qualification')
    $result = script:Invoke-AvmPester -Configuration $config
    if ($result.TotalCount -eq 0 -or $result.FailedCount -gt 0 -or $result.SkippedCount -gt 0) {
        throw "Qualification did not fully pass: $($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped."
    }
    Write-Build Green "  qualification OK: $($result.PassedCount) passed"
}

task 'pre-commit' 'docs-check', layout, lint, test, component

# CI runs unit and component matrices independently so both tiers can use the
# full job-level parallelism. The combined task remains for local parity.
task 'ci-unit' 'docs-check', layout, test
task 'ci-coverage' 'docs-check', layout, coverage
task 'ci-component' component
task 'ci-tests' 'docs-check', layout, test, component
task ci 'docs-check', layout, lint, coverage, component

task . layout
