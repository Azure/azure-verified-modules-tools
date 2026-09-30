function Assert-AvmBicepDeploymentSucceeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Output,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [string] $ResourceGroupName,

        [ValidateSet('group', 'sub', 'mg', 'tenant')]
        [string] $Scope = 'group',

        [string] $ManagementGroupId,

        [Parameter(Mandatory)]
        [string] $DeploymentName
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Json -Json $Output -ErrorAction SilentlyContinue)) {
        throw [AvmProcessException]::new(
            "ARM deployment '$DeploymentName' returned invalid JSON.")
    }
    $deployment = $Output | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $expectedId = Get-AvmBicepScopedDeploymentId -Scope $Scope `
        -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
        -ManagementGroupId $ManagementGroupId -DeploymentName $DeploymentName
    if ($deployment -isnot [System.Collections.IDictionary] -or
        -not [string]::Equals([string]$deployment['id'], $expectedId, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$deployment['name'], $DeploymentName, [System.StringComparison]::OrdinalIgnoreCase) -or
        $deployment['properties'] -isnot [System.Collections.IDictionary] -or
        $deployment['properties']['provisioningState'] -cne 'Succeeded') {
        throw [AvmProcessException]::new(
            "ARM deployment '$DeploymentName' did not confirm a succeeded $Scope deployment at '$expectedId'.")
    }
}
