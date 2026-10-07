function Test-AvmBicepAksZoneCapacity {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter(Mandatory)]
        [string] $ParentMessage,

        [string] $ResourceLocation
    )

    Set-StrictMode -Version 3.0
    if ([string]::IsNullOrWhiteSpace($ResourceLocation)) { return $false }
    $guid = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
    $parent = $ParentMessage.Split("'")
    if ($parent.Count -ne 7 -or $parent[0] -cne 'The template deployment ' -or
        $parent[1] -cnotmatch '\A[A-Za-z0-9_.()-]+\z' -or
        $parent[2] -cne ' is not valid according to the validation procedure. The following resource provider(s) - ' -or
        $parent[4] -cne ' reported preflight validation errors. Tracking id is ' -or
        $parent[5] -cnotmatch "\A$guid\z" -or $parent[6] -cne '. See inner errors for details.') { return $false }
    $provider = [regex]::Match($parent[3], '\AMicrosoft\.ContainerService/managedClusters \((?<version>[0-9]{4}-[0-9]{2}-[0-9]{2})\)\z')
    $apiDate = [datetime]::MinValue
    if (-not $provider.Success -or -not [datetime]::TryParseExact($provider.Groups['version'].Value, 'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$apiDate)) { return $false }
    $parts = $Message.Split("'")
    if ($parts.Count -ne 9 -or
        $parts[0] -cnotmatch '\APreflight validation check for resource\(s\) for container service [A-Za-z0-9_-]+ in resource group [A-Za-z0-9_.()-]+ failed\. Message: The zone\(s\) \z' -or
        $parts[2] -cne ' for resource ' -or $parts[3] -cnotmatch '\A[a-z][a-z0-9]{0,11}\z' -or
        $parts[4] -cne ' is not supported. The supported zones for location ' -or
        $parts[5] -cnotmatch '\A[A-Za-z0-9]+(?: [A-Za-z0-9]+)*\z' -or
        $parts[6] -cne ' are ' -or $parts[7] -cne '' -or $parts[8] -cne '. Details: ') { return $false }
    $zones = $parts[1].Split(',')
    if ($zones.Count -gt 3 -or @($zones | Where-Object { $_ -cnotin @('1', '2', '3') }).Count -gt 0 -or
        @($zones | Select-Object -Unique).Count -ne $zones.Count) { return $false }
    return ($parts[5] -replace '\s', '').ToLowerInvariant() -eq ($ResourceLocation -replace '\s', '').ToLowerInvariant()
}
