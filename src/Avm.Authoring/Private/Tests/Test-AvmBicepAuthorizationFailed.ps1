function Test-AvmBicepAuthorizationFailed {
    [CmdletBinding(DefaultParameterSetName = 'Response')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Response')] [AllowNull()] [object] $Response,
        [Parameter(Mandatory, ParameterSetName = 'Error')] [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [System.Collections.IDictionary] $Policy
    )

    Set-StrictMode -Version 3.0
    if (-not $PSBoundParameters.ContainsKey('Policy')) { $Policy = Get-AvmBicepRetryPolicy }
    $propagation = $Policy['authorizationPropagation']
    if ($PSCmdlet.ParameterSetName -eq 'Response') {
        if ($null -eq $Response -or $Response -is [System.Collections.IList]) { return $false }
        $status = Get-AvmPropertyValue -InputObject $Response -Name 'StatusCode' -NoEnumerate
        $content = Get-AvmPropertyValue -InputObject $Response -Name 'Content' -NoEnumerate
        if (($status -isnot [int] -and $status -isnot [System.Net.HttpStatusCode]) -or
            [int]$status -ne $propagation['statusCode'] -or
            $content -isnot [string] -or $content.Length -gt 65536) { return $false }
        try { $body = ConvertFrom-AvmStrictJson -Json $content -RejectCaseInsensitiveDuplicates }
        catch [System.ArgumentException] { return $false }
        $errorNode = Get-AvmPropertyValue -InputObject $body -Name 'error' -NoEnumerate
        return $body -is [System.Collections.IDictionary] -and $body.Count -eq 1 -and
        $errorNode -is [System.Collections.IDictionary] -and $errorNode['code'] -is [string] -and
        $errorNode['code'] -ceq $propagation['errorCode'] -and
        (-not $errorNode.Contains('message') -or $errorNode['message'] -is [string]) -and
        (-not $errorNode.Contains('target') -or $errorNode['target'] -is [string]) -and
        @($errorNode.Keys | Where-Object { $_ -cnotin @('code', 'message', 'target') }).Count -eq 0
    }

    if ($ErrorRecord.CategoryInfo.Category -in $propagation['nonRetryableCategories']) { return $false }
    $visited = [System.Collections.Generic.HashSet[System.Exception]]::new()
    $exception = $ErrorRecord.Exception
    $found = $false
    $hasExpectedStatus = $false
    while ($null -ne $exception) {
        if (-not $visited.Add($exception) -or $visited.Count -gt 100 -or
            $exception -is [System.OperationCanceledException] -or
            $exception -is [System.Management.Automation.PipelineStoppedException] -or
            $exception -is [System.UnauthorizedAccessException] -or
            $exception -is [System.Security.Authentication.AuthenticationException] -or
            $exception -is [System.Security.SecurityException]) { return $false }
        if ($exception -is [System.AggregateException]) {
            if ($exception.InnerExceptions.Count -ne 1) { return $false }
            $exception = $exception.InnerExceptions[0]
            continue
        }
        $status = Get-AvmPropertyValue -InputObject $exception -Name 'StatusCode' -NoEnumerate
        $response = Get-AvmPropertyValue -InputObject $exception -Name 'Response' -NoEnumerate
        $responseStatus = Get-AvmPropertyValue -InputObject $response -Name 'StatusCode' -NoEnumerate
        $observedStatus = if ($null -ne $responseStatus) { $responseStatus } else { $status }
        if (($observedStatus -is [int] -or $observedStatus -is [System.Net.HttpStatusCode]) -and
            [int]$observedStatus -eq $propagation['statusCode']) { $hasExpectedStatus = $true }
        if ($null -eq $status) { $status = $responseStatus }
        if ($null -ne $status -and (($status -isnot [int] -and $status -isnot [System.Net.HttpStatusCode]) -or
                [int]$status -ne $propagation['statusCode'])) {
            return $false
        }
        if ($null -ne $response -and (Test-AvmBicepAuthorizationFailed -Response $response -Policy $Policy)) { $found = $true }
        $body = Get-AvmPropertyValue -InputObject $exception -Name 'Body' -NoEnumerate
        if ($null -ne $body) {
            $code = Get-AvmPropertyValue -InputObject $body -Name 'Code' -NoEnumerate
            if ($code -isnot [string] -or $code -cne $propagation['errorCode'] -or
                ($status -isnot [int] -and $status -isnot [System.Net.HttpStatusCode]) -or
                [int]$status -ne $propagation['statusCode']) { return $false }
            $details = Get-AvmPropertyValue -InputObject $body -Name 'Details' -NoEnumerate
            if ($null -ne $details -and @($details).Count -gt 0) { return $false }
            $found = $true
        }
        if ($null -ne $response -and $null -ne (Get-AvmPropertyValue -InputObject $response -Name 'Content' -NoEnumerate) -and
            -not (Test-AvmBicepAuthorizationFailed -Response $response -Policy $Policy)) { return $false }
        if ($null -eq $response -and $null -eq $body -and
            $exception -isnot [System.Management.Automation.RuntimeException]) { return $false }
        $next = $exception.InnerException
        if ($exception -is [System.Management.Automation.RuntimeException] -and $null -ne $exception.ErrorRecord) {
            if ($exception.ErrorRecord.CategoryInfo.Category -in $propagation['nonRetryableCategories']) { return $false }
            $recordException = $exception.ErrorRecord.Exception
            if (-not [object]::ReferenceEquals($recordException, $exception)) {
                if ($null -ne $next -and -not [object]::ReferenceEquals($next, $recordException)) { return $false }
                $next = $recordException
            }
        }
        $exception = $next
    }
    return $found -and $hasExpectedStatus
}
