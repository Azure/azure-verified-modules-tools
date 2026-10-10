function Wait-AvmBicepNativeDeployment {
    <#
    .SYNOPSIS
        Watches one submitted deployment until it is terminal, without resubmitting it.
    .DESCRIPTION
        Used after a request timeout, exact nested read 404 or management-group HTTP 403. Returns the
        exact deployment's terminal state and outputs, or throws when its outcome
        cannot be confirmed. An explicit profile preserves the submission context.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $DeploymentId,

        [ValidateNotNull()]
        [object] $DefaultProfile,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds,

        [ValidateRange(0, 60)]
        [int] $PollIntervalSeconds
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $policy = (Get-AvmBicepRetryPolicy)['observation']
    if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds')) { $TimeoutSeconds = $policy['timeoutSeconds'] }
    if (-not $PSBoundParameters.ContainsKey('PollIntervalSeconds')) { $PollIntervalSeconds = $policy['pollIntervalSeconds'] }

    $request = @{
        Method = 'GET'; Path = $DeploymentId + '?api-version=2021-04-01'; ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('DefaultProfile')) {
        $request.DefaultProfile = $DefaultProfile
    }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    # The poll cap bounds the watch even when the clock barely moves between reads.
    $maximumPolls = [Math]::Ceiling($TimeoutSeconds / [Math]::Max($PollIntervalSeconds, 1)) + 1
    $consecutiveTimeouts = 0
    for ($poll = 0; $poll -lt $maximumPolls -and [datetime]::UtcNow -lt $deadline; $poll++) {
        $response = $null
        try {
            $response = Invoke-AzRestMethod @request
            $consecutiveTimeouts = 0
        }
        catch {
            if (-not (Test-AvmBicepRetryErrorRecord -ErrorRecord $_ -Kind MetadataTimeout)) { throw }
            $consecutiveTimeouts++
            if ($consecutiveTimeouts -ge $policy['consecutiveTimeouts']) {
                $exception = [System.TimeoutException]::new(
                    "Status recovery for '$DeploymentId' stopped after $consecutiveTimeouts consecutive request timeouts.", $_.Exception)
                $exception.Data['ReadErrorRecord'] = $_
                throw $exception
            }
            Write-AvmLog -Level Warning -Message (
                "Status read for '$DeploymentId' timed out ($consecutiveTimeouts/$($policy['consecutiveTimeouts'])); the deployment is not resubmitted.")
        }
        if ($null -ne $response) {
            $statusCode = $null
            if ($response -is [System.Collections.IDictionary]) { $statusCode = $response['StatusCode'] }
            elseif ($response -isnot [System.Collections.IList]) {
                $property = $response.PSObject.Properties['StatusCode']
                if ($null -ne $property) { $statusCode = $property.Value }
            }
            if ($statusCode -isnot [int] -and $statusCode -isnot [System.Net.HttpStatusCode]) {
                throw [AvmProcessException]::new("Status recovery for '$DeploymentId' returned an invalid HTTP status.")
            }
            if ($statusCode -ne 200) {
                throw [AvmProcessException]::new("Status recovery for '$DeploymentId' returned HTTP $statusCode.")
            }
            $document = ConvertFrom-AvmBicepRestResponse -Response $response -Activity "Status recovery for '$DeploymentId'"
            if ($document -isnot [System.Collections.IDictionary] -or
                $document['id'] -isnot [string] -or $document['id'] -ine $DeploymentId -or $document.Contains('error') -or
                $document['properties'] -isnot [System.Collections.IDictionary]) {
                throw [AvmProcessException]::new("Status recovery did not return exactly the deployment '$DeploymentId'.")
            }
            $state = $document['properties']['provisioningState']
            if ($state -isnot [string]) {
                throw [AvmProcessException]::new("Deployment '$DeploymentId' returned an invalid recovery state.")
            }
            if ($state -cin @('Succeeded', 'Failed')) {
                $outputs = $document['properties']['outputs']
                if ($null -ne $outputs -and $outputs -isnot [System.Collections.IDictionary]) {
                    throw [AvmProcessException]::new("Deployment '$DeploymentId' returned invalid recovery outputs.")
                }
                return [pscustomobject]@{
                    State   = [string]$state
                    Outputs = if ($outputs -is [System.Collections.IDictionary]) { $outputs } else { @{} }
                }
            }
            if ($state -cnotin @('Accepted', 'Running', 'Creating', 'Updating')) {
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
