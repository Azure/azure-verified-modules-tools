function ConvertTo-AvmBicepCleanupCase {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Case
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    foreach ($key in @('path', 'scope', 'managementGroupId', 'resourceGroupName', 'metadataLocation', 'sourceHash')) {
        if ($Case[$key] -isnot [string] -or $Case[$key] -match '[\x00-\x1f\x7f]') {
            throw [AvmConfigurationException]::new("Cleanup case requires a valid string '$key'.")
        }
    }
    if ($Case['completionStarted'] -isnot [bool] -or
        $Case['scope'] -cnotin @('group', 'sub', 'mg', 'tenant') -or
        $Case['sourceHash'] -cnotmatch '^[0-9a-f]{64}$' -or
        $Case['metadataLocation'] -cnotmatch '^[a-z0-9]+$') {
        throw [AvmConfigurationException]::new('Cleanup case has invalid scope, location or completion metadata.')
    }
    $path = $Case['path']
    if ([System.IO.Path]::IsPathRooted($path) -or $path.Contains('\') -or $path.Contains(':') -or
        @($path.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or
        $path -cnotmatch '(?:^|/)tests/e2e/.+/main\.test\.bicep$') {
        throw [AvmConfigurationException]::new('Cleanup case must identify a relative tests/e2e main.test.bicep path.')
    }
    if ($Case['scope'] -eq 'group') {
        if ($Case['resourceGroupName'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,89}$' -or
            $Case['resourceGroupName'].EndsWith('.')) {
            throw [AvmConfigurationException]::new('Cleanup case has an invalid resource group name.')
        }
    }
    elseif ($Case['resourceGroupName'].Length -ne 0) {
        throw [AvmConfigurationException]::new('Only group-scope cleanup cases may specify a resource group name.')
    }
    if ($Case['scope'] -eq 'mg') {
        if ($Case['managementGroupId'] -cnotmatch '^[A-Za-z0-9_().-]{1,90}$' -or
            $Case['managementGroupId'] -in @('.', '..') -or $Case['managementGroupId'].EndsWith('.')) {
            throw [AvmConfigurationException]::new('Cleanup case has an invalid management group name.')
        }
    }
    elseif ($Case['managementGroupId'].Length -ne 0) {
        throw [AvmConfigurationException]::new('Only management-group cleanup cases may specify a management group name.')
    }
    return [ordered]@{
        path = $path; scope = $Case['scope']
        resourceGroupName = $Case['resourceGroupName']; managementGroupId = $Case['managementGroupId']
        metadataLocation = $Case['metadataLocation']; sourceHash = $Case['sourceHash']
        completionStarted = $Case['completionStarted']
    }
}
