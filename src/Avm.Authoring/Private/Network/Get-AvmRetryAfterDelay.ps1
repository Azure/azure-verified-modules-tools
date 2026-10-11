function Get-AvmRetryAfterDelay {
    <#
    .SYNOPSIS
        Return the server-requested Retry-After delay in seconds, or $null.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)] [object] $ErrorRecord,
        [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    Set-StrictMode -Version 3.0
    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    for ($item = $exception; $null -ne $item; $item = $item.InnerException) {
        if ($item.Data.Contains('AvmRetryAfterSeconds') -and $null -ne $item.Data['AvmRetryAfterSeconds']) {
            return [double]$item.Data['AvmRetryAfterSeconds']
        }
        $response = $item.PSObject.Properties['Response']
        if ($null -eq $response -or $response.Value -isnot [System.Net.Http.HttpResponseMessage]) { continue }
        $header = $response.Value.Headers.RetryAfter
        if ($null -eq $header) { continue }
        if ($null -ne $header.Delta) { return [math]::Max(0, $header.Delta.TotalSeconds) }
        if ($null -ne $header.Date) { return [math]::Max(0, ($header.Date - $Now).TotalSeconds) }
    }
    return $null
}