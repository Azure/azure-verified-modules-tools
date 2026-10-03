function Invoke-AvmBicepTestE2eAssertion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Item,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $DeploymentOutput,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Issues,

        [switch] $InProcess
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $result = [ordered]@{
        Case             = $Item.Case.RelativeDirectory
        Status           = 'not-present'
        FilesProcessed   = $Item.AssertionFiles.Count
        RunsTotal        = 0
        RunsPassed       = 0
        RunsFailed       = 0
        RunsSkipped      = 0
        RunsInconclusive = 0
        RunsFiltered     = 0
    }
    if ($Item.AssertionFiles.Count -eq 0) {
        return [pscustomobject]$result
    }
    try {
        $deployment = $DeploymentOutput | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $outputs = $deployment['properties']['outputs']
        if ($null -ne $outputs -and $outputs -isnot [System.Collections.IDictionary]) {
            throw [AvmProcessException]::new(
                "ARM deployment '$DeploymentName' returned invalid outputs.")
        }
        $testInputData = @{
            DeploymentOutputs    = $outputs
            ModuleTestFolderPath = [System.IO.Path]::GetDirectoryName($Item.Case.Path)
        }
        $summary = Invoke-AvmBicepPesterSuite -Mode E2e `
            -Files $Item.AssertionFiles -TestInputData $testInputData `
            -WorkingDirectory $RepositoryRoot -TimeoutSec 1800 -InProcess:$InProcess
    }
    catch [AvmProcessException] {
        $result.Status = 'fail'
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code 'assertion-runner-failed' `
            -Message "Post-deployment assertions in '$($Item.Case.RelativeDirectory)' could not run: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
    catch [System.TimeoutException] {
        $result.Status = 'fail'
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code 'assertion-timeout' `
            -Message "Post-deployment assertions in '$($Item.Case.RelativeDirectory)' timed out: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
    $result.RunsTotal = [int]$summary.Total
    $result.RunsPassed = [int]$summary.Passed
    $result.RunsFailed = [int]$summary.Failed
    $result.RunsSkipped = [int]$summary.Skipped
    $result.RunsInconclusive = [int]$summary.Inconclusive
    $result.RunsFiltered = [int]$summary.Filtered
    $result.Status = if ($summary.Passed -gt 0 -and
        $summary.Total -eq $summary.Passed -and $summary.Failed -eq 0 -and
        $summary.Skipped -eq 0 -and $summary.Inconclusive -eq 0 -and
        $summary.Filtered -eq 0 -and $summary.Issues.Count -eq 0) {
        'pass'
    }
    else {
        'fail'
    }
    foreach ($diagnostic in @($summary.Issues)) {
        $file = if ([string]::IsNullOrWhiteSpace([string]$diagnostic.File)) {
            $Item.Case.RelativePath
        }
        else {
            [string]$diagnostic.File
        }
        $code = ([string]$diagnostic.Code).Replace(
            'avm.bicep.pester-', 'assertion-')
        Add-AvmBicepTestIssue -Issues $Issues -File $file -Code $code `
            -Line ([int]$diagnostic.Line) `
            -Message "$($Item.Case.RelativeDirectory): $($diagnostic.Message)"
    }
    if ($result.Status -eq 'fail' -and $summary.Issues.Count -eq 0) {
        $code = if ($summary.Total -eq 0 -or $summary.Passed -eq 0) {
            'assertion-empty'
        }
        else {
            'assertion-incomplete'
        }
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code $code `
            -Message "Post-deployment assertions in '$($Item.Case.RelativeDirectory)' were not all passed (passed $($summary.Passed), total $($summary.Total), skipped $($summary.Skipped), inconclusive $($summary.Inconclusive), filtered $($summary.Filtered))."
    }
    return [pscustomobject]$result
}
