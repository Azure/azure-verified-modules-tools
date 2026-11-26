function ConvertTo-AvmSafeTestDiagnostic {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [string] $Message)

    $message = $Message.ReplaceLineEndings(' ').Trim()
    $message = [regex]::Replace($message, "(['`"]).*?\1", '<value>')
    $message = [regex]::Replace($message, '(?i)\b(expected|actual|got|received)\b\s+[^,.;]+', '$1 <value>')
    if ($message.Length -gt 1024) { $message = $message.Substring(0, 1024) + [char]0x2026 }
    return $message
}

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
        [string] $ErrorMessage,

        [string] $SourceRoot = (Get-Location).Path,

        [switch] $RedactTestValues
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
                if ($RedactTestValues -and -not (Test-AvmIssuePresented -Issue $issue)) {
                    $messageProperty = $issue.PSObject.Properties['Message']
                    $codeProperty = $issue.PSObject.Properties['Code']
                    $message = if ($null -ne $messageProperty) { [string]$messageProperty.Value } else { [string]$issue }
                    $message = ConvertTo-AvmSafeTestDiagnostic -Message $message
                    if ($null -ne $codeProperty -and $codeProperty.Value) { $message = '[{0}] {1}' -f $codeProperty.Value, $message }
                    Write-AvmLog $message -Level Info
                    Register-AvmPresentedIssue -Issue $issue
                    continue
                }
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
                if ($RedactTestValues) {
                    $message = ConvertTo-AvmSafeTestDiagnostic -Message $message
                }

                $code = [string]$fields.Code
                if ($code) { $message = '[{0}] {1}' -f $code, $message }
                Write-AvmLog -Message $message -Level $severity `
                    -File ([string]$fields.File) -Line ([int]$fields.Line) -Column ([int]$fields.Column) `
                    -SourceRoot $SourceRoot
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
