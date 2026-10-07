function Remove-AvmBicepDeploymentRecord {
    <#
    .SYNOPSIS
        Deletes finished deployment records and confirms each one is gone.
    .DESCRIPTION
        Pass the records deepest first. Records under an already removed parent are skipped because
        removing the parent removed them. Any record that cannot be confirmed absent throws.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $DeploymentIds,

        [string[]] $RemovedParentIds = @(),

        [ValidateRange(1, 100)]
        [int] $RetryLimit = 3,

        [ValidateRange(0, 3600)]
        [int] $RetryInterval = 15,

        [switch] $ConfirmOnly,

        [scriptblock] $OnProgress
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    foreach ($deploymentId in $DeploymentIds) {
        if (-not $PSCmdlet.ShouldProcess($deploymentId, 'Remove or confirm finished deployment record')) {
            throw [AvmProcessException]::new("Deployment record removal was not performed: $deploymentId")
        }
        $underRemovedParent = @($RemovedParentIds | Where-Object {
                $deploymentId.StartsWith($_ + '/', [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
        if ($underRemovedParent) {
            if ($null -ne $OnProgress) { & $OnProgress $deploymentId 'Complete' }
            continue
        }
        $path = $deploymentId + '?api-version=2021-04-01'
        if (-not $ConfirmOnly) {
            $response = Invoke-AzRestMethod -Method DELETE -Path $path -ErrorAction Stop
            if (($response.StatusCode -isnot [int] -and $response.StatusCode -isnot [System.Net.HttpStatusCode]) -or
                $response.StatusCode -notin @(200, 202, 204, 404)) {
                throw [AvmProcessException]::new(
                    "Deployment record removal failed with HTTP $($response.StatusCode): $deploymentId")
            }
            if ($response.StatusCode -eq 404) {
                $null = ConvertFrom-AvmBicepDeploymentRecordResponse -Response $response -DeploymentId $deploymentId
                if ($null -ne $OnProgress) { & $OnProgress $deploymentId 'Complete' }
                continue
            }
            if ($null -ne $OnProgress) { & $OnProgress $deploymentId 'Pending' }
        }
        $absent = $false
        for ($attempt = 1; $attempt -le $RetryLimit; $attempt++) {
            $lookup = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
            $recordStatus = ConvertFrom-AvmBicepDeploymentRecordResponse -Response $lookup -DeploymentId $deploymentId
            if ($recordStatus -cin @('DeploymentNotFound', 'ResourceGroupNotFound')) {
                $absent = $true
                break
            }
            if ($attempt -lt $RetryLimit) {
                Start-Sleep -Seconds $RetryInterval
            }
        }
        if (-not $absent) {
            throw [AvmProcessException]::new("Deployment record still exists after cleanup: $deploymentId")
        }
        if ($null -ne $OnProgress) { & $OnProgress $deploymentId 'Complete' }
    }
}
