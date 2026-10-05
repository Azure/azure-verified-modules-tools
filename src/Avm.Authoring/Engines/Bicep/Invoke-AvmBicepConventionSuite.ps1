function Invoke-AvmBicepConventionSuite {
    <#
    .SYNOPSIS
        Run the packaged Bicep convention Pester suite against prepared input.

    .DESCRIPTION
        Executes Resources/bicep/conventions/Conventions.Tests.ps1 in the current
        process and returns the convention issues it recorded. A rule that throws,
        a suite that cannot run, or a suite that ran fewer tests than expected is
        reported as an error issue rather than a silent pass.

    .OUTPUTS
        Convention issue objects.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        # Prepared suite input; Findings and Crashes are added here.
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Convention
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $root = [string]$Convention.Root
    $Convention.Findings = [System.Collections.Generic.List[object]]::new()
    $Convention.Crashes = [System.Collections.Generic.List[object]]::new()
    $Convention.NativeCompiledExpected = 0
    $Convention.NativeWorkflowExpected = 0
    $Convention.NativeOwnershipExpected = 0
    $suitePath = Join-Path -Path $PSScriptRoot -ChildPath '..' `
        -AdditionalChildPath '..', 'Resources', 'bicep', 'conventions', 'Conventions.Tests.ps1'
    $suitePath = [System.IO.Path]::GetFullPath($suitePath)
    $issues = [System.Collections.Generic.List[object]]::new()

    $compiledCount = @($Convention.CompiledModules).Count
    $scopeCount = @($Convention.Scopes).Count
    $workflowCount = @($Convention.Workflows).Count
    $expected = [int]($compiledCount -gt 0) + (3 * $scopeCount) + (2 * [int]($scopeCount -gt 0))
    if ($expected -eq 0 -and $workflowCount -eq 0) {
        return $issues.ToArray()
    }

    try {
        $Convention.CompiledInputs = @($Convention.CompiledModules | ForEach-Object { Get-AvmBicepCompiledConventionInput -Module $_ })
        $files = @($suitePath)
        if ($compiledCount -gt 0) {
            $files += Join-Path (Split-Path $suitePath) 'Compiled.Tests.ps1'
        }
        if ($workflowCount -gt 0) {
            $files += Join-Path (Split-Path $suitePath) 'Workflow.Tests.ps1'
        }
        if ($scopeCount -gt 0) {
            $Convention.CodeownerInput = Get-AvmBicepCodeownerInput -RepositoryRoot $Convention.RepositoryRoot
            $files += Join-Path (Split-Path $suitePath) 'Ownership.Tests.ps1'
        }
        $summary = Invoke-AvmBicepPesterSuite -Files $files -WorkingDirectory $root `
            -Mode Convention -ConventionData $Convention -EnvVars @{} -InProcess
    }
    catch [AvmProcessException] {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $root `
                    -Code 'avm.bicep.convention-suite-unavailable' `
                    -Message "The convention Pester suite could not run; Pester 5.5.0 or later is required (Install-PSResource -Name Pester): $($_.Exception.Message)"))
        return $issues.ToArray()
    }

    foreach ($finding in $Convention.Findings) {
        $issues.Add($finding)
    }
    foreach ($crash in $Convention.Crashes) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $root `
                    -Code 'avm.bicep.convention-rule-failed' `
                    -Message "Convention rule '$($crash.Rule)' failed: $($crash.Message)"))
    }
    $nativeFindings = 0
    foreach ($suiteIssue in @($summary.Issues)) {
        if ($suiteIssue -is [System.Collections.IDictionary] -and $suiteIssue.Contains('NativeConvention') -and $suiteIssue.NativeConvention) {
            $nativeFindings++
            $issueRoot = if ($suiteIssue.Contains('IssueRoot') -and $suiteIssue.IssueRoot) { $suiteIssue.IssueRoot } else { $root }
            $issues.Add((New-AvmBicepConventionIssue -Root $issueRoot -Path $suiteIssue.File `
                        -Code $suiteIssue.Code -Message $suiteIssue.Message -Severity $suiteIssue.Severity -Line $suiteIssue.Line))
            continue
        }
        if ($suiteIssue.Code -ceq 'avm.bicep.pester-failed') {
            continue
        }
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $root `
                    -Code 'avm.bicep.convention-rule-failed' `
                    -Message "Convention suite reported $($suiteIssue.Code): $($suiteIssue.Message)"))
    }
    $hasError = @($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0
    if ($summary.Failed -gt $nativeFindings -and -not $hasError) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $root `
                    -Code 'avm.bicep.convention-rule-failed' `
                    -Message "The convention suite reported $($summary.Failed) failed test(s) without a recorded finding."))
    }
    $expected += $Convention.NativeCompiledExpected + $Convention.NativeWorkflowExpected + $Convention.NativeOwnershipExpected
    if (($compiledCount -gt 0 -and $Convention.NativeCompiledExpected -lt (11 * $compiledCount)) -or
        $Convention.NativeWorkflowExpected -lt $workflowCount -or
        ($scopeCount -gt 0 -and $Convention.NativeOwnershipExpected -lt 1) -or
        $summary.Total -ne $expected -or $summary.Passed + $summary.Failed -ne $expected) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $root `
                    -Code 'avm.bicep.convention-suite-incomplete' `
                    -Message "The convention suite ran $($summary.Passed + $summary.Failed) of $expected expected checks."))
    }
    return $issues.ToArray()
}
