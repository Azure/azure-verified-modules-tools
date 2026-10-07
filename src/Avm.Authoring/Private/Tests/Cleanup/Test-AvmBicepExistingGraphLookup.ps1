function Test-AvmBicepExistingGraphLookup {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Operation,

        [Parameter(Mandatory)]
        [string] $DeploymentId,

        [hashtable] $Exports = @{}
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $target = $Operation['targetResource']
    if ($Operation['provisioningOperation'] -cne 'Create' -or $Operation['provisioningState'] -cne 'Succeeded' -or
        $null -ne $Operation['statusCode'] -or $null -ne $Operation['statusMessage'] -or
        $target -isnot [System.Collections.IDictionary] -or $target.Contains('id') -or
        $target['resourceType'] -isnot [string] -or $target['resourceType'] -cne 'Microsoft.Graph/servicePrincipals@v1.0' -or
        $target['symbolicName'] -isnot [string] -or [string]::IsNullOrWhiteSpace($target['symbolicName'])) { return $false }
    $extension = $target['extension']
    if ($extension -isnot [System.Collections.IDictionary] -or
        $extension['name'] -isnot [string] -or $extension['name'] -cne 'MicrosoftGraph' -or
        $extension['version'] -isnot [string] -or $extension['version'] -cne '1.0.0' -or
        $extension['alias'] -isnot [string] -or [string]::IsNullOrWhiteSpace($extension['alias'])) { return $false }
    if (-not $Exports.ContainsKey($DeploymentId)) {
        $response = Invoke-AzRestMethod -Method POST -Path ($DeploymentId + '/exportTemplate?api-version=2025-04-01') -ErrorAction Stop
        if (($response.StatusCode -isnot [int] -and $response.StatusCode -isnot [System.Net.HttpStatusCode]) -or
            $response.StatusCode -ne 200 -or $response.Content -isnot [string]) {
            throw [AvmProcessException]::new("Cannot export deployment '$DeploymentId': HTTP $($response.StatusCode).")
        }
        $Exports[$DeploymentId] = ConvertFrom-AvmStrictJson -Json $response.Content -RejectCaseInsensitiveDuplicates
    }
    $export = $Exports[$DeploymentId]
    $template = $export['template']
    if ($export.Contains('error') -or $template -isnot [System.Collections.IDictionary] -or
        $template['languageVersion'] -isnot [string] -or $template['languageVersion'] -cne '2.0' -or
        $template['$schema'] -isnot [string]) { return $false }
    $schemaName = if ($DeploymentId -match '^/subscriptions/[^/]+/resourceGroups/') { 'deploymentTemplate' }
    elseif ($DeploymentId -match '^/subscriptions/') { 'subscriptionDeploymentTemplate' }
    elseif ($DeploymentId -match '^/providers/Microsoft\.Management/managementGroups/') { 'managementGroupDeploymentTemplate' }
    else { 'tenantDeploymentTemplate' }
    if ($template['$schema'] -cnotmatch "\Ahttps://schema\.management\.azure\.com/schemas/[0-9]{4}-[0-9]{2}-[0-9]{2}/$schemaName\.json#?\z" -or
        $template['resources'] -isnot [System.Collections.IDictionary] -or
        $template['imports'] -isnot [System.Collections.IDictionary]) { return $false }
    $declaration = $template['resources'][$target['symbolicName']]
    $import = $template['imports'][$extension['alias']]
    return $declaration -is [System.Collections.IDictionary] -and
    $declaration['existing'] -is [bool] -and $declaration['existing'] -and
    $declaration['type'] -is [string] -and $declaration['type'] -ceq $target['resourceType'] -and
    $declaration['import'] -is [string] -and $declaration['import'] -ceq $extension['alias'] -and
    $import -is [System.Collections.IDictionary] -and $import['provider'] -is [string] -and
    $import['provider'] -ceq $extension['name'] -and $import['version'] -is [string] -and $import['version'] -ceq $extension['version']
}
