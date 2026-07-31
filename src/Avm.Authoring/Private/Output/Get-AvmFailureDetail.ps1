function Get-AvmFailureDetail {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0

    $stepsProperty = $Result.PSObject.Properties['Steps']
    if ($null -ne $stepsProperty) {
        foreach ($step in @($stepsProperty.Value)) {
            if ([string]$step.Status -notin @('fail', 'error')) {
                continue
            }
            $errorProperty = $step.PSObject.Properties['Error']
            if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
                return "Step '$($step.Step)': $($errorProperty.Value)"
            }
            $resultProperty = $step.PSObject.Properties['Result']
            if ($null -ne $resultProperty -and $null -ne $resultProperty.Value) {
                $issueLines = @(ConvertTo-AvmIssueLine -Result $resultProperty.Value)
                if ($issueLines.Count -gt 0) {
                    return "Step '$($step.Step)': $($issueLines[0])"
                }
            }
            return "Step '$($step.Step)' reported Status '$($step.Status)'."
        }
    }

    $issueLines = @(ConvertTo-AvmIssueLine -Result $Result)
    if ($issueLines.Count -gt 0) {
        return $issueLines[0]
    }

    return ''
}
