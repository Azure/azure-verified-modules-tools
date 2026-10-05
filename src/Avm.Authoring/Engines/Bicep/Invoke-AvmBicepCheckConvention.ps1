function Invoke-AvmBicepCheckConvention {
    <#
    .SYNOPSIS
        Run convention checks against a Bicep module.

    .DESCRIPTION
        Checks layout, versions, changelogs, compiled ARM templates, checked-in
        main.json drift, e2e test sources, workflows, and CODEOWNERS across root
        and child modules without modifying them. The separate required docs
        step in pr-check checks README regeneration and render completeness.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Permit a PATH-resolved Bicep CLI matching the pinned version.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        UncoveredFamilies, and Issues.
    #>
    [CmdletBinding()]
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
            "Invoke-AvmBicepCheckConvention requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $issues = [System.Collections.Generic.List[object]]::new()
    $scopes = [System.Collections.Generic.List[object]]::new()
    foreach ($module in @(Get-AvmMetadataScope -Context $Context -IncludeModuleDirectories)) {
        $scope = Get-AvmBicepConventionScope -Path $module.Path
        if ($null -eq $scope) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root `
                        -Path (Join-Path $module.Path 'main.bicep') -Code 'avm.bicep.scope' `
                        -Message 'Bicep convention checks require modules under avm/res, avm/ptn, or avm/utl.'))
            continue
        }
        $scopes.Add($scope)
    }
    if ($scopes.Count -eq 0 -and $issues.Count -eq 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root `
                    -Path $Context.Root -Code 'avm.bicep.scope' `
                    -Message 'No Bicep module scopes were discovered for convention checks.'))
    }

    $serviceShortIndex = @{}
    if ($scopes.Count -gt 0) {
        $testFiles = @()
        try {
            $testFiles = @(Get-AvmBicepRepositoryTestFile -RepositoryRoot $scopes[0].RepositoryRoot)
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException],
        [System.Management.Automation.ActionPreferenceStopException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root `
                        -Path $scopes[0].RepositoryRoot -Code 'avm.bicep.test-discovery' `
                        -Message "Repository-wide e2e test discovery failed; serviceShort uniqueness cannot be checked: $($_.Exception.Message)"))
        }
        foreach ($testFile in $testFiles) {
            $source = Get-AvmBicepCommentFreeSource -Source ([System.IO.File]::ReadAllText($testFile.FullName))
            $short = [regex]::Match(
                $source, "(?m)^[ \t]*param[ \t]+serviceShort[ \t]+string[ \t]*=[ \t]*'(?<value>[^'\r\n]*)'")
            if (-not $short.Success) {
                continue
            }
            $value = $short.Groups['value'].Value
            if (-not $serviceShortIndex.ContainsKey($value)) {
                $serviceShortIndex[$value] = [System.Collections.Generic.List[string]]::new()
            }
            $serviceShortIndex[$value].Add($testFile.FullName)
        }
    }

    $sources = [System.Collections.Generic.List[object]]::new()
    $compiledModules = [System.Collections.Generic.List[object]]::new()
    $compiledTests = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($scope in $scopes) {
        $main = @(Get-ChildItem -LiteralPath $scope.Path -Force |
                Where-Object { $_.Name -ceq 'main.bicep' })
        if ($main.Count -eq 1 -and -not $main[0].PSIsContainer -and
            -not ($main[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $sources.Add([pscustomobject]@{
                    Path   = $main[0].FullName
                    Scope  = $scope
                    IsTest = $false
                })
        }
        elseif (@($main | Where-Object {
                    $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint
                }).Count -gt 0) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root `
                        -Path (Join-Path $scope.Path 'main.bicep') `
                        -Code 'avm.bicep.compiled-source-file' `
                        -Message 'Linked main.bicep files cannot be compiled for convention checks.'))
        }
        $testsPath = Join-Path $scope.Path 'tests'
        if (-not (Test-Path -LiteralPath $testsPath -PathType Container)) {
            continue
        }
        foreach ($testFile in @(Get-ChildItem -LiteralPath $testsPath -File -Recurse -Filter 'main.test.bicep')) {
            if ($testFile.Name -cne 'main.test.bicep' -or
                ($testFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root `
                            -Path $testFile.FullName -Code 'avm.bicep.test-source-file' `
                            -Message 'An e2e test source must be a regular main.test.bicep with exact casing.'))
                continue
            }
            $sources.Add([pscustomobject]@{
                    Path   = $testFile.FullName
                    Scope  = $scope
                    IsTest = $true
                })
        }
    }

    $tool = $null
    $compiledCount = 0
    if ($sources.Count -gt 0) {
        try {
            $tool = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback
        }
        catch [AvmToolException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root `
                        -Path $Context.Root -Code 'avm.bicep.compiler-unavailable' `
                        -Message "Compiled checks could not run: $($_.Exception.Message)"))
        }
        catch [AvmConfigurationException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root `
                        -Path $Context.Root -Code 'avm.bicep.compiler-unavailable' `
                        -Message "Compiled checks could not run: $($_.Exception.Message)"))
        }
    }
    if ($null -ne $tool) {
        foreach ($sourceFile in $sources) {
            $template = $null
            try {
                $json = Get-AvmBicepCompiledJson -SourcePath $sourceFile.Path -ToolPath $tool.Path
                $template = $json | ConvertFrom-Json -AsHashtable -Depth 1024 -ErrorAction Stop
            }
            catch [AvmConfigurationException] {
                $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root `
                            -Path $sourceFile.Path -Code 'avm.bicep.compile' `
                            -Message $_.Exception.Message))
                continue
            }
            catch [AvmProcessException] {
                $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root `
                            -Path $sourceFile.Path -Code 'avm.bicep.compile' `
                            -Message $_.Exception.Message))
                continue
            }
            $compiledCount++
            if ($sourceFile.IsTest) {
                $compiledTests[$sourceFile.Path] = $template
                continue
            }
            $compiledModules.Add([pscustomobject]@{
                    Path     = $sourceFile.Path
                    Scope    = $sourceFile.Scope
                    Template = $template
                    Json     = $json
                })
        }
    }
    $apiSpecs = $null
    $apiSpecsUnavailableReason = ''
    if ($compiledModules.Count -gt 0) {
        try {
            $apiSpecs = Get-AvmBicepApiSpecList
        }
        catch [AvmConfigurationException] {
            $apiSpecsUnavailableReason = $_.Exception.Message
        }
    }
    $repositoryRoot = if ($scopes.Count -gt 0) { $scopes[0].RepositoryRoot } else { $Context.Root }
    $workflows = @(foreach ($scope in $scopes) {
            if ($scope.IsTopLevel) {
                [pscustomobject]@{ Scope = $scope; Input = Get-AvmBicepConventionWorkflowInput -Scope $scope }
            }
        })
    $publication = if ($scopes.Count -gt 0) {
        Get-AvmBicepPublicationInput -RepositoryRoot $repositoryRoot -Scopes $scopes.ToArray()
    }
    $convention = @{
        Root                      = $Context.Root
        RepositoryRoot            = $repositoryRoot
        Scopes                    = $scopes.ToArray()
        CompiledModules           = $compiledModules.ToArray()
        ApiSpecs                  = $apiSpecs
        ApiSpecsUnavailableReason = $apiSpecsUnavailableReason
        ServiceShortIndex         = $serviceShortIndex
        CompiledTests             = $compiledTests
        Workflows                 = $workflows
        Publication               = $publication
    }
    foreach ($issue in @(Invoke-AvmBicepConventionSuite -Convention $convention)) {
        $issues.Add($issue)
    }
    $status = if (@($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) {
        'fail'
    }
    else { 'pass' }

    return [pscustomobject][ordered]@{
        Engine            = 'bicep'
        Tool              = 'avm-bicep-convention/1'
        ToolPath          = $null
        ToolSource        = 'builtin'
        Status            = $status
        ScopesChecked     = $scopes.Count
        CompiledFiles     = $compiledCount
        CompilerSource    = if ($null -ne $tool) { $tool.Source } else { 'not-run' }
        UncoveredFamilies = @()
        Issues            = $issues.ToArray()
    }
}
