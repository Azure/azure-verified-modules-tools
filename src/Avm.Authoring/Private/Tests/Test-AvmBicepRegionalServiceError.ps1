function Test-AvmBicepRegionalServiceError {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Code,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,

        [string] $ResourceLocation,
        [string] $SubscriptionId,
        [string[]] $Targets = @()
    )

    Set-StrictMode -Version 3.0
    if ([string]::IsNullOrWhiteSpace($ResourceLocation)) { return $false }
    $selectedRegion = ($ResourceLocation -replace '\s', '').ToLowerInvariant()
    if ($selectedRegion -eq 'global') { return $false }
    $region = '[A-Za-z0-9]+(?: [A-Za-z0-9]+)*'
    $isContainer = $Code -ceq 'ManagedEnvironmentCapacityHeavyUsageError'
    $pattern = switch -CaseSensitive ($Code) {
        'ResourcesForSkuUnavailable' {
            $guid = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
            "\AThe region '(?<region>$region)' currently does not have enough resources available to provision services with the SKU " +
            "'[A-Za-z][A-Za-z0-9_]*'\. Try creating the service in another region or selecting a different SKU\. RequestId: $guid\z"
        }
        'BadRequest' {
            "\ASemantic Search is not available in '(?<region>$region)' region\. Please refer to " +
            'https://aka\.ms/semanticsearchavailability for list of available regions\.\z'
        }
        'ManagedEnvironmentCapacityHeavyUsageError' {
            $summary = "(?:AKS is experiencing heavy usage in region (?<region>$region)\. We are working on adding new capacity\. " +
            'In the meantime, please consider creating new AKS clusters in a different region\.' +
            "|Creating a new cluster is unavailable at this time in region (?<region>$region)\. To create a new cluster, we recommend using an alternate region\.)" +
            ' For a list of all the Azure regions, visit https://aka\.ms/aks/regions\. For more details on this error, visit https://aka\.ms/akscapacityheavyusage\.'
            "\A(?<summary>$summary)\r?\nStatus: 400 \(Bad Request\)\r?\nErrorCode: AKSCapacityHeavyUsage\r?\n\r?\n" +
            'Content:\r?\n(?<json>\{.*\})\r?\n\r?\nHeaders:\r?\n(?<headers>(?:[A-Za-z0-9-]+: [^\r\n]+\r?\n)+)\z'
        }
        default { return $false }
    }
    $match = [regex]::Match($Message, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success -or ($match.Groups['region'].Value -replace '\s', '').ToLowerInvariant() -ne $selectedRegion) {
        return $false
    }

    $serviceTarget = ''
    if ($Targets.Count -gt 0) {
        $subscription = [guid]::Empty
        if (-not [guid]::TryParseExact($SubscriptionId, 'D', [ref]$subscription) -or $subscription -eq [guid]::Empty) {
            return $false
        }
        $prefix = '\A/subscriptions/' + [regex]::Escape($subscription.ToString('D'))
        $provider = if ($isContainer) { 'Microsoft\.App/managedEnvironments' } else { 'Microsoft\.Search/searchServices' }
        $servicePattern = "$prefix/resourceGroups/[^/?#\s]+/providers/$provider/[^/?#\s]+\z"
        $deploymentPattern = "$prefix(?:/resourceGroups/[^/?#\s]+)?/providers/Microsoft\.Resources/deployments/[^/?#\s]+\z"
        foreach ($target in $Targets) {
            if ($target -match $servicePattern) {
                if ($serviceTarget -and $serviceTarget -ine $target) { return $false }
                $serviceTarget = $target
            }
            elseif ($target -notmatch $deploymentPattern) { return $false }
        }
    }
    if (-not $isContainer) { return $true }
    if (-not $serviceTarget) { return $false }
    try {
        $body = ConvertFrom-AvmStrictJson -Json $match.Groups['json'].Value -RejectCaseInsensitiveDuplicates
    }
    catch [System.ArgumentException] { return $false }
    if ($body.psbase.Count -ne 4 -or
        @($body.psbase.Keys | Where-Object { $_ -cnotin @('code', 'message', 'details', 'subcode') }).Count -gt 0 -or
        $body['code'] -isnot [string] -or $body['code'] -cne 'AKSCapacityHeavyUsage' -or
        $body['message'] -isnot [string] -or $body['message'] -cne $match.Groups['summary'].Value -or
        $null -ne $body['details'] -or $body['subcode'] -isnot [string] -or $body['subcode'] -cne '') {
        return $false
    }
    $allowedHeaders = @(
        'Cache-Control', 'Pragma', 'x-ms-operation-identifier', 'x-ms-correlation-request-id', 'x-ms-request-id',
        'Strict-Transport-Security', 'x-ms-throttling-version', 'x-ms-ratelimit-remaining-subscription-writes',
        'x-ms-routing-request-id', 'X-Content-Type-Options', 'X-Cache', 'X-MSEdge-Ref', 'Date',
        'Content-Length', 'Content-Type', 'Expires'
    )
    $headers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $match.Groups['headers'].Value -split '\r?\n') {
        if ($line.Length -eq 0) { continue }
        $separator = $line.IndexOf(':')
        $name = $line.Substring(0, $separator)
        if ($name -notin $allowedHeaders -or -not $headers.Add($name) -or
            [string]::IsNullOrWhiteSpace($line.Substring($separator + 2))) { return $false }
    }
    return $true
}
