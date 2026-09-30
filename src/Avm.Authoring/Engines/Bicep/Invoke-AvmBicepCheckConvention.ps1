function Invoke-AvmBicepCheckConvention {
    <#
    .SYNOPSIS
        Run convention checks against a Bicep module.

    .DESCRIPTION
        Checks layout, versions, changelogs, compiled ARM templates, and e2e
        test sources across root and child modules without modifying them.
        Other registry checks still require a failing coverage issue even
        when every implemented rule passes.

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

    $serviceShortIndex = @{}
    if ($scopes.Count -gt 0) {
        foreach ($testFile in @(Get-ChildItem -LiteralPath $scopes[0].RepositoryRoot -File -Recurse -Filter 'main.test.bicep' |
                    Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })) {
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
            foreach ($issue in @(Test-AvmBicepConventionCompiledTemplate -Root $Context.Root `
                        -Scope $sourceFile.Scope -Template $template -SourcePath $sourceFile.Path)) {
                $issues.Add($issue)
            }
        }
    }

    foreach ($scope in $scopes) {
        foreach ($issue in @(Test-AvmBicepConventionLayout -Root $Context.Root -Scope $scope)) {
            $issues.Add($issue)
        }
        foreach ($issue in @(Test-AvmBicepConventionVersion -Root $Context.Root -Scope $scope)) {
            $issues.Add($issue)
        }
        foreach ($issue in @(Test-AvmBicepConventionTestFile -Root $Context.Root `
                    -Scope $scope -ServiceShortIndex $serviceShortIndex `
                    -CompiledTestFiles $compiledTests)) {
            $issues.Add($issue)
        }
    }

    $uncovered = @(
        'workflow and CODEOWNERS checks'
        'publication-aware changelog and parent/child version checks'
        'README regeneration and API-version checks'
        'child publish allowlist and resource-folder singularization'
        'registry-literal telemetry syntax and description parity for scaffolded modules'
        'checked-in main.json drift for children under modules/'
    )
    $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root -Path $Context.Root `
                -Code 'avm.bicep.convention-incomplete' `
                -Message ("Bicep convention coverage is incomplete: {0}. Keep the registry compliance job until these checks are implemented." -f ($uncovered -join '; '))))

    return [pscustomobject][ordered]@{
        Engine            = 'bicep'
        Tool              = 'avm-bicep-convention/1'
        ToolPath          = $null
        ToolSource        = 'builtin'
        Status            = 'fail'
        ScopesChecked     = $scopes.Count
        CompiledFiles     = $compiledCount
        CompilerSource    = if ($null -ne $tool) { $tool.Source } else { 'not-run' }
        UncoveredFamilies = $uncovered
        Issues            = $issues.ToArray()
    }
}
