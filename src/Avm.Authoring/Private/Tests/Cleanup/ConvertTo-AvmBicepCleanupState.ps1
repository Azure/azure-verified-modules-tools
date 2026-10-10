function ConvertTo-AvmBicepCleanupState {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (($State['schemaVersion'] -isnot [int] -and $State['schemaVersion'] -isnot [long]) -or
        $State['schemaVersion'] -ne 1) {
        throw [AvmConfigurationException]::new('Unsupported Bicep cleanup state version.')
    }
    foreach ($name in @('runId', 'tenantId', 'subscriptionId', 'environment', 'status')) {
        if ($State[$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($State[$name])) {
            throw [AvmConfigurationException]::new("Cleanup state requires a string '$name'.")
        }
    }
    if (-not (Test-AvmBicepRunId -RunId $State['runId']) -or
        $State['status'] -cnotin @('Pending', 'CleanupPending', 'Complete')) {
        throw [AvmConfigurationException]::new('Cleanup state has an invalid run ID or status.')
    }
    foreach ($name in @('tenantId', 'subscriptionId')) {
        $id = [guid]::Empty
        if (-not [guid]::TryParseExact($State[$name], 'D', [ref]$id) -or $id -eq [guid]::Empty) {
            throw [AvmConfigurationException]::new("Cleanup state has an invalid '$name'.")
        }
    }
    foreach ($name in @('deployments', 'ownedResourceGroups', 'resources')) {
        if ($State[$name] -isnot [System.Collections.IList]) {
            throw [AvmConfigurationException]::new("Cleanup state requires an array '$name'.")
        }
    }

    $deployments = [System.Collections.Generic.List[object]]::new()
    $deletionRecords = 0
    $pendingDeletions = 0
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $State['deployments']) {
        if ($entry -isnot [System.Collections.IDictionary] -or
            $entry['id'] -isnot [string] -or $entry['preflightRejected'] -isnot [bool] -or
            $entry['status'] -isnot [string] -or
            $entry['status'] -cnotin @('Attempted', 'Succeeded', 'Failed', 'Unknown', 'Rejected')) {
            throw [AvmConfigurationException]::new('Invalid cleanup deployment record.')
        }
        $resource = ConvertTo-AvmBicepCleanupResource -ResourceIds @($entry['id'])
        if ($resource.type -ine 'Microsoft.Resources/deployments' -or -not $seen.Add($entry['id'])) {
            throw [AvmConfigurationException]::new('Cleanup deployment IDs must be distinct deployment resources.')
        }
        $deployment = [ordered]@{
            id                = $entry['id']
            status            = $entry['status']
            preflightRejected = $entry['preflightRejected']
        }
        if ($entry.Contains('recordDeletion')) {
            if ($entry['recordDeletion'] -isnot [string] -or
                $entry['recordDeletion'] -cnotin @('Pending', 'Complete') -or
                $entry['status'] -cnotin @('Failed', 'Rejected')) {
                throw [AvmConfigurationException]::new('Invalid deployment record deletion progress.')
            }
            $deployment['recordDeletion'] = $entry['recordDeletion']
            $deletionRecords++
            if ($entry['recordDeletion'] -ceq 'Pending') { $pendingDeletions++ }
        }
        $deployments.Add($deployment)
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    $seen.Clear()
    foreach ($entry in $State['ownedResourceGroups']) {
        if ($entry -isnot [System.Collections.IDictionary] -or $entry['id'] -isnot [string] -or
            -not (Test-AvmBicepRunId -RunId $entry['runId'])) {
            throw [AvmConfigurationException]::new('Invalid owned resource-group cleanup record.')
        }
        $resource = ConvertTo-AvmBicepCleanupResource -ResourceIds @($entry['id'])
        if ($resource.type -ine 'Microsoft.Resources/resourceGroups' -or -not $seen.Add($entry['id'])) {
            throw [AvmConfigurationException]::new('Owned cleanup group IDs must be distinct resource groups.')
        }
        $groups.Add([ordered]@{ id = $entry['id']; runId = $entry['runId'] })
    }

    $resources = [System.Collections.Generic.List[object]]::new()
    $seen.Clear()
    foreach ($entry in $State['resources']) {
        if ($entry -isnot [System.Collections.IDictionary] -or
            $entry['id'] -isnot [string] -or $entry['removed'] -isnot [bool] -or
            $entry['postProcessed'] -isnot [bool] -or $entry['metadataCaptured'] -isnot [bool] -or
            $entry['managedResourceGroupIds'] -isnot [System.Collections.IList] -or
            $entry['originalSoftDeleteFeatureState'] -isnot [string] -or
            $entry['originalSoftDeleteFeatureState'] -cnotin @('', 'Enabled', 'Disabled', 'AlwaysON')) {
            throw [AvmConfigurationException]::new('Invalid cleanup resource record.')
        }
        $resource = ConvertTo-AvmBicepCleanupResource -ResourceIds @($entry['id'])
        if ($resource.type -ieq 'Microsoft.Resources/deployments' -or -not $seen.Add($entry['id'])) {
            throw [AvmConfigurationException]::new('Cleanup resource IDs must be distinct non-deployment resources.')
        }
        if (($entry['postProcessed'] -and -not $entry['removed']) -or
            (($entry['removed'] -or $entry['postProcessed']) -and -not $entry['metadataCaptured'])) {
            throw [AvmConfigurationException]::new('Cleanup resource status is inconsistent.')
        }
        $managedIds = [System.Collections.Generic.List[string]]::new()
        foreach ($managedId in $entry['managedResourceGroupIds']) {
            if ($managedId -isnot [string] -or
                (ConvertTo-AvmBicepCleanupResource -ResourceIds @($managedId)).type -ine 'Microsoft.Resources/resourceGroups' -or
                $resource.type -ine 'Microsoft.Databricks/workspaces' -or
                $managedId.Split('/')[2] -ine $entry['id'].Split('/')[2]) {
                throw [AvmConfigurationException]::new('Invalid Databricks managed group in cleanup state.')
            }
            $managedIds.Add($managedId)
        }
        if (-not [string]::IsNullOrEmpty($entry['originalSoftDeleteFeatureState']) -and
            $resource.type -ine 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems') {
            throw [AvmConfigurationException]::new('Unexpected recovery-vault setting in cleanup state.')
        }
        $resources.Add([ordered]@{
                id                             = $entry['id']
                type                           = $resource.type
                removed                        = $entry['removed']
                postProcessed                  = $entry['postProcessed']
                metadataCaptured               = $entry['metadataCaptured']
                managedResourceGroupIds        = $managedIds.ToArray()
                originalSoftDeleteFeatureState = $entry['originalSoftDeleteFeatureState']
            })
    }
    if ($State['status'] -ceq 'Complete' -and
        @($resources | Where-Object { -not $_['postProcessed'] }).Count -gt 0) {
        throw [AvmConfigurationException]::new('Complete cleanup state cannot contain unfinished resources.')
    }
    if (($deletionRecords -gt 0 -and @($resources | Where-Object { -not $_['postProcessed'] }).Count -gt 0) -or
        ($State['status'] -ceq 'Complete' -and $pendingDeletions -gt 0)) {
        throw [AvmConfigurationException]::new('Deployment deletion progress requires removed resources and confirmed completion.')
    }
    $document = [ordered]@{
        schemaVersion       = 1
        runId               = $State['runId']
        tenantId            = $State['tenantId']
        subscriptionId      = $State['subscriptionId']
        environment         = $State['environment']
        status              = $State['status']
        deployments         = $deployments.ToArray()
        ownedResourceGroups = $groups.ToArray()
        resources           = $resources.ToArray()
    }
    if ($State.Contains('attempts') -and -not $State.Contains('case')) {
        throw [AvmConfigurationException]::new('A Bicep attempt journal requires its case metadata.')
    }
    if ($State.Contains('case')) {
        if ($State['case'] -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new('Cleanup case metadata must be an object.')
        }
        $document['case'] = ConvertTo-AvmBicepCleanupCase -Case $State['case']
        $case = $document['case']
        if ($State.Contains('attempts')) {
            $document['attempts'] = @(ConvertTo-AvmBicepAttemptJournal -State $State)
        }
        else {
            foreach ($entry in $deployments) {
                $expectedId = Get-AvmBicepScopedDeploymentId -Scope $case['scope'] `
                    -SubscriptionId $State['subscriptionId'] -ResourceGroupName $case['resourceGroupName'] `
                    -ManagementGroupId $case['managementGroupId'] -DeploymentName $entry['id'].Split('/')[-1]
                if ($entry['id'] -ine $expectedId -or
                    $entry['id'].Split('/')[-1] -cnotmatch ('^avm-e2e-' + $State['runId'] + '-t[1-3]$')) {
                    throw [AvmConfigurationException]::new('Cleanup deployment does not belong to its recorded case.')
                }
            }
        }
    }
    return $document
}
