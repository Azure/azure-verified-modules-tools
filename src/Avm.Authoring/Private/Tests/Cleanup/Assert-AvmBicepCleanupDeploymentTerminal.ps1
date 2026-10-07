function Assert-AvmBicepCleanupDeploymentTerminal {
    <#
    .SYNOPSIS
        Throws unless a deployment record has finished, so relocation never removes resources that are still changing.
    .DESCRIPTION
        Attempted root deployments must be Failed because relocation only follows a failed regional
        deployment. Nested deployments may be Succeeded or Failed. Only a proven preflight
        rejection and explicit absence of that exact record can bypass discovery.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Record
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $response = Invoke-AzRestMethod -Method GET -Path ($Record.Id + '?api-version=2021-04-01') -ErrorAction Stop
    $state = ConvertFrom-AvmBicepDeploymentRecordResponse -Response $response -DeploymentId $Record.Id
    if ($Record.PreflightRejected -and $state -ceq 'DeploymentNotFound') {
        $Record.Status = 'RejectedWithoutRecord'
        return
    }
    $allowed = if ($Record.Required -and -not $Record.PreflightRejected) { @('Failed') } else { @('Succeeded', 'Failed') }
    if ($state -cnotin $allowed) {
        throw [AvmProcessException]::new(
            "Deployment is not in an allowed terminal state for relocation ('$state'): $($Record.Id)")
    }
    $Record.ProvisioningState = $state
}
