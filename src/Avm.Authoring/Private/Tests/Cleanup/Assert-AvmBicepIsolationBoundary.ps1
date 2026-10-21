function Assert-AvmBicepIsolationBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $State,
        [AllowEmptyCollection()] [string[]] $ResourceIds = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not $State.Contains('isolationBoundary')) { return }
    foreach ($id in $ResourceIds) {
        $owned = @($State['ownedResourceGroups'] | Where-Object {
                $_['runId'] -ceq $State['runId'] -and
                ($id -ieq $_['id'] -or $id.StartsWith($_['id'] + '/', [System.StringComparison]::OrdinalIgnoreCase))
            })
        $root = @($State['deployments'] | Where-Object { $_['id'] -ieq $id })
        $outside = if ($State['isolationBoundary'] -ceq 'Empty') { $root.Count -ne 1 } else { $owned.Count -ne 1 }
        if ($outside) {
            throw [AvmConfigurationException]::new("Isolation refuses a target outside the verified ownership boundary: $id")
        }
        $resource = ConvertTo-AvmBicepCleanupResource -ResourceIds @($id)
        if ($resource.type -inotmatch '^Microsoft\.Storage/storageAccounts(?:/[^/]+)*$' -and
            $resource.type -notin @('Microsoft.Resources/deployments', 'Microsoft.Resources/resourceGroups')) {
            throw [AvmConfigurationException]::new("Isolation refuses cleanup with an unestablished provider boundary: $id")
        }
    }
}
