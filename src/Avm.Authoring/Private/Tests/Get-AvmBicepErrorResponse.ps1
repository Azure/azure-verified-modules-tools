function Get-AvmBicepErrorResponse {
    <#
    .SYNOPSIS
        Return the structured Azure error response carried by an error record, or $null.

    .DESCRIPTION
        ARM validation failures raised by Invoke-AvmBicepNativeArmOperation carry their
        error objects as the record's TargetObject. Az cmdlet failures carry the response
        JSON in ErrorDetails.Message.
    #>
    [CmdletBinding()]
    [OutputType([object[]], [System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($ErrorRecord.FullyQualifiedErrorId -like 'AvmBicepTemplateValidationFailed*') {
        return , $ErrorRecord.TargetObject
    }
    $message = Get-AvmPropertyValue -InputObject $ErrorRecord.ErrorDetails -Name 'Message'
    if ($message -isnot [string]) { return $null }
    try {
        return , (ConvertFrom-Json -InputObject $message -AsHashtable -NoEnumerate -ErrorAction Stop)
    }
    catch [System.ArgumentException] {
        return $null
    }
}