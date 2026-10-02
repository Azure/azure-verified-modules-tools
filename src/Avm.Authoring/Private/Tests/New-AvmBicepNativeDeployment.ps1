function New-AvmBicepNativeDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [string] $StatePath,

        [Parameter(Mandatory)]
        [hashtable] $DeploymentInput,

        [ValidateRange(1, 3)]
        [int] $RetryLimit = 3
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    for ($attempt = 1; $attempt -le $RetryLimit; $attempt++) {
        $name = 'avm-e2e-{0}-t{1}' -f $State['runId'], $attempt
        $idOptions = @{
            Scope             = $DeploymentInput.Scope
            SubscriptionId    = $State['subscriptionId']
            DeploymentName    = $name
            ResourceGroupName = $DeploymentInput['ResourceGroupName']
            ManagementGroupId = $DeploymentInput['ManagementGroupId']
        }
        $id = Get-AvmBicepScopedDeploymentId @idOptions
        if (-not $PSCmdlet.ShouldProcess($id, 'Record and submit Bicep test deployment')) {
            return [pscustomobject]@{ Status = 'skipped'; DeploymentName = $name; DeploymentId = $id; Outputs = @{} }
        }
        $entry = @{ id = $id; status = 'Attempted'; preflightRejected = $false }
        $State['deployments'] = @($State['deployments']) + @($entry)
        Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
        $inputOptions = $DeploymentInput.Clone()
        $inputOptions.DeploymentName = $name
        $response = $null
        $failure = $null
        try {
            $response = Invoke-AvmBicepNativeArmOperation @inputOptions -Operation Create -Confirm:$false
            $provisioningState = Get-AvmPropertyValue -InputObject $response -Name 'ProvisioningState'
            if ($provisioningState -eq 'Succeeded') {
                $entry['status'] = 'Succeeded'
                Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                $outputs = Get-AvmPropertyValue -InputObject $response -Name 'Outputs'
                if ($null -eq $outputs) { $outputs = @{} }
                return [pscustomobject]@{
                    Status = 'pass'; DeploymentName = $name; DeploymentId = $id; Outputs = $outputs
                }
            }
            $entry['status'] = if ($provisioningState -eq 'Failed') { 'Failed' } else { 'Unknown' }
        }
        catch {
            $failure = $_
            $kind = Get-AvmBicepDeploymentErrorKind -ErrorRecord $_
            if (Test-AvmBicepDeploymentPreflightRejection -ErrorRecord $_ -DeploymentName $name) {
                $entry['status'] = 'Rejected'
                $entry['preflightRejected'] = $true
            }
            elseif ($kind -eq 'Other' -and $_.Exception.Message -cmatch
                "^(?:\d{2}:\d{2}:\d{2} - )?The deployment '$([regex]::Escape($name))' failed with error\(s\)\. \(Code: DeploymentFailed\)(?:\s|$)") {
                $entry['status'] = 'Failed'
            }
            else { $entry['status'] = 'Unknown' }
            if ($kind -eq 'Cancellation') {
                Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                throw
            }
        }
        Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
        if ($entry['status'] -eq 'Unknown' -or $attempt -eq $RetryLimit) {
            $kind = if ($null -ne $failure) { Get-AvmBicepDeploymentErrorKind -ErrorRecord $failure } else { 'Other' }
            return [pscustomobject]@{
                Status = 'fail'; DeploymentName = $name; DeploymentId = $id; Outputs = @{}
                ErrorKind = $kind; Outcome = $entry['status']
            }
        }
        Write-AvmLog -Level Warning -Message (
            "Deployment '$name' ended with a confirmed $($entry['status']) outcome; retrying ($attempt/$RetryLimit).")
        Start-Sleep -Seconds 5
    }
}
