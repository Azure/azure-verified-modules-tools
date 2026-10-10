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
        throw [AvmProcessException]::new("$Activity returned an invalid response or HTTP status.")
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
