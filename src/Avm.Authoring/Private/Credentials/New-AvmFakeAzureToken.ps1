function New-AvmFakeAzureToken {
    <#
    .SYNOPSIS
        Build the unsigned JWT served by the synthetic Azure token endpoint.

    .DESCRIPTION
        The Azure Terraform providers parse the claims of the token they
        receive to discover the tenant, client and object identifiers before
        they issue any request. Only those claims matter here.

        The token carries no signature. It authenticates nothing, Azure
        rejects it, and it is only ever read locally by the provider that
        requested it.

    .PARAMETER TenantId
        Tenant identifier placed in the 'tid' claim.

    .PARAMETER ClientId
        Client identifier placed in the 'appid' claim.

    .PARAMETER ObjectId
        Principal identifier placed in the 'oid' and 'sub' claims.

    .PARAMETER IssuedAt
        Issue time for the 'iat' claim; 'nbf' is five minutes earlier so a
        modest clock skew cannot reject the token.

    .PARAMETER ExpiresAt
        Expiry time for the 'exp' claim.

    .OUTPUTS
        System.String. The encoded JWT.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ClientId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ObjectId,

        [Parameter(Mandatory)]
        [System.DateTimeOffset] $IssuedAt,

        [Parameter(Mandatory)]
        [System.DateTimeOffset] $ExpiresAt
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $header = [ordered]@{
        alg = 'none'
        typ = 'JWT'
    }
    $claims = [ordered]@{
        aud   = 'https://management.azure.com/'
        iss   = 'https://sts.windows.net/{0}/' -f $TenantId
        appid = $ClientId
        oid   = $ObjectId
        sub   = $ObjectId
        tid   = $TenantId
        ver   = '1.0'
        iat   = $IssuedAt.ToUnixTimeSeconds()
        nbf   = $IssuedAt.AddMinutes(-5).ToUnixTimeSeconds()
        exp   = $ExpiresAt.ToUnixTimeSeconds()
    }

    $segments = foreach ($part in @($header, $claims)) {
        $json = ConvertTo-Json -InputObject ([pscustomobject]$part) -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        [System.Convert]::ToBase64String($bytes).
            TrimEnd('=').
            Replace('+', '-').
            Replace('/', '_')
    }

    return '{0}.{1}.' -f $segments[0], $segments[1]
}
