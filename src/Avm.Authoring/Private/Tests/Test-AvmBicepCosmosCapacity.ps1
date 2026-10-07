function Test-AvmBicepCosmosCapacity {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [string] $ResourceLocation
    )

    Set-StrictMode -Version 3.0
    if ([string]::IsNullOrWhiteSpace($ResourceLocation)) { return $false }
    $guid = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
    $sdk = 'Microsoft\.Azure\.Documents\.Common/[0-9]+\.[0-9]+\.[0-9]+'
    $pattern = "\ALong running operation failed with status 'Failed'\. Additional Info:'Database account creation failed\. " +
    "Operation Id: $guid, Error : Message: (?<json>\{.*\}), Request URI: /serviceReservation, RequestStats: , SDK: $sdk(?:, $sdk)*'\z"
    $wrapper = [regex]::Match($Message, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $wrapper.Success) { return $false }
    try {
        $cosmos = ConvertFrom-AvmStrictJson -Json $wrapper.Groups['json'].Value -RejectCaseInsensitiveDuplicates
    }
    catch [System.ArgumentException] { return $false }
    if ($cosmos.psbase.Count -ne 2 -or $cosmos['code'] -isnot [string] -or
        $cosmos['code'] -cne 'ServiceUnavailable' -or $cosmos['message'] -isnot [string]) { return $false }
    $pattern = '\ASorry, we are currently experiencing high demand in (?<region>[A-Za-z0-9]+(?: [A-Za-z0-9]+)*) region, ' +
    'and cannot fulfill your request at this time (?<time>[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT)\. ' +
    'To request region access for your subscription, please follow this link https://aka\.ms/cosmosdbquota for more details on how to create a region access request\.' +
    "\r\nActivityId: $guid, $sdk\z"
    $capacity = [regex]::Match($cosmos['message'], $pattern)
    $timestamp = [datetime]::MinValue
    return $capacity.Success -and
    [datetime]::TryParseExact($capacity.Groups['time'].Value, 'r', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$timestamp) -and
    ($capacity.Groups['region'].Value -replace '\s', '').ToLowerInvariant() -eq ($ResourceLocation -replace '\s', '').ToLowerInvariant()
}
