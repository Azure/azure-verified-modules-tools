function Get-AvmBicepApiSpecList {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $uri = [uri]'https://azure.github.io/Azure-Verified-Modules/governance/apiSpecsList.json'
    if ($env:AVM_OFFLINE -eq '1') {
        throw [AvmConfigurationException]::new(
            'AVM_OFFLINE=1: the registry API-version specification list cannot be verified.')
    }
    if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'azure.github.io' -or
        $uri.AbsolutePath -cne '/Azure-Verified-Modules/governance/apiSpecsList.json' -or
        -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw [AvmConfigurationException]::new('The API-version specification endpoint must be the fixed registry HTTPS URL.')
    }
    try {
        $response = Invoke-AvmWebRequest -Uri $uri -Headers @{ Accept = 'application/json' } `
            -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 20 -Label 'Registry API-version specification request'
    }
    catch [System.Net.Http.HttpRequestException], [System.Net.WebException],
    [System.TimeoutException], [System.Management.Automation.RuntimeException] {
        throw [AvmConfigurationException]::new(
            "Cannot read registry API-version specifications from '$($uri.AbsoluteUri)': $($_.Exception.Message)")
    }
    if ($null -eq $response.BaseResponse -or
        $null -eq $response.BaseResponse.RequestMessage -or
        $null -eq $response.BaseResponse.RequestMessage.RequestUri -or
        $response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri -cne $uri.AbsoluteUri) {
        throw [AvmConfigurationException]::new(
            'The registry API-version response cannot be attributed to its fixed HTTPS endpoint.')
    }
    if ($response.StatusCode -ne 200) {
        throw [AvmConfigurationException]::new(
            "The registry API-version endpoint returned HTTP $($response.StatusCode); recency is unknown.")
    }
    try {
        $specs = [string]$response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch [System.Management.Automation.RuntimeException] {
        throw [AvmConfigurationException]::new(
            "The registry API-version response is not valid JSON: $($_.Exception.Message)")
    }
    if ($specs -isnot [System.Collections.IDictionary] -or $specs.Count -eq 0) {
        throw [AvmConfigurationException]::new(
            'The registry API-version response must contain provider namespace mappings.')
    }
    foreach ($namespace in $specs.Keys) {
        if ($namespace -isnot [string] -or
            $namespace -cnotmatch '^[A-Za-z][A-Za-z0-9]*\.[A-Za-z][A-Za-z0-9.]*$' -or
            $specs[$namespace] -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                'The registry API-version response must contain provider namespace mappings.')
        }
    }
    return $specs
}
