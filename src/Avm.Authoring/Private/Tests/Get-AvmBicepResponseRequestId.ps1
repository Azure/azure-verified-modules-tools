function Get-AvmBicepResponseRequestId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [object] $Response,
        [ValidateSet('x-ms-request-id', 'x-ms-correlation-request-id')] [string] $HeaderName = 'x-ms-request-id'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $headers = Get-AvmPropertyValue -InputObject $Response -Name 'Headers' -NoEnumerate
    $values = @()
    if ($headers -is [System.Net.Http.Headers.HttpResponseHeaders]) {
        [System.Collections.Generic.IEnumerable[string]] $headerValues = $null
        if ($headers.TryGetValues($HeaderName, [ref]$headerValues)) { $values = @($headerValues) }
    }
    elseif ($headers -is [System.Collections.IDictionary]) {
        $keys = @($headers.Keys | Where-Object { $_ -is [string] -and $_ -ieq $HeaderName })
        if ($keys.Count -eq 1) {
            $value = $headers[$keys[0]]
            if ($value -is [string]) { $values = @($value) }
            elseif ($value -is [array]) { $values = @($value) }
        }
    }
    if ($values.Count -eq 1 -and $values[0] -is [string] -and
        $values[0] -cmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') {
        return $values[0]
    }
    return ''
}
