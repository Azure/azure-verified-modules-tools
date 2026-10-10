function Assert-AvmBicepCleanupDeploymentTerminal {
    <#
    .SYNOPSIS
        Requires terminal, exact deployment history before preserving retry evidence.
    .DESCRIPTION
        Attempted root deployments must be Failed because retries only follow a failed
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

    $response = Invoke-AvmBicepRead -Activity 'Read terminal deployment history' -Read {
        Invoke-AzRestMethod -Method GET -Path ($Record.Id + '?api-version=2021-04-01') -ErrorAction Stop
    }
    $state = ConvertFrom-AvmBicepDeploymentRecordResponse -Response $response -DeploymentId $Record.Id
    if ($Record.PreflightRejected -and $state -ceq 'DeploymentNotFound') {
        $Record.Status = 'RejectedWithoutRecord'
        return
    }
    $allowed = if ($Record.Required -and -not $Record.PreflightRejected) { @('Failed') } else { @('Succeeded', 'Failed') }
    if ($state -cnotin $allowed) {
        throw [AvmProcessException]::new(
            "Deployment is not in an allowed terminal state for retry evidence ('$state'): $($Record.Id)")
    }
    $Record.ProvisioningState = $state
}
