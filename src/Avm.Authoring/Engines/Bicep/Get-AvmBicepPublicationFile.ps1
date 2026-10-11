function Get-AvmBicepPublicationFile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        $GitState
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Path -cnotmatch '^avm/(?:res|ptn|utl)(?:/[a-z0-9]+(?:-[a-z0-9]+)*){2,}/(?:main|version)\.json\z' -or
        $GitState.BaseSha -cnotmatch '^[0-9a-f]{40,64}\z') {
        throw [AvmConfigurationException]::new('Invalid pinned publication module-data path.')
    }
    if ($GitState.RemoteFiles.ContainsKey($Path)) {
        return $GitState.RemoteFiles[$Path]
    }
    if ($env:AVM_OFFLINE -eq '1') {
        throw [AvmConfigurationException]::new('AVM_OFFLINE=1: upstream publication files cannot be verified.')
    }
    $uri = "https://raw.githubusercontent.com/Azure/bicep-registry-modules/$($GitState.BaseSha)/$Path"
    try {
        $response = Invoke-AvmWebRequest -Uri $uri -MaximumRedirection 0 -SkipHttpErrorCheck `
            -TimeoutSec 20 -Label "Publication data for '$Path'"
    }
    catch [System.Net.Http.HttpRequestException], [System.Net.WebException],
    [System.TimeoutException], [System.Management.Automation.RuntimeException] {
        throw [AvmConfigurationException]::new("Cannot read upstream '$Path': $($_.Exception.Message)")
    }
    if ($null -eq $response.BaseResponse -or $null -eq $response.BaseResponse.RequestMessage -or
        $null -eq $response.BaseResponse.RequestMessage.RequestUri -or
        $response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri -cne $uri) {
        throw [AvmConfigurationException]::new("Cannot attribute the upstream '$Path' response to its pinned endpoint.")
    }
    if ($response.StatusCode -notin @(200, 404) -or
        ($response.StatusCode -eq 404 -and ([string]$response.Content).Trim() -cne '404: Not Found')) {
        throw [AvmConfigurationException]::new(
            "Upstream '$Path' returned HTTP $($response.StatusCode) without verifiable module data.")
    }
    $result = [pscustomobject]@{
        Exists  = $response.StatusCode -eq 200
        Content = if ($response.StatusCode -eq 200) { [string]$response.Content } else { $null }
    }
    $GitState.RemoteFiles[$Path] = $result
    return $result
}
