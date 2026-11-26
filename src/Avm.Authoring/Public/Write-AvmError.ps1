function Write-AvmError {
    <#
    .SYNOPSIS
        Report an error through the shared AVM diagnostic output.

    .DESCRIPTION
        Reports an error locally and in CI without reporting the same exception
        twice. Test values in the displayed message are redacted. This command
        does not rethrow or change the supplied error record.

    .PARAMETER ErrorRecord
        The PowerShell error record to report.

    .OUTPUTS
        None. Diagnostic output is written to the host.

    .EXAMPLE
        try { Invoke-AvmTestUnit } catch { Write-AvmError -ErrorRecord $_; throw }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    if (-not (Test-AvmIssuePresented -Issue $exception)) {
        $message = ConvertTo-AvmSafeTestDiagnostic -Message $exception.Message
        Write-AvmLog $message -Level Error
        Register-AvmPresentedIssue -Issue $exception
    }
}
