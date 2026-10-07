function Invoke-AvmBicepConventionSuite {
    <#
    .SYNOPSIS
        Run the packaged Bicep convention Pester suite against prepared input.

    .DESCRIPTION
        Executes native packaged requirements in one Pester run. Translates
        failures and preserves preparation diagnostics, rejecting incomplete runs.

    .OUTPUTS
        Convention issue objects.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Convention,

        [switch] $Compliance,

        [AllowEmptyCollection()]
        [object[]] $MetadataInputs = @(),

        [AllowEmptyCollection()]
        [object[]] $ReadmeInputs = @(),

        [AllowEmptyCollection()]
        [string[]] $Tag = @(),

        [AllowEmptyCollection()]
        [string[]] $TestName = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $root = [string]$Convention.Root
    $Convention.NativeCompiledExpected = 0
    $Convention.NativeWorkflowExpected = 0
    $Convention.NativeOwnershipExpected = 0
    $Convention.NativeChildPublishExpected = -1
    $Convention.NativeVersionExpected = -1
    $Convention.NativeApiVersionExpected = 0
    $Convention.NativeTestSourceExpected = -1
    $Convention.NativeLayoutExpected = -1
    $Convention.NativePublicationExpected = -1
    $Convention.NativeMetadataExpected = if ($MetadataInputs.Count -gt 0) { -1 } else { 0 }
    $Convention.NativeReadmeExpected = if ($ReadmeInputs.Count -gt 0) { -1 } else { 0 }
    $Convention.ValidationSummary = $null
    $suiteDirectory = Join-Path -Path $PSScriptRoot -ChildPath '..' `
        -AdditionalChildPath '..', 'Resources', 'bicep', 'conventions'
    $suiteDirectory = [System.IO.Path]::GetFullPath($suiteDirectory)
    $issues = [System.Collections.Generic.List[object]]::new()

    $compiledCount = @($Convention.CompiledModules).Count
    $scopeCount = @($Convention.Scopes).Count
    $workflowCount = @($Convention.Workflows).Count
    $expected = 0
    if ($scopeCount -eq 0 -and $workflowCount -eq 0 -and $compiledCount -eq 0 -and
        $MetadataInputs.Count -eq 0 -and $ReadmeInputs.Count -eq 0) {
        return $issues.ToArray()
    }

    try {
        $Convention.CompiledInputs = @($Convention.CompiledModules | ForEach-Object { Get-AvmBicepCompiledConventionInput -Module $_ })
        $files = @()
        if ($compiledCount -gt 0) {
            $files += Join-Path $suiteDirectory 'Compiled.Tests.ps1'
            $Convention.ApiVersionInputs = @($Convention.CompiledModules | ForEach-Object { Get-AvmBicepApiVersionInput -Module $_ })
            $files += Join-Path $suiteDirectory 'ApiVersion.Tests.ps1'
        }
        if ($workflowCount -gt 0) {
            $files += Join-Path $suiteDirectory 'Workflow.Tests.ps1'
        }
        if ($scopeCount -gt 0) {
            $Convention.CodeownerInput = Get-AvmBicepCodeownerInput -RepositoryRoot $Convention.RepositoryRoot
            $files += Join-Path $suiteDirectory 'Ownership.Tests.ps1'
            $Convention.ChildPublishInput = Get-AvmBicepChildPublishInput -RepositoryRoot $Convention.RepositoryRoot `
                -Scopes @($Convention.Scopes)
            $files += Join-Path $suiteDirectory 'ChildPublish.Tests.ps1'
            $Convention.VersionInputs = @(foreach ($scope in @($Convention.Scopes)) {
                    $versionInput = Get-AvmBicepVersionInput -Scope $scope
                    if ($null -ne $versionInput) { $versionInput }
                })
            $Convention.MajorVersionAllowedModules = (Get-AvmBicepConfiguration)['conventionExemptions']['majorVersionAllowedModules']
            $files += Join-Path $suiteDirectory 'Version.Tests.ps1'
            $Convention.TestSourceInputs = @($Convention.TestSources | ForEach-Object {
                    Get-AvmBicepTestSourceInput -SourceFile $_ -CompiledTests $Convention.CompiledTests
                })
            $files += Join-Path $suiteDirectory 'TestSource.Tests.ps1'
            $Convention.LayoutInputs = @($Convention.Scopes | ForEach-Object { Get-AvmBicepLayoutInput -Scope $_ })
            $Convention.LayoutExemptions = (Get-AvmBicepConfiguration)['conventionExemptions']
            $files += Join-Path $suiteDirectory 'Layout.Tests.ps1'
            foreach ($issue in @($Convention.Publication.Issues)) { $issues.Add($issue) }
            $Convention.PublicationConventionInput = Get-AvmBicepPublicationConventionInput `
                -RepositoryRoot $Convention.RepositoryRoot -Publication $Convention.Publication -VersionInputs $Convention.VersionInputs
            $files += Join-Path $suiteDirectory 'Publication.Tests.ps1'
            if (@($Convention.Publication.Entries | Where-Object { $null -eq $_.Target -or $null -eq $_.Published }).Count -gt 0 -and
                @($Convention.Publication.Issues).Count -eq 0) {
                $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $root `
                            -Code 'avm.bicep.convention-suite-incomplete' -Message 'Publication input is missing target/tag data without a preparation diagnostic.'))
            }
        }
        if ($Compliance) {
            $Convention.MetadataValidations = $MetadataInputs
            $Convention.ReadmeInputs = $ReadmeInputs
            if ($MetadataInputs.Count -gt 0) {
                $files += [System.IO.Path]::GetFullPath((Join-Path -Path $suiteDirectory -ChildPath '..' `
                            -AdditionalChildPath '..', 'metadata', 'Metadata.Tests.ps1'))
            }
            if ($ReadmeInputs.Count -gt 0) { $files += Join-Path $suiteDirectory 'Readme.Tests.ps1' }
            $Convention.SuiteFiles = $files
            $Convention.ComplianceFile = Join-Path (Split-Path $suiteDirectory) 'Compliance.Tests.ps1'
            $files = @($Convention.ComplianceFile)
        }
        $summary = Invoke-AvmBicepPesterSuite -Files $files -WorkingDirectory $root `
            -Mode Convention -ConventionData $Convention -Tag $Tag -TestName $TestName -EnvVars @{} -InProcess
        $Convention.ValidationSummary = $summary
    }
    catch [AvmProcessException], [AvmToolException] {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $root `
                    -Code 'avm.bicep.convention-suite-unavailable' `
                    -Message "The convention Pester suite could not run. Restore its configured prerequisite with avm tool install Pester: $($_.Exception.Message)"))
        return $issues.ToArray()
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
    if ($summary.Failed -gt $nativeFindings) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $root `
                    -Code 'avm.bicep.convention-rule-failed' `
                    -Message "The convention suite reported $($summary.Failed) failed test(s) without a recorded finding."))
    }
    $expected += $Convention.NativeCompiledExpected + $Convention.NativeWorkflowExpected + $Convention.NativeOwnershipExpected
    $expected += $Convention.NativeApiVersionExpected
    $expected += [Math]::Max(0, $Convention.NativeMetadataExpected) + [Math]::Max(0, $Convention.NativeReadmeExpected)
    if ($scopeCount -gt 0) { $expected += [Math]::Max(0, $Convention.NativeChildPublishExpected) }
    if ($scopeCount -gt 0) { $expected += [Math]::Max(0, $Convention.NativeVersionExpected) }
    if ($scopeCount -gt 0) { $expected += [Math]::Max(0, $Convention.NativeTestSourceExpected) }
    if ($scopeCount -gt 0) { $expected += [Math]::Max(0, $Convention.NativeLayoutExpected) + [Math]::Max(0, $Convention.NativePublicationExpected) }
    $filtered = if ($Compliance) { $summary.Filtered } else { 0 }
    if (($compiledCount -gt 0 -and $Convention.NativeCompiledExpected -lt (11 * $compiledCount)) -or
        ($compiledCount -gt 0 -and $Convention.NativeApiVersionExpected -lt 1) -or
        $Convention.NativeWorkflowExpected -lt $workflowCount -or
        ($scopeCount -gt 0 -and $Convention.NativeOwnershipExpected -lt 1) -or
        ($scopeCount -gt 0 -and $Convention.NativeChildPublishExpected -lt 0) -or
        ($scopeCount -gt 0 -and $Convention.NativeVersionExpected -lt 0) -or
        ($scopeCount -gt 0 -and $Convention.NativeTestSourceExpected -lt 0) -or
        ($scopeCount -gt 0 -and ($Convention.NativeLayoutExpected -lt 0 -or $Convention.NativePublicationExpected -lt 0)) -or
        $Convention.NativeMetadataExpected -lt 0 -or $Convention.NativeReadmeExpected -lt 0 -or
        $summary.Total -ne $expected -or $summary.Passed + $summary.Failed + $filtered -ne $expected) {
        $issues.Add((New-AvmBicepConventionIssue -Root $root -Path $root `
                    -Code 'avm.bicep.convention-suite-incomplete' `
                    -Message "The convention suite ran $($summary.Passed + $summary.Failed) of $expected expected checks."))
    }
    return $issues.ToArray()
}
