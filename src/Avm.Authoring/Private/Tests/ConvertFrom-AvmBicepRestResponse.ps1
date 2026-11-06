function ConvertFrom-AvmBicepRestResponse {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Response,
        [Parameter(Mandatory)] [string] $Activity,
        [int[]] $AllowedStatus = @(200)
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $status = Get-AvmPropertyValue -InputObject $Response -Name 'StatusCode' -NoEnumerate
    $content = Get-AvmPropertyValue -InputObject $Response -Name 'Content' -NoEnumerate
    if ($null -eq $Response -or $Response -is [System.Collections.IList] -or
        ($status -isnot [int] -and $status -isnot [System.Net.HttpStatusCode]) -or
        $status -notin $AllowedStatus -or $content -isnot [string]) {
        $responseShape = if ($null -eq $Response) { 'null' }
        elseif ($Response -is [System.Collections.IList]) { 'array' }
        elseif ($Response -is [string] -or $Response -is [ValueType]) { 'scalar' }
        else { 'object' }
        $statusShape = if ($null -eq $status) { 'missing' }
        elseif ($status -is [int] -or $status -is [System.Net.HttpStatusCode]) {
            $number = [int]$status
            if ($number -ge 100 -and $number -le 599) { "HTTP $number" } else { 'out-of-range integer' }
        }
        elseif ($status -is [System.Collections.IList]) { 'array' }
        elseif ($status -is [string]) { 'string' }
        else { 'other' }
        $contentShape = if ($null -eq $content) { 'missing' }
        elseif ($content -is [string]) { 'string' }
        elseif ($content -is [System.Collections.IList]) { 'array' }
        elseif ($content -is [ValueType]) { 'scalar' }
        else { 'object' }
        $diagnostics = [System.Collections.Generic.List[string]]::new()
        $diagnostics.Add("response=$responseShape; status=$statusShape; content=$contentShape")
        try {
            if ($content -is [string] -and $content.Length -le 65536) {
                try {
                    $body = ConvertFrom-AvmStrictJson -Json $content -RejectCaseInsensitiveDuplicates
                    $errorNode = Get-AvmPropertyValue -InputObject $body -Name 'error' -NoEnumerate
                    if ($errorNode -is [System.Collections.IDictionary]) {
                        $code = Get-AvmPropertyValue -InputObject $errorNode -Name 'code' -NoEnumerate
                        if ($code -is [string] -and $code -cin @(
                                'AuthorizationFailed', 'Forbidden', 'InvalidAuthenticationToken',
                                'AuthenticationFailed', 'ExpiredAuthenticationToken', 'MissingSubscription',
                                'SubscriptionNotFound', 'ResourceGroupNotFound', 'DeploymentNotFound',
                                'ResourceNotFound', 'NotFound', 'TooManyRequests', 'InternalServerError',
                                'ServiceUnavailable', 'RequestTimeout', 'BadRequest', 'InvalidRequestContent',
                                'InvalidApiVersionParameter', 'NoRegisteredProviderFound', 'MissingSubscriptionRegistration'
                            )) {
                            $diagnostics.Add("code=$code")
                        }
                    }
                }
                catch [System.ArgumentException] {
                    $diagnostics.Add('error code unavailable')
                }
            }
            foreach ($headerName in @('x-ms-request-id', 'x-ms-correlation-request-id')) {
                $requestId = Get-AvmBicepResponseRequestId -Response $Response -HeaderName $headerName
                if ($requestId) { $diagnostics.Add("$headerName=$requestId") }
            }
        }
        catch {
            $diagnostics.Add('optional diagnostics unavailable')
        }
        throw [AvmProcessException]::new(
            "$Activity returned an invalid response or HTTP status. $($diagnostics -join '; ').")
    }
    try {
        $document = ConvertFrom-AvmStrictJson -Json $content -RejectCaseInsensitiveDuplicates
    }
    catch [System.ArgumentException] {
        $failure = [AvmProcessException]::new("$Activity returned invalid JSON.")
        $failure.Data['ReadErrorRecord'] = $_
        throw $failure
    }
    if ($document -isnot [System.Collections.IDictionary]) {
        throw [AvmProcessException]::new("$Activity did not return one JSON object.")
    }
    return $document
}
