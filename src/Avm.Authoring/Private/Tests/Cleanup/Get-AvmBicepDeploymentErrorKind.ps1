function Get-AvmBicepDeploymentErrorKind {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $pending = [System.Collections.Generic.Stack[System.Exception]]::new()
    $pending.Push($ErrorRecord.Exception)
    $visited = [System.Collections.Generic.HashSet[System.Exception]]::new()
    $hasTimeout = $false
    $hasTransportError = $false
    $hasForbidden = $false

    while ($pending.Count -gt 0) {
        $chainHasCancellation = $false
        $chainHasTimeout = $false
        $exception = $pending.Pop()
        while ($null -ne $exception -and $visited.Add($exception)) {
            if ($exception -is [System.Management.Automation.PipelineStoppedException]) {
                return 'Cancellation'
            }
            if ($exception -is [System.AggregateException]) {
                foreach ($innerException in $exception.InnerExceptions) {
                    $pending.Push($innerException)
                }
                break
            }
            $chainHasCancellation = $chainHasCancellation -or $exception -is [System.OperationCanceledException]
            $chainHasTimeout = $chainHasTimeout -or $exception -is [System.TimeoutException]
            $hasTransportError = $hasTransportError -or $exception -is [System.Net.Http.HttpRequestException]
            $statusCode = $null
            $responseProperty = $exception.PSObject.Properties['Response']
            if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
                $response = $responseProperty.Value
                if ($response -is [System.Collections.IDictionary]) { $statusCode = $response['StatusCode'] }
                else {
                    $statusProperty = $response.PSObject.Properties['StatusCode']
                    if ($null -ne $statusProperty) { $statusCode = $statusProperty.Value }
                }
            }
            if ($null -eq $statusCode) {
                $statusProperty = $exception.PSObject.Properties['StatusCode']
                if ($null -ne $statusProperty) { $statusCode = $statusProperty.Value }
            }
            $hasForbidden = $hasForbidden -or (
                ($statusCode -is [int] -or $statusCode -is [System.Net.HttpStatusCode]) -and [int]$statusCode -eq 403)
            $innerException = $exception.InnerException
            if ($exception -is [System.Management.Automation.RuntimeException]) {
                $recordException = $exception.ErrorRecord.Exception
                if ($null -eq $innerException) {
                    $innerException = $recordException
                }
                elseif ($null -ne $recordException -and
                    -not [object]::ReferenceEquals($recordException, $exception) -and
                    -not [object]::ReferenceEquals($recordException, $innerException)) {
                    $pending.Push($recordException)
                }
            }
            $exception = $innerException
        }
        if ($chainHasCancellation -and -not $chainHasTimeout) {
            return 'Cancellation'
        }
        $hasTimeout = $hasTimeout -or $chainHasTimeout
    }

    if ($hasForbidden) { return 'Forbidden' }
    if ($hasTimeout) { return 'Timeout' }
    if ($hasTransportError) { return 'Transport' }
    return 'Other'
}
