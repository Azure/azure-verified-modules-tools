function Resolve-AvmBicepCleanupNextLink {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $NextLink
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrEmpty($NextLink)) {
        return ''
    }
    if ($NextLink.StartsWith('/') -and -not $NextLink.StartsWith('//') -and
        $NextLink -notmatch '[\\#\x00-\x1f]') {
        return $NextLink
    }
    $nextUri = $null
    $context = Get-AzContext -ErrorAction Stop
    $environment = Get-AvmPropertyValue -InputObject $context -Name 'Environment'
    $endpointValue = [string](Get-AvmPropertyValue -InputObject $environment -Name 'ResourceManagerUrl')
    $endpoint = $null
    if (-not [uri]::TryCreate($endpointValue, [System.UriKind]::Absolute, [ref]$endpoint)) {
        throw [AvmConfigurationException]::new('Azure context has no Resource Manager endpoint.')
    }
    if (-not [uri]::TryCreate($NextLink, [System.UriKind]::Absolute, [ref]$nextUri) -or
        $nextUri.Scheme -ne 'https' -or $nextUri.Authority -ine $endpoint.Authority -or
        -not [string]::IsNullOrEmpty($nextUri.UserInfo) -or
        -not [string]::IsNullOrEmpty($nextUri.Fragment)) {
        throw [AvmProcessException]::new('Azure collection returned a foreign nextLink.')
    }
    return $nextUri.PathAndQuery
}
