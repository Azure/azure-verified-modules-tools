function Invoke-AvmBicepCheckConvention {
    <#
    .SYNOPSIS
        Run convention checks against a Bicep module.

    .DESCRIPTION
        Checks file layout, changelogs, version files, and e2e test source
        across the selected root and child modules without modifying them.
        The registry compliance suite also checks compiled templates,
        workflows, API versions, and publication state. Until those checks
        are covered, the engine returns a failing coverage issue even when
        every implemented rule passes.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Accepted for dispatcher compatibility; these rules need no tool.

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

    $null = $AllowPathFallback

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
        foreach ($testFile in @(Get-ChildItem -LiteralPath $scopes[0].RepositoryRoot -File -Recurse -Filter 'main.test.bicep')) {
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

    foreach ($scope in $scopes) {
        foreach ($issue in @(Test-AvmBicepConventionLayout -Root $Context.Root -Scope $scope)) {
            $issues.Add($issue)
        }
        foreach ($issue in @(Test-AvmBicepConventionVersion -Root $Context.Root -Scope $scope)) {
            $issues.Add($issue)
        }
        foreach ($issue in @(Test-AvmBicepConventionTestFile -Root $Context.Root `
                    -Scope $scope -ServiceShortIndex $serviceShortIndex)) {
            $issues.Add($issue)
        }
    }

    $uncovered = @(
        'workflow and CODEOWNERS checks'
        'compiled ARM schema, parameter, UDT, output and telemetry checks'
        'publication-aware changelog and parent/child version checks'
        'README regeneration and API-version checks'
        'child publish allowlist and compiled e2e-test checks'
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
        UncoveredFamilies = $uncovered
        Issues            = $issues.ToArray()
    }
}
