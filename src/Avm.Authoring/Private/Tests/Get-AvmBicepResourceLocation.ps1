function Get-AvmBicepResourceLocation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $ResourceType,

        [Parameter(Mandatory)]
        [string] $MetadataLocation,

        [string[]] $UnavailableRegions = @(),

        [string[]] $AllowedRegions,

        [string[]] $ExcludedRegions
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $regions = (Get-AvmBicepRetryPolicy)['regions']
    if (-not $PSBoundParameters.ContainsKey('AllowedRegions')) { $AllowedRegions = $regions['allowed'] }
    if (-not $PSBoundParameters.ContainsKey('ExcludedRegions')) { $ExcludedRegions = $regions['excluded'] }

    $unavailable = @($UnavailableRegions | ForEach-Object { ($_ -replace '\s', '').ToLowerInvariant() })
    $excluded = @($ExcludedRegions | ForEach-Object { ($_ -replace '\s', '').ToLowerInvariant() }) + $unavailable
    $allowed = @($AllowedRegions | ForEach-Object { ($_ -replace '\s', '').ToLowerInvariant() })
    if (-not [string]::IsNullOrWhiteSpace($ResourceType)) {
        if (-not (Test-AvmMetadataResourceType -CanonicalType $ResourceType)) {
            throw [AvmConfigurationException]::new('Automatic resource location selection requires a canonical ARM resource type.')
        }
        $providerName, $typeName = $ResourceType -split '/', 2
        $provider = Invoke-AvmBicepRead -Activity "Read provider locations for $providerName" -Read {
            Get-AzResourceProvider -ProviderNamespace $providerName -ErrorAction Stop
        }
        $resourceTypes = Get-AvmPropertyValue -InputObject $provider -Name 'ResourceTypes'
        $providerLocations = @(
            foreach ($type in $resourceTypes) {
                if ((Get-AvmPropertyValue -InputObject $type -Name 'ResourceTypeName') -eq $typeName) {
                    foreach ($location in (Get-AvmPropertyValue -InputObject $type -Name 'Locations')) {
                        if ($location -is [string] -and -not [string]::IsNullOrWhiteSpace($location)) {
                            ($location -replace '\s', '').ToLowerInvariant()
                        }
                    }
                }
            }
        ) | Sort-Object -Unique
        $providerLocations = @($providerLocations)
        if ($providerLocations.Count -eq 0) {
            throw [AvmConfigurationException]::new(
                "No location metadata was returned for '$ResourceType'; supply an explicit resource location.")
        }
        if ($providerLocations.Count -eq 1 -and $providerLocations[0] -eq 'global') {
            $location = ($MetadataLocation -replace '\s', '').ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($location) -or $location -in $unavailable) {
                throw [AvmConfigurationException]::new('The global resource requires a metadata location that has not failed validation.')
            }
            return [pscustomobject]@{ Location = $location; IsGlobal = $true }
        }
        $locations = Invoke-AvmBicepRead -Activity 'Read Azure location metadata' -Read {
            Get-AzLocation -ErrorAction Stop
        }
        $candidates = @(
            foreach ($entry in $locations) {
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
    else {
        $candidates = @($allowed | Where-Object { $_ -notin $excluded -and -not [string]::IsNullOrWhiteSpace($_) })
    }
    $candidates = @($candidates | Sort-Object -Unique)
    if ($candidates.Count -eq 0) {
        throw [AvmConfigurationException]::new('No supported, allowed resource regions remain after exclusions and failed validations.')
    }
    $index = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($candidates.Count)
    return [pscustomobject]@{ Location = $candidates[$index]; IsGlobal = $false }
}
