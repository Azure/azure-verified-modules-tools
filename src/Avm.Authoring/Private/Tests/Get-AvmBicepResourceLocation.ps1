function Get-AvmBicepResourceLocation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $ResourceType,

        [string] $MetadataLocation,

        [string[]] $UnavailableRegions = @(),

        [string[]] $AllowedRegions,

        [string[]] $ExcludedRegions,

        [string] $AzPath,

        [string] $SubscriptionId,

        [string] $WorkingDirectory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $regions = (Get-AvmBicepRetryPolicy)['regions']
    if (-not $PSBoundParameters.ContainsKey('AllowedRegions')) { $AllowedRegions = $regions['allowed'] }
    if (-not $PSBoundParameters.ContainsKey('ExcludedRegions')) { $ExcludedRegions = $regions['excluded'] }

    $unavailable = @($UnavailableRegions | ForEach-Object { ($_ -replace '\s', '').ToLowerInvariant() })
    $excluded = @($ExcludedRegions | ForEach-Object { ($_ -replace '\s', '').ToLowerInvariant() }) + $unavailable
    $allowed = @($AllowedRegions | ForEach-Object { ($_ -replace '\s', '').ToLowerInvariant() })
    $candidates = @($allowed | Where-Object { $_ -notin $excluded -and -not [string]::IsNullOrWhiteSpace($_) })
    if (-not [string]::IsNullOrWhiteSpace($ResourceType)) {
        if ([string]::IsNullOrWhiteSpace($AzPath) -or [string]::IsNullOrWhiteSpace($SubscriptionId) -or
            [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            throw [AvmConfigurationException]::new(
                'Azure CLI resource-location discovery requires an executable, subscription and working directory.')
        }
        if (-not (Test-AvmMetadataResourceType -CanonicalType $ResourceType)) {
            throw [AvmConfigurationException]::new('Automatic resource location selection requires a canonical ARM resource type.')
        }
        $providerName, $typeName = $ResourceType -split '/', 2
        $provider = Invoke-AvmBicepRead -Activity "Read provider locations for $providerName" -Read {
            $result = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
                'provider', 'show', '--namespace', $providerName,
                '--subscription', $SubscriptionId,
                '--query', '{ProviderNamespace:namespace,ResourceTypes:resourceTypes[].{ResourceTypeName:resourceType,Locations:locations}}',
                '--output', 'json'
            ) -WorkingDirectory $WorkingDirectory -TimeoutSec 60 -IgnoreExitCode
            if ($result.ExitCode -ne 0) {
                throw [AvmProcessException]::new((Add-AvmProcessFailureDetail `
                            -Message "Cannot read provider locations for '$providerName'." `
                            -StdOut ([string]$result.StdOut) -StdErr ([string]$result.StdErr)))
            }
            try {
                ConvertFrom-AvmStrictJson -Json ([string]$result.StdOut) `
                    -Description 'Azure CLI provider-location response' -RejectCaseInsensitiveDuplicates
            }
            catch [System.ArgumentException] {
                throw [AvmProcessException]::new(
                    "Azure CLI returned invalid provider-location JSON: $($_.Exception.Message)")
            }
        }
        $providers = @($provider)
        $resourceTypes = @(
            foreach ($provider in $providers) {
                if ($provider -isnot [System.Collections.IDictionary]) {
                    throw [AvmProcessException]::new('Azure CLI returned a malformed provider metadata object.')
                }
                $namespace = Get-AvmPropertyValue -InputObject $provider -Name 'ProviderNamespace' -NoEnumerate
                if ($namespace -isnot [string] -or $namespace -ine $providerName) {
                    throw [AvmProcessException]::new(
                        "Location metadata returned an unexpected provider namespace for '$providerName'.")
                }
                $types = Get-AvmPropertyValue -InputObject $provider -Name 'ResourceTypes' -NoEnumerate
                if (-not $provider.Contains('ResourceTypes') -or $types -isnot [array]) {
                    throw [AvmProcessException]::new('Azure CLI returned a malformed provider resource-type collection.')
                }
                $types
            }
        )
        foreach ($type in $resourceTypes) {
            if ($type -isnot [System.Collections.IDictionary] -or
                -not $type.Contains('ResourceTypeName') -or
                $type['ResourceTypeName'] -isnot [string] -or
                -not $type.Contains('Locations') -or $type['Locations'] -isnot [array]) {
                throw [AvmProcessException]::new('Azure CLI returned a malformed provider resource-type row.')
            }
        }
        $matchingTypes = @($resourceTypes | Where-Object {
                (Get-AvmPropertyValue -InputObject $_ -Name 'ResourceTypeName') -eq $typeName
            })
        $providerLocations = @(
            foreach ($type in $matchingTypes) {
                foreach ($location in (Get-AvmPropertyValue -InputObject $type -Name 'Locations')) {
                    if ($location -is [string] -and -not [string]::IsNullOrWhiteSpace($location)) {
                        ($location -replace '\s', '').ToLowerInvariant()
                    }
                }
            }
        ) | Sort-Object -Unique
        $providerLocations = @($providerLocations)
        if ($providerLocations.Count -eq 0) {
            if ($matchingTypes.Count -eq 0 -or @($matchingTypes | Where-Object {
                        $locations = Get-AvmPropertyValue -InputObject $_ -Name 'Locations' -NoEnumerate
                        $null -eq $locations -or @($locations).Count -gt 0
                    }).Count -gt 0) {
                throw [AvmConfigurationException]::new(
                    "No location metadata was returned for '$ResourceType'; supply an explicit resource location.")
            }
        }
        if ($providerLocations.Count -eq 1 -and $providerLocations[0] -eq 'global') {
            $location = ($MetadataLocation -replace '\s', '').ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($location) -or $location -in $unavailable) {
                throw [AvmConfigurationException]::new('The global resource requires a metadata location that has not failed validation.')
            }
            return [pscustomobject]@{ Location = $location; IsGlobal = $true }
        }
        if ($providerLocations.Count -gt 0) {
            $locations = Invoke-AvmBicepRead -Activity 'Read Azure location metadata' -Read {
                $result = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
                    'rest', '--method', 'get',
                    '--url', "/subscriptions/$SubscriptionId/locations?api-version=2022-12-01",
                    '--query', 'value[].{Location:name,DisplayName:displayName,PairedRegion:metadata.pairedRegion,RegionCategory:metadata.regionCategory}',
                    '--output', 'json'
                ) -WorkingDirectory $WorkingDirectory -TimeoutSec 60 -IgnoreExitCode
                if ($result.ExitCode -ne 0) {
                    throw [AvmProcessException]::new((Add-AvmProcessFailureDetail `
                                -Message 'Cannot read Azure location metadata.' `
                                -StdOut ([string]$result.StdOut) -StdErr ([string]$result.StdErr)))
                }
                try {
                    $value = ConvertFrom-AvmStrictJson -Json ([string]$result.StdOut) `
                        -Description 'Azure CLI location response' -AllowArray -RejectCaseInsensitiveDuplicates
                    if ($value -isnot [array]) {
                        throw [System.ArgumentException]::new(
                            'Azure CLI location response must be a JSON array.')
                    }
                    return , $value
                }
                catch [System.ArgumentException] {
                    throw [AvmProcessException]::new(
                        "Azure CLI returned invalid location-metadata JSON: $($_.Exception.Message)")
                }
            }
            $candidates = @(
                foreach ($entry in $locations) {
                    if ($entry -isnot [System.Collections.IDictionary] -or
                        -not $entry.Contains('Location') -or $entry['Location'] -isnot [string] -or
                        -not $entry.Contains('DisplayName') -or $entry['DisplayName'] -isnot [string] -or
                        -not $entry.Contains('PairedRegion') -or
                        -not $entry.Contains('RegionCategory') -or $entry['RegionCategory'] -isnot [string]) {
                        throw [AvmProcessException]::new('Azure CLI returned a malformed location metadata row.')
                    }
                    $location = [string](Get-AvmPropertyValue -InputObject $entry -Name 'Location')
                    $displayName = [string](Get-AvmPropertyValue -InputObject $entry -Name 'DisplayName')
                    $pairedRegion = Get-AvmPropertyValue -InputObject $entry -Name 'PairedRegion'
                    $category = Get-AvmPropertyValue -InputObject $entry -Name 'RegionCategory'
                    $location = ($location -replace '\s', '').ToLowerInvariant()
                    if (($location -in $providerLocations -or
                            ($displayName -replace '\s', '').ToLowerInvariant() -in $providerLocations) -and
                        $location -in $allowed -and $location -notin $excluded -and
                        $null -ne $pairedRegion -and "$pairedRegion" -ne '{}' -and
                        "$pairedRegion".Length -gt 0 -and $category -eq 'Recommended') {
                        $location
                    }
                }
            )
        }
    }
    $candidates = @($candidates | Sort-Object -Unique)
    if ($candidates.Count -eq 0) {
        throw [AvmConfigurationException]::new('No supported, allowed resource regions remain after exclusions and failed validations.')
    }
    $index = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($candidates.Count)
    return [pscustomobject]@{ Location = $candidates[$index]; IsGlobal = $false }
}
