function New-AvmBicepNativeDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $State,
        [Parameter(Mandatory)] [string] $StatePath,
        [Parameter(Mandatory)] [hashtable] $DeploymentInput,
        [ValidateRange(1, 3)] [int] $Attempt = 1,
        [ValidateSet('Initial', 'InPlace', 'Fresh')] [string] $Mode = 'Initial',
        [string] $NamingId,
        [string] $ResourceLocation,
        [switch] $ClassifyRetry
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $name = $DeploymentInput['DeploymentName']
    if (-not $name) { $name = 'avm-e2e-{0}-t{1}' -f $State['runId'], $Attempt }
    $id = Get-AvmBicepScopedDeploymentId -Scope $DeploymentInput.Scope -SubscriptionId $State['subscriptionId'] `
        -DeploymentName $name -ResourceGroupName $DeploymentInput['ResourceGroupName'] `
        -ManagementGroupId $DeploymentInput['ManagementGroupId']
    if (-not $PSCmdlet.ShouldProcess($id, 'Record and submit Bicep test deployment')) {
        return [pscustomobject]@{ Status = 'skipped'; DeploymentName = $name; DeploymentId = $id; Outputs = @{} }
    }
    $inputOptions = $DeploymentInput.Clone()
    $inputOptions.DeploymentName = $name
    $observationOptions = @{}
    if ($DeploymentInput.Scope -in @('mg', 'sub')) {
        $submissionProfile = Get-AzContext -ErrorAction Stop
        $tenant = Get-AvmPropertyValue -InputObject $submissionProfile -Name 'Tenant'
        $tenantId = Get-AvmPropertyValue -InputObject $tenant -Name 'Id' -NoEnumerate
        if ($tenantId -isnot [string] -or [string]::IsNullOrWhiteSpace($tenantId)) {
            throw [AvmConfigurationException]::new('Submission requires an authenticated Azure tenant context.')
        }
        $inputOptions.DefaultProfile = $submissionProfile
        $observationOptions.DefaultProfile = $submissionProfile
    }
    $entries = @($State['deployments'] | Where-Object { $_['id'] -ieq $id })
    if ($Mode -eq 'InPlace') {
        if ($entries.Count -ne 1 -or $entries[0]['status'] -cne 'Failed') {
            throw [AvmConfigurationException]::new('An in-place retry requires the exact previously failed deployment.')
        }
        $entry = $entries[0]
        $entry['status'] = 'Attempted'
        $entry['preflightRejected'] = $false
    }
    else {
        if ($entries.Count -ne 0) { throw [AvmConfigurationException]::new('A fresh deployment identity was already recorded.') }
        $entry = @{ id = $id; status = 'Attempted'; preflightRejected = $false }
        $State['deployments'] = @($State['deployments']) + @($entry)
    }
    if ($State.Contains('attempts')) {
        $State['case']['resourceGroupName'] = [string]$DeploymentInput['ResourceGroupName']
        $State['attempts'] = @($State['attempts']) + @([ordered]@{
                number = $Attempt; mode = $Mode; namingId = $NamingId; deploymentId = $id
                resourceGroupName = [string]$DeploymentInput['ResourceGroupName']; resourceLocation = $ResourceLocation
            })
    }
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
        if ($null -eq $response -or $response -is [System.Collections.IList] -or
            (Get-AvmPropertyValue -InputObject $response -Name 'Id' -NoEnumerate) -isnot [string] -or
            (Get-AvmPropertyValue -InputObject $response -Name 'Id' -NoEnumerate) -ine $id -or
            $null -ne (Get-AvmPropertyValue -InputObject $response -Name 'Error' -NoEnumerate)) {
            throw [AvmProcessException]::new('The native deployment response did not identify the recorded deployment.')
        }
        $provisioningState = Get-AvmPropertyValue -InputObject $response -Name 'ProvisioningState' -NoEnumerate
        $entry['status'] = if ($provisioningState -is [string] -and $provisioningState -cin @('Succeeded', 'Failed')) {
            $provisioningState
        }
        else { 'Unknown' }
        $outputs = Get-AvmPropertyValue -InputObject $response -Name 'Outputs' -NoEnumerate
        if ($null -ne $outputs -and $outputs -isnot [System.Collections.IDictionary]) {
            throw [AvmProcessException]::new('The native deployment returned invalid outputs.')
        }
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
        elseif (-not $submissionReturned -and $kind -eq 'Other' -and $_.Exception.Message -cmatch $failedPattern) {
            $entry['status'] = 'Failed'
        }
        else { $entry['status'] = 'Unknown' }
        $failureQueryAllowed = -not $submissionReturned -and $kind -eq 'Other' -and -not $entry['preflightRejected']
        if ($kind -eq 'Cancellation') {
            Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
            throw
        }
        $canObserve = Test-AvmBicepRetryErrorRecord -ErrorRecord $_ -Kind MetadataTimeout
        if (-not $submissionReturned -and $DeploymentInput.Scope -eq 'mg' -and $kind -eq 'Forbidden') { $canObserve = $true }
        if (-not $submissionReturned -and $DeploymentInput.Scope -eq 'sub' -and $kind -eq 'Other') {
            $canObserve = Test-AvmBicepNestedDeploymentReadFailure -ErrorRecord $_ -DeploymentId $id -DefaultProfile $submissionProfile
        }
        if ($canObserve -and $entry['status'] -eq 'Unknown') {
            Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
            Write-AvmLog -Level Warning -Message "Request for deployment '$name' returned $kind; watching it without resubmitting."
            try {
                $recovered = Wait-AvmBicepNativeDeployment -DeploymentId $id @observationOptions
                $entry['status'] = $recovered.State
                $failureQueryAllowed = $false
                if ($kind -eq 'Forbidden' -and $recovered.State -ne 'Succeeded') {
                    throw [AvmProcessException]::new("The original management-group deployment '$id' failed after HTTP 403.")
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
                Write-AvmLog -Level Warning -Message "Status recovery for '$name' did not confirm success; outcome '$($entry['status'])'."
            }
        }
    }
    $retryMode = ''
    if ($ClassifyRetry -and $kind -ne 'Forbidden' -and $null -eq $recoveryFailure -and
        ($entry['status'] -eq 'Failed' -or $failureQueryAllowed)) {
        $classificationFailure = $failure
        if ($recoveredFailure) { $classificationFailure = $null }
        elseif ($null -ne $failure -and $failure.CategoryInfo.Category -eq 'OperationStopped') {
            $classificationFailure = [System.Management.Automation.ErrorRecord]::new(
                $failure.Exception, 'AvmBicepConfirmedDeploymentFailure',
                [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
        }
        try {
            $retryKind = Get-AvmBicepDeploymentRetryKind -DeploymentId $id -SubscriptionId $State['subscriptionId'] `
                -ResourceLocation $ResourceLocation -Failure $classificationFailure
            $retryMode = switch ($retryKind) { 'Regional' { 'Fresh' } 'Transient' { 'InPlace' } default { '' } }
            if ($retryMode) { $entry['status'] = 'Failed' }
        }
        catch {
            if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') {
                Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
                throw
            }
            $recoveryFailure = $_
            Write-AvmLog -Level Warning -Message "Failure evidence for '$name' could not be confirmed; no retry is permitted."
        }
    }
    Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
    if ($null -eq $outputs) { $outputs = @{} }
    return [pscustomobject]@{
        Status = if ($entry['status'] -eq 'Succeeded') { 'pass' } else { 'fail' }
        DeploymentName = $name; DeploymentId = $id; Outputs = $outputs; Attempt = $Attempt
        RetryMode = $retryMode; ErrorKind = $kind; Outcome = $entry['status']
        ErrorRecord = $failure; RecoveryErrorRecord = $recoveryFailure
    }
}
