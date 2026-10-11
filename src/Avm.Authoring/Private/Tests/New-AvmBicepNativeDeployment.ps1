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
        [int] $RetryLimit = 3,

        # Continues the shared attempt budget, and deployment names, after a relocation.
        [ValidateRange(1, 3)]
        [int] $FirstAttempt = 1,

        # Return 'relocate' instead of retrying in place when a confirmed failure is wholly regional.
        [switch] $AllowRelocation
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    for ($attempt = $FirstAttempt; $attempt -le $RetryLimit; $attempt++) {
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
        $failure = $null
        $outputs = $null
        try {
            $response = Invoke-AvmBicepNativeArmOperation @inputOptions -Operation Create -Confirm:$false
            $responseId = Get-AvmPropertyValue -InputObject $response -Name 'Id'
            if ($responseId -isnot [string] -or $responseId -ine $id) {
                throw [AvmProcessException]::new('The native deployment response did not identify the recorded deployment.')
            }
            $provisioningState = Get-AvmPropertyValue -InputObject $response -Name 'ProvisioningState'
            $entry['status'] = if ($provisioningState -in @('Succeeded', 'Failed')) { $provisioningState } else { 'Unknown' }
            $outputs = Get-AvmPropertyValue -InputObject $response -Name 'Outputs'
        }
        catch {
            $failure = $_
            $kind = Get-AvmBicepDeploymentErrorKind -ErrorRecord $_
            $failedPattern = "^(?:\d{2}:\d{2}:\d{2} - )?The deployment '$([regex]::Escape($name))' failed with error\(s\)\. " +
            '(?:Showing \d+ out of \d+ error\(s\)\. Status Message: (?:(?!\(Code:)[^\r\n])* )?\(Code: DeploymentFailed\)(?:\s|$)'
            if (Test-AvmBicepDeploymentPreflightRejection -ErrorRecord $_ -DeploymentName $name) {
                $entry['status'] = 'Rejected'
                $entry['preflightRejected'] = $true
            }
            elseif ($kind -eq 'Other' -and $_.Exception.Message -cmatch $failedPattern) {
                $entry['status'] = 'Failed'
            }
            else { $entry['status'] = 'Unknown' }
            if ($kind -eq 'Cancellation') {
                Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                throw
            }
            if ($kind -eq 'Timeout' -and $entry['status'] -eq 'Unknown') {
                # The request may still have been accepted, so watch the same deployment instead of submitting another.
                Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                Write-AvmLog -Level Warning -Message "Request for deployment '$name' timed out; watching it without resubmitting."
                try {
                    $recovered = Wait-AvmBicepNativeDeployment -DeploymentId $id
                    $entry['status'] = $recovered.State
                    $outputs = $recovered.Outputs
                }
                catch {
                    if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') {
                        Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                        throw
                    }
                    Write-AvmLog -Level Warning -Message "Status recovery for deployment '$name' failed; its outcome remains unknown."
                }
            }
        }
        Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
        if ($entry['status'] -eq 'Succeeded') {
            if ($null -eq $outputs) { $outputs = @{} }
            return [pscustomobject]@{ Status = 'pass'; DeploymentName = $name; DeploymentId = $id; Outputs = $outputs }
        }
        if ($entry['status'] -eq 'Unknown' -or $attempt -eq $RetryLimit) {
            $kind = if ($null -eq $failure -or $entry['status'] -eq 'Failed') { 'Other' }
            else { Get-AvmBicepDeploymentErrorKind -ErrorRecord $failure }
            return [pscustomobject]@{
                Status = 'fail'; DeploymentName = $name; DeploymentId = $id; Outputs = @{}
                ErrorKind = $kind; Outcome = $entry['status']
            }
        }
        if ($AllowRelocation -and $entry['status'] -eq 'Failed') {
            $regional = $false
            try { $regional = Test-AvmBicepRegionalDeploymentFailure -DeploymentId $id }
            catch {
                if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') { throw }
                Write-AvmLog -Level Warning -Message "Regional classification for '$name' failed; retrying in place."
            }
            if ($regional) {
                return [pscustomobject]@{
                    Status = 'relocate'; DeploymentName = $name; DeploymentId = $id; Outputs = @{}
                    ErrorKind = 'Other'; Outcome = 'Failed'; Attempt = $attempt
                }
            }
        }
        Write-AvmLog -Level Warning -Message (
            "Deployment '$name' ended with a confirmed $($entry['status']) outcome; retrying ($attempt/$RetryLimit).")
        Start-Sleep -Seconds 5
    }
}
