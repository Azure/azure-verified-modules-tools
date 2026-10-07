function Remove-AvmBicepCleanupResourceBatch {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [string] $StatePath,

        [string[]] $BlockedResourceIds = @(),

        [ValidateRange(1, 100)]
        [int] $RetryLimit = 3,

        [ValidateRange(0, 3600)]
        [int] $RetryInterval = 15,

        [switch] $RequireCompleteRemoval
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $requireCompleteRemovalForBatch = [bool]$RequireCompleteRemoval
    $validated = ConvertTo-AvmBicepCleanupState -State $State
    $byId = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $orderInput = @(
        foreach ($resource in $validated['resources']) {
            $byId.Add($resource['id'], $resource)
            @{ resourceId = $resource['id']; type = $resource['type'] }
        }
    )
    $State['resources'] = $validated['resources']
    $ordered = @(Get-AvmBicepResourceRemovalOrder -ResourcesToOrder $orderInput)
    if (-not $PSCmdlet.ShouldProcess(
            "$($ordered.Count) recorded resource(s)", 'Remove Bicep test resources and complete post-removal work')) {
        return [pscustomobject]@{
            Cleaned = $false
            Status  = 'skipped'
            Pending = @($ordered | ForEach-Object { $_.resourceId })
            Issues  = @()
        }
    }
    $issues = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $blocked = [System.Collections.Generic.HashSet[string]]::new(
        $BlockedResourceIds, [System.StringComparer]::OrdinalIgnoreCase)
    for ($attempt = 1; $attempt -le $RetryLimit; $attempt++) {
        foreach ($item in $ordered) {
            $resource = $byId[$item.resourceId]
            if ($resource['metadataCaptured'] -or $blocked.Contains($resource['id'])) { continue }
            $subscription = if ($resource['id'] -match '^/subscriptions/([^/]+)/') {
                $resource['id'].Split('/')[2]
            }
            else { $State['subscriptionId'] }
            try {
                Invoke-AvmBicepAzureContext -SubscriptionId $subscription -TenantId $State['tenantId'] -ScriptBlock {
                    Initialize-AvmBicepCleanupResource -Resource $resource
                } -Confirm:$false
            }
            catch {
                if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                    $_.FullyQualifiedErrorId.Split(',')[0] -eq 'AvmBicepContextRestoreFailed') {
                    throw
                }
                $issues[$resource['id']] = [pscustomobject]@{
                    ResourceId = $resource['id']; Phase = 'metadata'; Message = $_.Exception.Message
                }
                Write-AvmLog -Message "Cleanup metadata is unavailable for '$($resource['id'])': $($_.Exception.Message)" -Level Warning
            }
            Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
        }

        foreach ($item in $ordered) {
            $resource = $byId[$item.resourceId]
            if (-not $resource['metadataCaptured'] -or $resource['postProcessed'] -or
                $blocked.Contains($resource['id'])) { continue }
            $unpreparedChildren = @($byId.Values | Where-Object {
                    (-not $_['metadataCaptured'] -or $blocked.Contains($_['id'])) -and $_['id'].StartsWith(
                        $resource['id'] + '/', [System.StringComparison]::OrdinalIgnoreCase)
                })
            if ($unpreparedChildren.Count -gt 0) {
                $issues[$resource['id']] = [pscustomobject]@{
                    ResourceId = $resource['id']; Phase = 'metadata'; Message = 'Child cleanup must be allowed and its metadata captured before removing its parent.'
                }
                continue
            }
            $subscription = if ($resource['id'] -match '^/subscriptions/([^/]+)/') {
                $resource['id'].Split('/')[2]
            }
            else { $State['subscriptionId'] }
            if (-not $resource['removed']) {
                $removedParent = @($byId.Values | Where-Object {
                        $_['removed'] -and $resource['id'].StartsWith(
                            $_['id'] + '/', [System.StringComparison]::OrdinalIgnoreCase)
                    }).Count -gt 0
                if ($removedParent) {
                    $resource['removed'] = $true
                }
                else {
                    try {
                        Invoke-AvmBicepAzureContext -SubscriptionId $subscription -TenantId $State['tenantId'] -ScriptBlock {
                            Assert-AvmBicepCleanupGroupOwnership -State $State -ResourceId $resource['id']
                            Remove-AvmBicepResource -ResourceId $resource['id'] -Type $resource['type'] -Confirm:$false
                        } -Confirm:$false
                        $resource['removed'] = $true
                    }
                    catch {
                        if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                            $_.FullyQualifiedErrorId.Split(',')[0] -eq 'AvmBicepContextRestoreFailed') {
                            throw
                        }
                        if ((Get-AvmBicepAzureErrorStatus -ErrorRecord $_) -eq 404) {
                            $resource['removed'] = $true
                        }
                        else {
                            $issues[$resource['id']] = [pscustomobject]@{
                                ResourceId = $resource['id']; Phase = 'remove'; Message = $_.Exception.Message
                            }
                            Write-AvmLog -Message "Removal failed for '$($resource['id'])': $($_.Exception.Message)" -Level Warning
                            if ($_.Exception -is [AvmConfigurationException]) { continue }
                        }
                    }
                }
                Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
            }
            try {
                Invoke-AvmBicepAzureContext -SubscriptionId $subscription -TenantId $State['tenantId'] -ScriptBlock {
                    Assert-AvmBicepCleanupGroupOwnership -State $State -ResourceId $resource['id']
                    Remove-AvmBicepResourceRemainder -ResourceId $resource['id'] -Type $resource['type'] `
                        -ManagedResourceGroupIds $resource['managedResourceGroupIds'] `
                        -OriginalSoftDeleteFeatureState $resource['originalSoftDeleteFeatureState'] `
                        -RequireCompleteRemoval:$requireCompleteRemovalForBatch -Confirm:$false
                } -Confirm:$false
                if ($resource['removed']) {
                    $resource['postProcessed'] = $true
                    $null = $issues.Remove($resource['id'])
                }
            }
            catch {
                if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation' -or
                    $_.FullyQualifiedErrorId.Split(',')[0] -eq 'AvmBicepContextRestoreFailed') {
                    throw
                }
                $issues[$resource['id']] = [pscustomobject]@{
                    ResourceId = $resource['id']; Phase = 'post'; Message = $_.Exception.Message
                }
                Write-AvmLog -Message "Post-removal failed for '$($resource['id'])': $($_.Exception.Message)" -Level Warning
            }
            Save-AvmBicepCleanupState -State $State -Path $StatePath -Confirm:$false
        }
        $pending = @($byId.Values | Where-Object {
                -not $_['postProcessed'] -or $blocked.Contains($_['id'])
            } |
                ForEach-Object { $_['id'] })
        if ($pending.Count -eq 0 -or $attempt -eq $RetryLimit) { break }
        Start-Sleep -Seconds $RetryInterval
    }
    return [pscustomobject]@{
        Cleaned = $pending.Count -eq 0
        Status  = if ($pending.Count -eq 0) { 'pass' } else { 'fail' }
        Pending = $pending
        Issues  = @($issues.Values)
    }
}
