function ConvertFrom-AvmBicepDeploymentRecordResponse {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Response,

        [Parameter(Mandatory)]
        [string] $DeploymentId,

        [switch] $AllowDeleting
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Response -is [System.Collections.IList] -or
        ($Response.StatusCode -isnot [int] -and $Response.StatusCode -isnot [System.Net.HttpStatusCode]) -or
        $Response.Content -isnot [string]) {
        throw [AvmProcessException]::new("Invalid deployment record response: $DeploymentId")
    }
    try {
        $document = ConvertFrom-AvmStrictJson -Json $Response.Content -RejectCaseInsensitiveDuplicates
    }
    catch [System.ArgumentException] {
        throw [AvmProcessException]::new("Invalid deployment record JSON: $DeploymentId")
    }
    if ($Response.StatusCode -eq 404) {
        $errorBody = $document['error']
        if ($errorBody -is [System.Collections.IDictionary] -and $errorBody['code'] -is [string]) {
            $expectedTarget = $DeploymentId
            $group = [regex]::Match($DeploymentId, '(?i)\A(?<group>/subscriptions/[^/]+/resourceGroups/[^/]+)/providers/Microsoft\.Resources/deployments/[^/]+\z')
            $code = $errorBody['code']
            if ($code -ceq 'ResourceGroupNotFound' -and $group.Success) { $expectedTarget = $group.Groups['group'].Value }
            if (($code -ceq 'DeploymentNotFound' -or ($code -ceq 'ResourceGroupNotFound' -and $group.Success)) -and
                ($null -eq $errorBody['target'] -or
                ($errorBody['target'] -is [string] -and $errorBody['target'] -ieq $expectedTarget))) {
                return $code
            }
        }
        throw [AvmProcessException]::new("Deployment record absence was not confirmed: $DeploymentId")
    }
    if ($Response.StatusCode -ne 200) {
        throw [AvmProcessException]::new("Deployment record lookup failed with HTTP $($Response.StatusCode): $DeploymentId")
    }
    $properties = $document['properties']
    if ($document.Contains('error') -or $document['id'] -isnot [string] -or $document['id'] -ine $DeploymentId -or
        $properties -isnot [System.Collections.IDictionary] -or $properties['provisioningState'] -isnot [string] -or
        ($properties['provisioningState'] -cnotin @('Succeeded', 'Failed') -and
        (-not $AllowDeleting -or $properties['provisioningState'] -cne 'Deleting'))) {
        throw [AvmProcessException]::new("Deployment record response did not identify a terminal deployment: $DeploymentId")
    }
    return $properties['provisioningState']
}
