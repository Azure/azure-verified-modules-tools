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

        [switch] $AllowRelocation,

        [switch] $AllowTransientRetry,

        [string] $ResourceLocation
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
        $inputOptions = $DeploymentInput.Clone()
        $inputOptions.DeploymentName = $name
        $observationOptions = @{}
        if ($DeploymentInput.Scope -eq 'mg') {
            $submissionProfile = Get-AzContext -ErrorAction Stop
            $tenant = Get-AvmPropertyValue -InputObject $submissionProfile -Name 'Tenant'
            $tenantId = Get-AvmPropertyValue -InputObject $tenant -Name 'Id'
            if ($tenantId -isnot [string] -or [string]::IsNullOrWhiteSpace($tenantId)) {
                throw [AvmConfigurationException]::new('Management-group submission requires an authenticated Azure tenant context.')
            }
            $inputOptions.DefaultProfile = $submissionProfile
            $observationOptions.DefaultProfile = $submissionProfile
        }
        $entry = @{ id = $id; status = 'Attempted'; preflightRejected = $false }
        $State['deployments'] = @($State['deployments']) + @($entry)
        Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
        $failure = $null
        $recoveryFailure = $null
        $kind = 'Other'
        $outputs = $null
        $submissionReturned = $false
        $failureQueryAllowed = $false
        $recoveredFailure = $false
        try {
            $response = Invoke-AvmBicepNativeArmOperation @inputOptions -Operation Create -Confirm:$false
            $submissionReturned = $true
            $responseId = $null
            $provisioningState = $null
            if ($response -is [System.Collections.IDictionary]) {
                $responseId = $response['Id']
                $provisioningState = $response['ProvisioningState']
            }
            elseif ($null -ne $response -and $response -isnot [System.Collections.IList]) {
                $idProperty = $response.PSObject.Properties['Id']
                $stateProperty = $response.PSObject.Properties['ProvisioningState']
                if ($null -ne $idProperty) { $responseId = $idProperty.Value }
                if ($null -ne $stateProperty) { $provisioningState = $stateProperty.Value }
            }
            if ($responseId -isnot [string] -or $responseId -ine $id) {
                throw [AvmProcessException]::new('The native deployment response did not identify the recorded deployment.')
            }
            $entry['status'] = if ($provisioningState -is [string] -and $provisioningState -cin @('Succeeded', 'Failed')) {
                $provisioningState
            }
            else { 'Unknown' }
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
            $failureQueryAllowed = -not $submissionReturned -and $kind -eq 'Other' -and
            -not $entry['preflightRejected']
            if ($kind -eq 'Cancellation') {
                Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                throw
            }
            $canObserve = $kind -eq 'Timeout' -or
            ($kind -eq 'Forbidden' -and $DeploymentInput.Scope -eq 'mg' -and -not $submissionReturned)
            if ($canObserve -and $entry['status'] -eq 'Unknown') {
                # The request may still have been accepted, so watch the same deployment instead of submitting another.
                Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                Write-AvmLog -Level Warning -Message "Request for deployment '$name' returned $kind; watching it without resubmitting."
                try {
                    $recovered = Wait-AvmBicepNativeDeployment -DeploymentId $id @observationOptions
                    $entry['status'] = $recovered.State
                    if ($kind -eq 'Forbidden' -and $recovered.State -ne 'Succeeded') {
                        throw [AvmProcessException]::new(
                            "The original management-group deployment '$id' has a confirmed Failed outcome after HTTP 403.")
                    }
                    $outputs = $recovered.Outputs
                    $recoveredFailure = $recovered.State -eq 'Failed'
                }
                catch {
                    $recoveryFailure = $_
                    if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') {
                        Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                        throw
                    }
                    Write-AvmLog -Level Warning -Message (
                        "Status recovery for deployment '$name' did not confirm success; its recorded outcome is '$($entry['status'])'.")
                }
            }
        }
        Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
        if ($entry['status'] -eq 'Succeeded') {
            if ($null -eq $outputs) { $outputs = @{} }
            return [pscustomobject]@{ Status = 'pass'; DeploymentName = $name; DeploymentId = $id; Outputs = $outputs }
        }
        if ($kind -ne 'Forbidden' -and ($AllowRelocation -or $AllowTransientRetry) -and $attempt -lt $RetryLimit -and
            ($entry['status'] -eq 'Failed' -or $failureQueryAllowed)) {
            $classificationFailure = $failure
            if ($recoveredFailure) { $classificationFailure = $null }
            elseif ($null -ne $failure -and $failure.CategoryInfo.Category -eq 'OperationStopped') {
                $classificationFailure = [System.Management.Automation.ErrorRecord]::new(
                    $failure.Exception, 'AvmBicepConfirmedDeploymentFailure',
                    [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            }
            $retryKind = Get-AvmBicepDeploymentRetryKind -DeploymentId $id -SubscriptionId $State['subscriptionId'] `
                -ResourceLocation $ResourceLocation -Failure $classificationFailure
            if (($AllowRelocation -and $retryKind -eq 'Regional') -or
                ($AllowTransientRetry -and $retryKind -eq 'Transient')) {
                $entry['status'] = 'Failed'
                Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                return [pscustomobject]@{
                    Status = if ($retryKind -eq 'Regional') { 'relocate' } else { 'retry-clean' }
                    DeploymentName = $name; DeploymentId = $id; Outputs = @{}
                    ErrorKind = 'Other'; Outcome = 'Failed'; Attempt = $attempt
                }
            }
        }
        if ($kind -eq 'Forbidden' -or $entry['status'] -eq 'Unknown' -or $attempt -eq $RetryLimit) {
            $kind = if ($null -eq $failure -or ($entry['status'] -eq 'Failed' -and $kind -ne 'Forbidden')) { 'Other' }
            else { Get-AvmBicepDeploymentErrorKind -ErrorRecord $failure }
            return [pscustomobject]@{
                Status = 'fail'; DeploymentName = $name; DeploymentId = $id; Outputs = @{}
                ErrorKind = $kind; Outcome = $entry['status']
                ErrorRecord = $failure; RecoveryErrorRecord = $recoveryFailure
            }
        }
        Write-AvmLog -Level Warning -Message (
            "Deployment '$name' ended with a confirmed $($entry['status']) outcome; retrying ($attempt/$RetryLimit).")
        Start-Sleep -Seconds 5
    }
}
