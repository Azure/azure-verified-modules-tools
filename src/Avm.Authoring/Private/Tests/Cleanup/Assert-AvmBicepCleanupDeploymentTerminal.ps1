function Assert-AvmBicepCleanupDeploymentTerminal {
    <#
    .SYNOPSIS
        Throws unless a deployment record has finished, so relocation never removes resources that are still changing.
    .DESCRIPTION
        Attempted root deployments must be Failed because relocation only follows a failed regional
        deployment. Nested deployments may be Succeeded or Failed. An absent record is left to the
        operations lookup, which classifies it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Record
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $response = Invoke-AzRestMethod -Method GET -Path ($Record.Id + '?api-version=2021-04-01') -ErrorAction Stop
    $document = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ([int]$response.StatusCode -eq 404) {
        $errorCode = [string](Get-AvmPropertyValue -InputObject (
                Get-AvmPropertyValue -InputObject $document -Name 'error') -Name 'code')
        if ($errorCode -cin @('DeploymentNotFound', 'ResourceGroupNotFound')) {
            return
        }
    }
    if ([int]$response.StatusCode -ne 200) {
        throw [AvmProcessException]::new(
            "Deployment lookup failed: HTTP $($response.StatusCode), deployment '$($Record.Id)'.")
    }
    $state = [string](Get-AvmPropertyValue -InputObject (
            Get-AvmPropertyValue -InputObject $document -Name 'properties') -Name 'provisioningState')
    $allowed = if ($Record.Required -and -not $Record.PreflightRejected) { @('Failed') } else { @('Succeeded', 'Failed') }
    if ($state -cnotin $allowed) {
        throw [AvmProcessException]::new(
            "Deployment is not in an allowed terminal state for relocation ('$state'): $($Record.Id)")
    }
}
