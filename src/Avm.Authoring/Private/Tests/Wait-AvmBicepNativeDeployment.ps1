function Wait-AvmBicepNativeDeployment {
    <#
    .SYNOPSIS
        Watches one submitted deployment until it is terminal, without resubmitting it.
    .DESCRIPTION
        Used after a deployment request times out. Returns the exact deployment's
        terminal state and outputs, or throws when the outcome cannot be confirmed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $DeploymentId,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 3600,

        [ValidateRange(0, 60)]
        [int] $PollIntervalSeconds = 15
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    # The poll cap bounds the watch even when the clock barely moves between reads.
    $maximumPolls = [Math]::Ceiling($TimeoutSeconds / [Math]::Max($PollIntervalSeconds, 1)) + 1
    $consecutiveTimeouts = 0
    for ($poll = 0; $poll -lt $maximumPolls -and [datetime]::UtcNow -lt $deadline; $poll++) {
        $response = $null
        try {
            $response = Invoke-AzRestMethod -Method GET -Path ($DeploymentId + '?api-version=2021-04-01') -ErrorAction Stop
            $consecutiveTimeouts = 0
        }
        catch {
            if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -ne 'Timeout') { throw }
            $consecutiveTimeouts++
            if ($consecutiveTimeouts -ge 3) {
                throw [System.TimeoutException]::new(
                    "Status recovery for '$DeploymentId' stopped after three consecutive request timeouts.", $_.Exception)
            }
            Write-AvmLog -Level Warning -Message (
                "Status read for '$DeploymentId' timed out ($consecutiveTimeouts/3); the deployment is not resubmitted.")
        }
        if ($null -ne $response) {
            $statusCode = [int](Get-AvmPropertyValue -InputObject $response -Name 'StatusCode')
            if ($statusCode -ne 200) {
                throw [AvmProcessException]::new("Status recovery for '$DeploymentId' returned HTTP $statusCode.")
            }
            $document = ConvertFrom-Json -InputObject ([string]$response.Content) -AsHashtable -ErrorAction Stop
            if ($document -isnot [System.Collections.IDictionary] -or $document['id'] -ine $DeploymentId -or
                $document['properties'] -isnot [System.Collections.IDictionary]) {
                throw [AvmProcessException]::new("Status recovery did not return exactly the deployment '$DeploymentId'.")
            }
            $state = $document['properties']['provisioningState']
            if ($state -in @('Succeeded', 'Failed')) {
                $outputs = $document['properties']['outputs']
                return [pscustomobject]@{
                    State   = [string]$state
                    Outputs = if ($outputs -is [System.Collections.IDictionary]) { $outputs } else { @{} }
                }
            }
            if ($state -notin @('Accepted', 'Running', 'Creating', 'Updating')) {
                throw [AvmProcessException]::new("Deployment '$DeploymentId' has unsupported recovery state '$state'.")
            }
            Write-AvmLog -Level Info -Message "Deployment '$DeploymentId' remains '$state'; watching the same deployment."
        }
        $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Seconds ([Math]::Min($PollIntervalSeconds, [Math]::Ceiling($remaining))) }
    }
    throw [System.TimeoutException]::new(
        "Status recovery for '$DeploymentId' exceeded the $TimeoutSeconds-second recovery window.")
}
