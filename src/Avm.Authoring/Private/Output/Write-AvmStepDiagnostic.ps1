function Write-AvmStepDiagnostic {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Result,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Status,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]] $Presented,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ErrorMessage
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($null -ne $Result -and (Test-AvmVerboseEnabled)) {
        foreach ($line in @(ConvertTo-AvmRunSummaryLine -Result $Result -Indent '  ')) {
            Write-AvmLog $line -Level Verbose
        }
    }
    if ($null -ne $Result -and $null -ne $Result.PSObject.Properties['Issues']) {
        foreach ($issue in @($Result.Issues)) {
            if ($null -eq $issue) { continue }
            $severityProperty = $issue.PSObject.Properties['Severity']
            if ($null -eq $severityProperty -or $severityProperty.Value -isnot [string] -or
                $severityProperty.Value -notin @('warning', 'error')) {
                if ((Test-AvmVerboseEnabled) -and -not (Test-AvmIssuePresented -Issue $issue)) {
                    foreach ($line in @(ConvertTo-AvmIssueLine -Result ([pscustomobject]@{ Issues = @($issue) }) -Indent '  ')) {
                        Write-AvmLog $line -Level Verbose
                    }
                }
                continue
            }
            $severity = $severityProperty.Value.ToLowerInvariant()
            $fields = @{ File = ''; Line = 0; Column = 0; Code = ''; Message = '' }
            foreach ($fieldName in @($fields.Keys)) {
                $property = $issue.PSObject.Properties[$fieldName]
                if ($null -ne $property -and $null -ne $property.Value) { $fields[$fieldName] = $property.Value }
            }
            $key = ConvertTo-Json -InputObject @(
                $severity, $fields.File, $fields.Line, $fields.Column, $fields.Code, $fields.Message
            ) -Compress
            if ($Presented.Add($key) -and -not (Test-AvmIssuePresented -Issue $issue)) {
                $message = [string]$fields.Message
                $code = [string]$fields.Code
                if ($code) { $message = '[{0}] {1}' -f $code, $message }
                Write-AvmLog -Message $message -Level $severity `
                    -File ([string]$fields.File) -Line ([int]$fields.Line) -Column ([int]$fields.Column)
            }
            Register-AvmPresentedIssue -Issue $issue
        }
    }
    if ($Status -in @('fail', 'error') -and -not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        Write-AvmLog ('  {0}: {1}' -f $Name, $ErrorMessage) -Level Error
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ErrorMessage) -and (Test-AvmVerboseEnabled)) {
        Write-AvmLog ('  {0}: {1}' -f $Name, $ErrorMessage) -Level Verbose
    }
}
