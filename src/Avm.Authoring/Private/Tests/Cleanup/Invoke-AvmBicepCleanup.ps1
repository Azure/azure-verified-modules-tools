function Invoke-AvmBicepCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $StatePath,

        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [guid] $TenantId,

        [ValidateRange(1, 1000)]
        [int] $SearchRetryLimit = 40,

        [ValidateRange(0, 3600)]
        [int] $SearchRetryInterval = 60,

        [ValidateRange(1, 100)]
        [int] $RemovalRetryLimit = 3,

        [ValidateRange(0, 3600)]
        [int] $RemovalRetryInterval = 15
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $StatePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StatePath)
    $state = Read-AvmBicepCleanupState -Path $StatePath
    if ($state['subscriptionId'] -ine $SubscriptionId.ToString('D') -or
        $state['tenantId'] -ine $TenantId.ToString('D')) {
        throw [AvmConfigurationException]::new('Cleanup state does not match the explicitly selected subscription and tenant.')
    }
    if (-not $PSCmdlet.ShouldProcess(
            "recorded Bicep deployments in $SubscriptionId, tenant $TenantId", 'Resume deployment-owned cleanup')) {
        return [pscustomobject]@{ Cleaned = $false; Status = 'skipped'; Pending = @(); Issues = @(); StatePath = $StatePath }
    }
    Assert-AvmBicepAzureDependency
    $az = Get-Command -Name 'az' -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $discoveryOptions = @{
        SearchRetryLimit    = $SearchRetryLimit
        SearchRetryInterval = $SearchRetryInterval
    }
    $removalOptions = @{
        RetryLimit    = $RemovalRetryLimit
        RetryInterval = $RemovalRetryInterval
    }
    Invoke-AvmBicepAzureContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ScriptBlock {
        $context = Get-AzContext -ErrorAction Stop
        $environment = Get-AvmPropertyValue -InputObject $context -Name 'Environment'
        if ((Get-AvmPropertyValue -InputObject $environment -Name 'Name') -cne $state['environment']) {
            throw [AvmConfigurationException]::new('Cleanup state belongs to a different Azure cloud.')
        }
        Assert-AvmBicepAzureIdentity -AzPath $az.Source -SubscriptionId $SubscriptionId -TenantId $TenantId
        $state['status'] = 'CleanupPending'
        Save-AvmBicepCleanupState -State $state -Path $StatePath -Confirm:$false
        $readiness = Get-AvmBicepPendingDeployment -State $state `
            -RetryLimit $discoveryOptions.SearchRetryLimit -RetryInterval $discoveryOptions.SearchRetryInterval
        Save-AvmBicepCleanupState -State $state -Path $StatePath -Confirm:$false
        if ($readiness.Pending.Count -gt 0) {
            foreach ($issue in $readiness.Issues) { Write-AvmLog -Level Warning -Message $issue.Message }
            return [pscustomobject]@{
                Cleaned = $false; Status = 'fail'; Pending = $readiness.Pending
                Issues = $readiness.Issues; StatePath = $StatePath
            }
        }

        $issues = [System.Collections.Generic.List[object]]::new()
        $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $blockedGroups = [System.Collections.Generic.List[string]]::new()
        $discovery = Get-AvmBicepDeploymentCleanupTarget @discoveryOptions `
            -DeploymentIds @($state['deployments'] | ForEach-Object { $_['id'] }) `
            -PreflightRejectedDeploymentIds @($state['deployments'] |
                Where-Object { $_['preflightRejected'] } | ForEach-Object { $_['id'] })
        foreach ($issue in $discovery.Issues) { $issues.Add($issue) }
        foreach ($id in $discovery.ResourceIds) { $null = $ids.Add($id) }

        foreach ($owned in $state['ownedResourceGroups']) {
            $groupSubscription = $owned['id'].Split('/')[2]
            try {
                $group = Invoke-AvmBicepAzureContext -SubscriptionId $groupSubscription -TenantId $TenantId -ScriptBlock {
                    Invoke-AvmBicepCleanupLookup -Command 'Get-AzResourceGroup' -Parameters @{
                        Name = $owned['id'].Split('/')[-1]
                    }
                } -Confirm:$false
                if ($null -ne $group) {
                    $actualId = Get-AvmPropertyValue -InputObject $group -Name 'ResourceId'
                    $tags = Get-AvmPropertyValue -InputObject $group -Name 'Tags'
                    if ($actualId -ine $owned['id'] -or
                        (Get-AvmPropertyValue -InputObject $tags -Name 'avm-e2e-run-id') -cne $owned['runId']) {
                        throw [AvmProcessException]::new("Ownership could not be confirmed for '$($owned['id'])'.")
                    }
                }
                $null = $ids.Add($owned['id'])
            }
            catch {
                if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                    $_.FullyQualifiedErrorId.Split(',')[0] -eq 'AvmBicepContextRestoreFailed') {
                    throw
                }
                $blockedGroups.Add($owned['id'])
                $issues.Add([pscustomobject]@{
                        ResourceId = $owned['id']; Code = 'GroupOwnershipUnverified'; Message = $_.Exception.Message
                    })
                Write-AvmLog -Message $_.Exception.Message -Level Warning
            }
        }

        $records = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($resource in $state['resources']) { $records.Add($resource['id'], $resource) }
        foreach ($resource in ConvertTo-AvmBicepCleanupResource -ResourceIds @($ids)) {
            if (-not $records.ContainsKey($resource.resourceId)) {
                $records.Add($resource.resourceId, [ordered]@{
                        id                             = $resource.resourceId
                        type                           = $resource.type
                        removed                        = $false
                        postProcessed                  = $false
                        metadataCaptured               = $false
                        managedResourceGroupIds        = @()
                        originalSoftDeleteFeatureState = ''
                    })
            }
        }
        $excluded = @($records.Keys | Where-Object {
                Test-AvmBicepCleanupExclusion -ResourceId $_ -SubscriptionId $state['subscriptionId']
            })
        foreach ($id in $excluded) {
            Write-AvmLog -Message "Retaining workflow-excluded resource '$id'." -Level Info
            $null = $records.Remove($id)
        }
        $state['resources'] = @($records.Values)
        $blocked = [System.Collections.Generic.List[string]]::new()
        foreach ($resource in $state['resources']) {
            foreach ($groupId in $blockedGroups) {
                if ($resource['id'] -ieq $groupId -or $resource['id'].StartsWith(
                        $groupId + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $blocked.Add($resource['id'])
                    break
                }
            }
        }
        Save-AvmBicepCleanupState -State $state -Path $StatePath -Confirm:$false
        $batch = Remove-AvmBicepCleanupResourceBatch -State $state -StatePath $StatePath `
            -BlockedResourceIds $blocked.ToArray() @removalOptions -Confirm:$false
        foreach ($issue in $batch.Issues) { $issues.Add($issue) }
        $cleaned = $batch.Cleaned -and $issues.Count -eq 0
        $state['status'] = if ($cleaned) { 'Complete' } else { 'CleanupPending' }
        Save-AvmBicepCleanupState -State $state -Path $StatePath -Confirm:$false
        [pscustomobject]@{
            Cleaned   = $cleaned
            Status    = if ($cleaned) { 'pass' } else { 'fail' }
            Pending   = @(
                @($batch.Pending) + @($blockedGroups) +
                @($discovery.Issues | ForEach-Object { $_.DeploymentId }) |
                    Select-Object -Unique
            )
            Issues    = $issues.ToArray()
            StatePath = $StatePath
        }
    } -Confirm:$false
}
