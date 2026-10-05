function Invoke-AvmBicepCheckPolicy {
    <#
    .SYNOPSIS
        Evaluate the Bicep module's selected tests with PSRule for Azure.

    .DESCRIPTION
        Uses the repository's PSRule options and rule/suppression directory
        to evaluate defaults and waf-aligned e2e tests with the required
        Reliability and AVM WAF Security baselines and the advisory Default
        and Security baselines. Files are tokenized in a temporary tree;
        original module files are never changed. Missing inputs, tools,
        baselines, or uninspectable results fail the check.

        The PSRule and PSRule.Rules.Azure versions pinned in avm.pins.jsonc are
        optional, exact-version dependencies loaded only for Bicep policy checks. Install them with
        Install-PSResource before running this command. Tokens are read from
        TEST_SUBSCRIPTION_IDS (first entry) or VALIDATE_SUBSCRIPTION_ID, VALIDATE_TENANT_ID,
        VALIDATE_MANAGEMENT_GROUP_ID (or ARM_MGMTGROUP_ID), TOKEN_NAMEPREFIX,
        and localToken_* environment variables.

    .PARAMETER Context
        Bicep module context produced by Get-AvmModuleContext.

    .PARAMETER AllowPathFallback
        Permit a PATH-resolved Bicep CLI matching the pinned version.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        RequiredBaselines, AdvisoryBaselines, TestsSelected,
        BaselinesExecuted, Evaluations, and Issues.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmBicepCheckPolicy requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $required = @('Azure.Pillar.Reliability', 'CB.AVM.WAF.Security')
    $advisory = @('Azure.Default', 'Azure.Pillar.Security')
    $baselines = @(
        foreach ($name in $required) { [pscustomobject]@{ Name = $name; Required = $true } }
        foreach ($name in $advisory) { [pscustomobject]@{ Name = $name; Required = $false } }
    )
    $issues = [System.Collections.Generic.List[object]]::new()
    $evaluations = [System.Collections.Generic.List[object]]::new()
    $tests = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        $(if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase }
            else { [System.StringComparer]::Ordinal }))
    # Only exceptions of the listed types carry author-facing messages; any
    # other failure is reported with the fixed fallback message.
    $addFailure = {
        param(
            [System.Management.Automation.ErrorRecord] $ErrorRecord,
            [string] $Path,
            [string] $Code,
            [type[]] $KnownType,
            [string] $Fallback,
            [string] $Baseline = ''
        )
        $exception = $ErrorRecord.Exception
        $message = $Fallback
        foreach ($type in $KnownType) {
            if ($exception -is $type) { $message = $exception.Message; break }
        }
        $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root -Path $Path `
                    -Code $Code -Message $message -Baseline $Baseline))
    }
    $repositoryRoot = $null
    $modules = @()
    try {
        $modules = @(Get-AvmMetadataScope -Context $Context -IncludeModuleDirectories)
    }
    catch {
        & $addFailure $_ $Context.Root 'avm.bicep.psrule-input' ([System.ArgumentException]) `
            "PSRule could not enumerate Bicep scopes ($($_.Exception.GetType().Name))."
    }
    foreach ($module in $modules) {
        $scope = Get-AvmBicepConventionScope -Path $module.Path
        if ($null -eq $scope) {
            $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root -Path $module.Path `
                        -Code 'avm.bicep.psrule-input' `
                        -Message 'PSRule requires modules under avm/res, avm/ptn, or avm/utl.'))
            continue
        }
        if ($null -ne $repositoryRoot -and
            $scope.RepositoryRoot -cne $repositoryRoot) {
            $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root -Path $module.Path `
                        -Code 'avm.bicep.psrule-input' `
                        -Message 'PSRule module scopes must share one repository root.'))
            continue
        }
        $repositoryRoot = $scope.RepositoryRoot
        try {
            foreach ($file in @(Get-AvmBicepPolicyTestFile -ModulePath $scope.Path)) {
                if ($seen.Add($file.FullName)) {
                    $tests.Add($file)
                }
            }
        }
        catch {
            & $addFailure $_ $module.Path 'avm.bicep.psrule-input' ([AvmConfigurationException]) `
                "PSRule could not select test sources ($($_.Exception.GetType().Name))."
        }
    }
    if ($tests.Count -eq 0) {
        $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root -Path $Context.Root `
                    -Code 'avm.bicep.psrule-input-missing' `
                    -Message 'No defaults or waf-aligned main.test.bicep sources were selected for PSRule.'))
    }

    $tool = $null
    $compiler = $null
    $configuration = $null
    $verified = @{}
    if ($issues.Count -eq 0) {
        $configPath = Join-Path -Path $repositoryRoot -ChildPath 'utilities' `
            -AdditionalChildPath 'pipelines', 'staticValidation', 'psrule'
        if (-not [System.IO.File]::Exists((Join-Path $configPath 'ps-rule.yaml')) -or
            -not [System.IO.Directory]::Exists((Join-Path $configPath '.ps-rule'))) {
            $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root -Path $Context.Root `
                        -Code 'avm.bicep.psrule-config' `
                        -Message 'PSRule needs the repository utilities/pipelines/staticValidation/psrule/ps-rule.yaml and .ps-rule/ directory.'))
        }
    }
    if ($issues.Count -eq 0) {
        try {
            $tool = Import-AvmBicepPolicyModule
        }
        catch {
            & $addFailure $_ $Context.Root 'avm.bicep.psrule-module' ([AvmConfigurationException]) `
                'Required PSRule module versions could not be loaded.'
        }
    }
    if ($issues.Count -eq 0) {
        try {
            $configuration = Get-AvmBicepPolicyConfiguration -RepositoryRoot $repositoryRoot
        }
        catch {
            & $addFailure $_ $Context.Root 'avm.bicep.psrule-config' ([AvmConfigurationException]) `
                'PSRule configuration could not be loaded; inspect ps-rule.yaml and the installed modules.'
        }
    }
    if ($issues.Count -eq 0) {
        foreach ($baseline in $baselines) {
            try {
                $verified[$baseline.Name] = Get-AvmBicepPolicyBaseline `
                    -Configuration $configuration -Name $baseline.Name
            }
            catch {
                & $addFailure $_ $Context.Root 'avm.bicep.psrule-baseline' ([AvmConfigurationException]) `
                    "PSRule baseline '$($baseline.Name)' could not be inspected." $baseline.Name
            }
        }
    }
    if ($issues.Count -eq 0 -and
        -not $PSCmdlet.ShouldProcess($Context.Root, 'Stage Bicep tests for PSRule evaluation')) {
        $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root -Path $Context.Root `
                    -Code 'avm.bicep.psrule-not-run' `
                    -Message 'PSRule sources were not staged; no baseline ran.'))
    }
    if ($issues.Count -eq 0) {
        try {
            $compiler = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback
        }
        catch {
            $knownCompilerFailure = [type[]]@([AvmToolException], [AvmConfigurationException])
            & $addFailure $_ $Context.Root 'avm.bicep.psrule-compiler' $knownCompilerFailure `
                'The pinned Bicep compiler could not be resolved.'
        }
    }

    if ($issues.Count -eq 0) {
        $tokens = Get-AvmBicepPolicyToken
        $previousBicep = [Environment]::GetEnvironmentVariable('PSRULE_AZURE_BICEP_PATH')
        try {
            $env:PSRULE_AZURE_BICEP_PATH = $compiler.Path
            foreach ($test in @($tests | Sort-Object -Culture 'en-US' -Property FullName)) {
                try {
                    $files = @(Get-AvmBicepPolicySource -Path $test.FullName `
                            -RepositoryRoot $repositoryRoot -Tokens $tokens)
                }
                catch {
                    & $addFailure $_ $test.FullName 'avm.bicep.psrule-source' ([AvmConfigurationException]) `
                        "PSRule could not read a selected test or local reference ($($_.Exception.GetType().Name))."
                    continue
                }

                $stage = $null
                try {
                    $stage = [System.IO.Directory]::CreateTempSubdirectory('avm-psrule-')
                    Copy-AvmBicepPolicySource -Files $files -Destination $stage.FullName
                    $relative = [System.IO.Path]::GetRelativePath(
                        $repositoryRoot, $test.FullName)
                    $stagePath = Join-Path $stage.FullName $relative
                    if (-not [System.IO.File]::Exists($stagePath)) {
                        throw [AvmConfigurationException]::new(
                            'The selected PSRule input was not staged.')
                    }
                    foreach ($baseline in $baselines) {
                        try {
                            $records = @(Invoke-AvmBicepPolicyBaseline `
                                    -StageRoot $stage.FullName -InputPath $relative `
                                    -OptionPath $configuration.OptionPath `
                                    -RulePath $configuration.RulePath `
                                    -Baseline $baseline.Name)
                            $result = ConvertFrom-AvmBicepPolicyResult -Records $records `
                                -Baseline $verified[$baseline.Name] `
                                -StagePath $stagePath `
                                -SourcePath $test.FullName -ModuleRoot $Context.Root
                            foreach ($issue in $result.Issues) { $issues.Add($issue) }
                            if (-not $result.Valid) { continue }
                            $evaluations.Add([pscustomobject]@{
                                    File            = [System.IO.Path]::GetRelativePath(
                                        $Context.Root, $test.FullName).Replace('\', '/')
                                    Baseline        = $baseline.Name
                                    Required        = $baseline.Required
                                    Records         = $records.Count
                                    ExpandedRecords = $result.ExpandedRecords
                                    ProcessedRules  = $result.ProcessedRules
                                    FailedRules     = $result.Failures.Count
                                })
                            foreach ($failure in $result.Failures) {
                                $severity = if ($baseline.Required) { 'error' } else { 'warning' }
                                $message = "PSRule baseline '$($baseline.Name)' failed rule '$($failure.RuleName)' for target type '$($failure.TargetType)'."
                                $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root `
                                            -Path $test.FullName -Baseline $baseline.Name `
                                            -RuleName $failure.RuleName -TargetType $failure.TargetType `
                                            -Severity $severity -Code 'avm.bicep.psrule-rule' `
                                            -Message $message))
                            }
                        }
                        catch {
                            $message = "PSRule baseline '$($baseline.Name)' could not evaluate this tokenized Bicep test ($($_.Exception.GetType().Name)); verify the source and configuration."
                            $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root `
                                        -Path $test.FullName -Baseline $baseline.Name `
                                        -Code 'avm.bicep.psrule-evaluation' `
                                        -Message $message))
                        }
                    }
                }
                catch {
                    $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root -Path $test.FullName `
                                -Code 'avm.bicep.psrule-staging' `
                                -Message 'PSRule could not stage the tokenized Bicep test and its local references.'))
                }
                finally {
                    if ($null -ne $stage) {
                        try {
                            [System.IO.Directory]::Delete($stage.FullName, $true)
                        }
                        catch {
                            $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root `
                                        -Path $test.FullName -Code 'avm.bicep.psrule-cleanup' `
                                        -Message ("PSRule temporary files could not be removed from '{0}'; remove them before retrying." -f $stage.FullName)))
                        }
                    }
                }
            }
        }
        finally {
            if ($null -eq $previousBicep) {
                [Environment]::SetEnvironmentVariable('PSRULE_AZURE_BICEP_PATH', $null)
            }
            else {
                $env:PSRULE_AZURE_BICEP_PATH = $previousBicep
            }
        }
    }

    return [pscustomobject][ordered]@{
        Engine            = 'bicep'
        Tool              = if ($null -ne $tool) { $tool.Name } else { 'PSRule.Rules.Azure (not run)' }
        ToolPath          = if ($null -ne $tool) { $tool.Path } else { $null }
        ToolSource        = if ($evaluations.Count -gt 0) { 'powershell-module' } else { 'not-run' }
        Status            = if (@($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) { 'fail' } else { 'pass' }
        RequiredBaselines = $required
        AdvisoryBaselines = $advisory
        TestsSelected     = $tests.Count
        BaselinesExecuted = $evaluations.Count
        Evaluations       = $evaluations.ToArray()
        Issues            = $issues.ToArray()
    }
}
