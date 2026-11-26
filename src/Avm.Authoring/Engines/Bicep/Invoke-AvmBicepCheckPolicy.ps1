function Invoke-AvmBicepCheckPolicy {
    <#
    .SYNOPSIS
        Evaluate the Bicep module's selected tests with PSRule for Azure.

    .DESCRIPTION
        Uses the package's PSRule options and rule/suppression directory
        to evaluate defaults and waf-aligned e2e tests with baselines classified
        by module type. Reliability and AVM WAF Security are required for
        resources and advisory for patterns and utilities. Default and Security
        remain advisory. Files are tokenized in a temporary tree;
        original module files are never changed. Missing custom tokens, tools,
        baselines, or uninspectable results fail the check.

        The PSRule and PSRule.Rules.Azure versions pinned in avm.pins.jsonc are
        exact-version dependencies resolved through the shared tool cache.
        Missing modules are acquired before evaluation. Tokens are read from
        VALIDATE_SUBSCRIPTION_IDS or its TEST_SUBSCRIPTION_IDS alias (first
        entry matching the exact root reservation map), with
        VALIDATE_SUBSCRIPTION_ID as a General-only fallback, VALIDATE_TENANT_ID,
        VALIDATE_MANAGEMENT_GROUP_ID (or ARM_MGMTGROUP_ID), and localToken_*
        environment variables. Without configured IDs, offline policy uses
        public placeholders:
        subscriptionId 11111111-1111-4111-8111-111111111111, tenantId
        22222222-2222-4222-8222-222222222222 and managementGroupId avm-policy.
        These are template-expansion values, not verified Azure targets;
        policy checks never authenticate or query Azure. The same defaults
        apply to reserved modules without subscription configuration, but
        configured pools still require an exact matching tag. namePrefix
        defaults to 'gci'; localToken_* values override policy tokens.
        These defaults are policy-only and never supply deployment inputs.

    .PARAMETER Context
        Bicep module context produced by Get-AvmModuleContext.

    .PARAMETER AllowPathFallback
        Permit a PATH-resolved Bicep CLI matching the pinned version.

    .PARAMETER Example
        Exact module-relative paths from the discovered policy tests.

    .PARAMETER Baseline
        Exact names from the four supported required and advisory baselines.

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

        [switch] $AllowPathFallback,

        [ValidateNotNullOrEmpty()]
        [string[]] $Example,

        [ValidateNotNullOrEmpty()]
        [string[]] $Baseline
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmBicepCheckPolicy requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $allBaselines = @(
        'Azure.Pillar.Reliability',
        'CB.AVM.WAF.Security',
        'Azure.Default',
        'Azure.Pillar.Security'
    )
    $selectedBaselines = $allBaselines
    if ($PSBoundParameters.ContainsKey('Baseline')) {
        foreach ($name in $Baseline) {
            if ($allBaselines -cnotcontains $name) {
                throw [AvmConfigurationException]::new(
                    '-Baseline must select exact supported Bicep policy baseline names.')
            }
        }
        $selectedBaselines = @($allBaselines | Where-Object { $Baseline -ccontains $_ })
    }
    $baselines = @($selectedBaselines | ForEach-Object {
            [pscustomobject]@{ Name = $_ }
        })
    $issues = [System.Collections.Generic.List[object]]::new()
    $evaluations = [System.Collections.Generic.List[object]]::new()
    $tests = [System.Collections.Generic.List[object]]::new()
    $testModulePaths = @{}
    $testModuleTypes = @{}
    $moduleTypeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
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
        $null = $moduleTypeSet.Add($scope.ModuleType)
        try {
            foreach ($file in @(Get-AvmBicepPolicyTestFile -ModulePath $scope.Path `
                        -IncludeAllExamples:($PSBoundParameters.ContainsKey('Example')))) {
                if ($seen.Add($file.FullName)) {
                    $tests.Add($file)
                    $testModulePaths[$file.FullName] = $scope.ModuleRelativePath
                    $testModuleTypes[$file.FullName] = $scope.ModuleType
                }
            }
        }
        catch {
            & $addFailure $_ $module.Path 'avm.bicep.psrule-input' ([AvmConfigurationException]) `
                "PSRule could not select test sources ($($_.Exception.GetType().Name))."
        }
    }
    $moduleTypes = @($moduleTypeSet | Sort-Object)
    $required = @($selectedBaselines | Where-Object {
            $baselineName = $_
            @($moduleTypes | Where-Object {
                    (Get-AvmRequiredPolicyBaseline -ModuleType $_) -cnotcontains $baselineName
                }).Count -eq 0 -and $moduleTypes.Count -gt 0
        })
    $advisory = @($selectedBaselines | Where-Object { $required -cnotcontains $_ })
    if ($PSBoundParameters.ContainsKey('Example')) {
        $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($path in $Example) {
            $relative = $path.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($relative) -or
                [System.IO.Path]::IsPathRooted($relative) -or
                $relative -match '[:\x00-\x1f*?\[\]]' -or
                $relative.Split('/') -contains '..') {
                throw [AvmConfigurationException]::new(
                    '-Example must contain literal module-relative policy test paths without parent segments.')
            }
            $matched = @($tests | Where-Object {
                    [System.IO.Path]::GetRelativePath($Context.Root, $_.FullName).Replace('\', '/') -ceq $relative
                })
            if ($matched.Count -ne 1) {
                throw [AvmConfigurationException]::new(
                    "Policy example '$relative' did not match exactly one discovered e2e main.test.bicep file.")
            }
            $null = $selected.Add($matched[0].FullName)
        }
        $tests = [System.Collections.Generic.List[object]]@($tests | Where-Object { $selected.Contains($_.FullName) })
    }
    if ($tests.Count -eq 0) {
        $message = 'No required Bicep E2E main.test.bicep sources were selected for PSRule.'
        if ($moduleTypes.Count -gt 0) {
            $configuration = Get-AvmE2eScenarioConfiguration
            $displayNames = @($moduleTypes | ForEach-Object {
                    [string]$configuration['moduleTypes'][$_]['displayName']
                })
            $scenarioNames = @($moduleTypes | ForEach-Object {
                    Get-AvmRequiredE2eScenario -ModuleType $_
                } | Sort-Object -Unique)
            $requiredText = if ($scenarioNames.Count -eq 1) {
                $scenarioNames[0]
            }
            else {
                ($scenarioNames[0..($scenarioNames.Count - 2)] -join ', ') + " or $($scenarioNames[-1])"
            }
            $moduleText = if ($displayNames.Count -eq 1) {
                "the $($displayNames[0]) module"
            }
            else {
                "the $($displayNames -join ', ') modules"
            }
            $message = "No $requiredText main.test.bicep sources were selected for $moduleText."
        }
        $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root -Path $Context.Root `
                    -Code 'avm.bicep.psrule-input-missing' `
                    -Message $message))
    }

    $tool = $null
    $compiler = $null
    $configuration = $null
    $verified = @{}
    if ($issues.Count -eq 0) {
        try {
            $tool = Import-AvmBicepPolicyModule -ModuleRoot $Context.Root
        }
        catch {
            & $addFailure $_ $Context.Root 'avm.bicep.psrule-module' ([AvmConfigurationException]) `
                'Required PSRule module versions could not be loaded.'
        }
    }
    if ($issues.Count -eq 0) {
        try {
            $configuration = Get-AvmBicepPolicyConfiguration
        }
        catch {
            & $addFailure $_ $Context.Root 'avm.bicep.psrule-config' ([AvmConfigurationException]) `
                'PSRule configuration could not be loaded; inspect ps-rule.yaml and the installed modules.'
        }
    }
    if ($issues.Count -eq 0) {
        foreach ($baselineDefinition in $baselines) {
            try {
                $verified[$baselineDefinition.Name] = Get-AvmBicepPolicyBaseline `
                    -Configuration $configuration -Name $baselineDefinition.Name
            }
            catch {
                & $addFailure $_ $Context.Root 'avm.bicep.psrule-baseline' ([AvmConfigurationException]) `
                    "PSRule baseline '$($baselineDefinition.Name)' could not be inspected." $baselineDefinition.Name
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
            $compiler = Resolve-AvmTool -Name 'bicep' -ModuleRoot $Context.Root -AllowPathFallback:$AllowPathFallback
        }
        catch {
            $knownCompilerFailure = [type[]]@([AvmToolException], [AvmConfigurationException])
            & $addFailure $_ $Context.Root 'avm.bicep.psrule-compiler' $knownCompilerFailure `
                'The pinned Bicep compiler could not be resolved.'
        }
    }

    if ($issues.Count -eq 0) {
        $previousBicep = [Environment]::GetEnvironmentVariable('PSRULE_AZURE_BICEP_PATH')
        try {
            $env:PSRULE_AZURE_BICEP_PATH = $compiler.Path
            foreach ($test in @($tests | Sort-Object -Culture 'en-US' -Property FullName)) {
                try {
                    $tokens = Get-AvmBicepPolicyToken -RepositoryRoot $repositoryRoot `
                        -ModulePath $testModulePaths[$test.FullName]
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
                    foreach ($baselineDefinition in $baselines) {
                        $baselineRequired = (Get-AvmRequiredPolicyBaseline `
                                -ModuleType $testModuleTypes[$test.FullName]) -ccontains $baselineDefinition.Name
                        try {
                            $records = @(Invoke-AvmBicepPolicyBaseline `
                                    -StageRoot $stage.FullName -InputPath $relative `
                                    -OptionPath $configuration.OptionPath `
                                    -RulePath $configuration.RulePath `
                                    -Baseline $baselineDefinition.Name)
                            $result = ConvertFrom-AvmBicepPolicyResult -Records $records `
                                -Baseline $verified[$baselineDefinition.Name] `
                                -StagePath $stagePath `
                                -SourcePath $test.FullName -ModuleRoot $Context.Root
                            foreach ($issue in $result.Issues) { $issues.Add($issue) }
                            if (-not $result.Valid) { continue }
                            foreach ($record in $records) {
                                Write-AvmLog ("PSRule [{0}] {1}: {2} ({3})" -f
                                    $baselineDefinition.Name, $record.RuleName, $record.Outcome, $record.TargetType) -Level Verbose
                            }
                            $evaluations.Add([pscustomobject]@{
                                    File            = [System.IO.Path]::GetRelativePath(
                                        $Context.Root, $test.FullName).Replace('\', '/')
                                    ModuleType      = $testModuleTypes[$test.FullName]
                                    Baseline        = $baselineDefinition.Name
                                    Required        = $baselineRequired
                                    Records         = $records.Count
                                    ExpandedRecords = $result.ExpandedRecords
                                    ProcessedRules  = $result.ProcessedRules
                                    FailedRules     = $result.Failures.Count
                                })
                            foreach ($failure in $result.Failures) {
                                $severity = if ($baselineRequired) { 'error' } else { 'warning' }
                                $message = "PSRule baseline '$($baselineDefinition.Name)' failed rule '$($failure.RuleName)' for target type '$($failure.TargetType)'."
                                $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root `
                                            -Path $test.FullName -Baseline $baselineDefinition.Name `
                                            -RuleName $failure.RuleName -TargetType $failure.TargetType `
                                            -Severity $severity -Code 'avm.bicep.psrule-rule' `
                                            -Message $message))
                            }
                        }
                        catch {
                            $message = "PSRule baseline '$($baselineDefinition.Name)' could not evaluate this tokenized Bicep test ($($_.Exception.GetType().Name)); verify the source and configuration."
                            $issues.Add((New-AvmBicepPolicyIssue -Root $Context.Root `
                                        -Path $test.FullName -Baseline $baselineDefinition.Name `
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
