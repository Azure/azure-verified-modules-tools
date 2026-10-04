function Get-AvmBicepPendingDeployment {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [ValidateRange(1, 1000)]
        [int] $RetryLimit = 40,

        [ValidateRange(0, 3600)]
        [int] $RetryInterval = 60
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $unresolved = @($State['deployments'] | Where-Object { $_['status'] -in @('Attempted', 'Unknown') })
    $pending = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $unresolved) {
        $pending.Add($entry['id'], [pscustomobject]@{
                DeploymentId = $entry['id']
                Code         = 'DeploymentOutcomeUnknown'
                Message      = "Deployment outcome is not confirmed; retaining resources for '$($entry['id'])'."
            })
    }
    for ($round = 1; $round -le $RetryLimit -and $pending.Count -gt 0; $round++) {
        foreach ($entry in $unresolved) {
            $id = $entry['id']
            if (-not $pending.ContainsKey($id)) { continue }
            try {
                $response = Invoke-AzRestMethod -Method GET -Path ($id + '?api-version=2021-04-01') -ErrorAction Stop
                $body = ConvertFrom-Json -InputObject $response.Content -AsHashtable -ErrorAction Stop
                if ([int]$response.StatusCode -eq 200 -and $body['id'] -ieq $id) {
                    $properties = Get-AvmPropertyValue -InputObject $body -Name 'properties'
                    $status = Get-AvmPropertyValue -InputObject $properties -Name 'provisioningState'
                    if ($status -in @('Succeeded', 'Failed', 'Canceled')) {
                        $entry['status'] = if ($status -eq 'Succeeded') { 'Succeeded' } else { 'Failed' }
                        $null = $pending.Remove($id)
                        continue
                    }
                    $pending[$id].Code = 'DeploymentNotTerminal'
                    $pending[$id].Message = "Deployment is not confirmed terminal; retaining resources for '$id'."
                }
                elseif ([int]$response.StatusCode -eq 404 -and
                    $id -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Resources/deployments/[^/]+$' -and
                    (Get-AvmPropertyValue -InputObject (
                        Get-AvmPropertyValue -InputObject $body -Name 'error') -Name 'code') -ceq 'ResourceGroupNotFound') {
                    $entry['status'] = 'Failed'
                    $null = $pending.Remove($id)
                }
                elseif ([int]$response.StatusCode -notin @(200, 404)) {
                    $pending[$id].Code = 'DeploymentStatusUnavailable'
                    $pending[$id].Message = "Deployment status lookup returned HTTP $($response.StatusCode); retaining resources for '$id'."
                    return [pscustomobject]@{ Pending = @($pending.Keys); Issues = @($pending.Values) }
                }
            }
            catch {
                if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') { throw }
                $pending[$id].Code = 'DeploymentStatusUnavailable'
                $pending[$id].Message = "Deployment status could not be verified; retaining resources for '$id'."
                Write-AvmLog -Level Warning -Message $pending[$id].Message
                return [pscustomobject]@{ Pending = @($pending.Keys); Issues = @($pending.Values) }
            }
        }
        if ($pending.Count -gt 0 -and $round -lt $RetryLimit) {
            Write-AvmLog -Level Info -Message "Waiting for $($pending.Count) deployment outcome(s), check $round/$RetryLimit."
            Start-Sleep -Seconds $RetryInterval
        }
    }
    return [pscustomobject]@{ Pending = @($pending.Keys); Issues = @($pending.Values) }
}
