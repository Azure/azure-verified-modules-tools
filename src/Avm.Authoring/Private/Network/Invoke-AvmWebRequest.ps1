function Invoke-AvmWebRequest {
    <#
    .SYNOPSIS
        Send an idempotent HTTP GET with bounded retry for transient failures.
    .DESCRIPTION
        Thin wrapper over Invoke-WebRequest that retries through Invoke-AvmRetry.
        With -SkipHttpErrorCheck, transient status codes (for example 429 or 503)
        are retried and the last response is returned once attempts run out, so
        callers keep reporting the status themselves. Other statuses are returned
        immediately.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $Label,
        [hashtable] $Headers,
        [int] $TimeoutSec = 60,
        [string] $UserAgent,
        [string] $OutFile,
        [int] $MaximumRedirection = -1,
        [switch] $SkipHttpErrorCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $requestParameters = @{
        Uri             = $Uri
        Method          = 'Get'
        TimeoutSec      = $TimeoutSec
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }
    if ($null -ne $Headers) { $requestParameters.Headers = $Headers }
    if (-not [string]::IsNullOrWhiteSpace($UserAgent)) { $requestParameters.UserAgent = $UserAgent }
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) { $requestParameters.OutFile = $OutFile }
    if ($MaximumRedirection -ge 0) { $requestParameters.MaximumRedirection = $MaximumRedirection }
    if ($SkipHttpErrorCheck) { $requestParameters.SkipHttpErrorCheck = $true }

    # Pin TLS 1.2+; Tls13 is absent on some .NET targets.
    $protocols = [System.Net.SecurityProtocolType]::Tls12
    if ($null -ne [System.Net.SecurityProtocolType].GetField('Tls13')) {
        $protocols = $protocols -bor [System.Net.SecurityProtocolType]::Tls13
    }
    [System.Net.ServicePointManager]::SecurityProtocol = $protocols

    $statusCodes = (Get-AvmNetworkRetryPolicy).TransientStatusCodes
    Invoke-AvmRetry -RetryActivity $Label -RetryAction {
        $response = Invoke-WebRequest @requestParameters
        if ($SkipHttpErrorCheck -and $null -ne $response -and $statusCodes -contains [int]$response.StatusCode) {
            $transient = [System.Exception]::new("$Label returned HTTP $([int]$response.StatusCode).")
            $transient.Data['AvmTransient'] = $true
            $transient.Data['AvmResult'] = $response
            $responseHeaders = $response.PSObject.Properties['Headers']?.Value
            $retryAfterHeader = if ($responseHeaders -is [System.Collections.IDictionary] -and $responseHeaders.Contains('Retry-After')) { $responseHeaders['Retry-After'] } else { $null }
            $transient.Data['AvmRetryAfterSeconds'] = ConvertFrom-AvmRetryAfterHeader -Value $retryAfterHeader
            throw $transient
        }
        $response
    }
}