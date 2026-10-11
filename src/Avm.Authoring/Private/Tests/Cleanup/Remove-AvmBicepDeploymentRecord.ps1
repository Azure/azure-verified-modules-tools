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
        [int] $RetryInterval = 15
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    foreach ($deploymentId in $DeploymentIds) {
        $underRemovedParent = @($RemovedParentIds | Where-Object {
                $deploymentId.StartsWith($_ + '/', [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
        if ($underRemovedParent) {
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($deploymentId, 'Remove finished deployment record')) {
            throw [AvmProcessException]::new("Deployment record removal was not performed: $deploymentId")
        }
        $path = $deploymentId + '?api-version=2021-04-01'
        $response = Invoke-AzRestMethod -Method DELETE -Path $path -ErrorAction Stop
        if ([int]$response.StatusCode -notin @(200, 202, 204, 404)) {
            throw [AvmProcessException]::new(
                "Deployment record removal failed with HTTP $($response.StatusCode): $deploymentId")
        }
        $absent = $false
        for ($attempt = 1; $attempt -le $RetryLimit; $attempt++) {
            $lookup = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
            if ([int]$lookup.StatusCode -eq 404) {
                $document = $lookup.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                $code = [string](Get-AvmPropertyValue -InputObject (
                        Get-AvmPropertyValue -InputObject $document -Name 'error') -Name 'code')
                if ($code -cnotin @('DeploymentNotFound', 'ResourceGroupNotFound')) {
                    throw [AvmProcessException]::new(
                        "Deployment record absence was not confirmed (code '$code'): $deploymentId")
                }
                $absent = $true
                break
            }
            if ([int]$lookup.StatusCode -ne 200) {
                throw [AvmProcessException]::new(
                    "Deployment record lookup failed with HTTP $($lookup.StatusCode): $deploymentId")
            }
            if ($attempt -lt $RetryLimit) {
                Start-Sleep -Seconds $RetryInterval
            }
        }
        if (-not $absent) {
            throw [AvmProcessException]::new("Deployment record still exists after cleanup: $deploymentId")
        }
    }
}
