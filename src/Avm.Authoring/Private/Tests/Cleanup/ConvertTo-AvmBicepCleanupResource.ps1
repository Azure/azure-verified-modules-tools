function ConvertTo-AvmBicepCleanupResource {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string[]] $ResourceIds = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    foreach ($resourceId in $ResourceIds) {
        if ($resourceId -notmatch '^/(?:subscriptions|providers)/' -or
            $resourceId -match '[\\?#\x00-\x1f]|//|/(?:\.|\.\.)(?:/|$)|/$') {
            throw [AvmConfigurationException]::new("Invalid Azure cleanup resource ID: $resourceId")
        }
        $parts = $resourceId.Split('/')
        $index = 1
        if ($parts[$index] -ieq 'subscriptions') {
            $subscriptionId = [guid]::Empty
            if ($parts.Count -lt 5 -or
                -not [guid]::TryParse($parts[2], [ref]$subscriptionId) -or
                $subscriptionId -eq [guid]::Empty) {
                throw [AvmConfigurationException]::new("Invalid cleanup subscription in '$resourceId'.")
            }
            $index = 3
            if ($parts[$index] -ieq 'resourceGroups') {
                $index = 5
                if ($parts.Count -eq 5) {
                    @{ resourceId = $resourceId; type = 'Microsoft.Resources/resourceGroups' }
                    continue
                }
            }
        }

        $resourceType = ''
        while ($index -lt $parts.Count) {
            if ($parts[$index] -ine 'providers' -or $index + 3 -ge $parts.Count) {
                throw [AvmConfigurationException]::new("Incomplete cleanup resource ID: $resourceId")
            }
            $resourceType = $parts[$index + 1]
            $index += 2
            while ($index -lt $parts.Count -and $parts[$index] -ine 'providers') {
                if ($index + 1 -ge $parts.Count) {
                    throw [AvmConfigurationException]::new("Unpaired resource type in '$resourceId'.")
                }
                $resourceType += '/' + $parts[$index]
                $index += 2
            }
        }
        if ([string]::IsNullOrEmpty($resourceType)) {
            throw [AvmConfigurationException]::new("Missing provider resource in '$resourceId'.")
        }
        @{ resourceId = $resourceId; type = $resourceType }
    }
}
