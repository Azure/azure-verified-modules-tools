function Get-AvmBicepDeploymentCleanupTarget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [string[]] $DeploymentIds = @(),

        [string[]] $PreflightRejectedDeploymentIds = @(),

        [ValidateRange(1, 1000)]
        [int] $SearchRetryLimit = 40,

        [ValidateRange(0, 3600)]
        [int] $SearchRetryInterval = 60
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $records = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($deployment in ConvertTo-AvmBicepCleanupResource -ResourceIds $DeploymentIds) {
        if ($deployment.type -ine 'Microsoft.Resources/deployments') {
            throw [AvmConfigurationException]::new("Not a deployment ID: $($deployment.resourceId)")
        }
        $records[$deployment.resourceId] = @{
            Id                = $deployment.resourceId
            Required          = $true
            PreflightRejected = $false
            Status            = 'Pending'
            ErrorCode         = ''
            ErrorMessage      = ''
        }
    }
    foreach ($rejectedId in $PreflightRejectedDeploymentIds) {
        if (-not $records.ContainsKey($rejectedId)) {
            throw [AvmConfigurationException]::new(
                'Preflight rejection metadata contains IDs outside the attempted deployments.')
        }
        $records[$rejectedId].PreflightRejected = $true
    }
    $resources = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    for ($round = 1; $round -le $SearchRetryLimit; $round++) {
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($record in $records.Values) {
            if ($record.Status -eq 'Pending') {
                $queue.Enqueue($record.Id)
            }
        }
        while ($queue.Count -gt 0) {
            $record = $records[$queue.Dequeue()]
            $nextPath = $record.Id + '/operations?api-version=2021-04-01'
            $visitedPages = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal)
            try {
                while (-not [string]::IsNullOrEmpty($nextPath)) {
                    if (-not $visitedPages.Add($nextPath)) {
                        throw [AvmProcessException]::new("Repeated deployment operations page: $nextPath")
                    }
                    $response = Invoke-AzRestMethod -Method GET -Path $nextPath -ErrorAction Stop
                    $document = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    if ([int]$response.StatusCode -ne 200) {
                        $errorBody = Get-AvmPropertyValue -InputObject $document -Name 'error'
                        $errorCode = [string](Get-AvmPropertyValue -InputObject $errorBody -Name 'code')
                        $groupScope = $record.Id -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Resources/deployments/[^/]+$'
                        if ([int]$response.StatusCode -eq 404 -and $groupScope -and $errorCode -ceq 'ResourceGroupNotFound') {
                            $record.Status = 'ContainerRemoved'
                            break
                        }
                        if ([int]$response.StatusCode -eq 404 -and $errorCode -ceq 'DeploymentNotFound') {
                            if ($visitedPages.Count -gt 1) {
                                throw [AvmProcessException]::new(
                                    "Deployment record disappeared during pagination: $($record.Id)")
                            }
                            if ($record.PreflightRejected) {
                                $record.Status = 'RejectedWithoutRecord'
                            }
                            elseif (-not $record.Required) {
                                $record.Status = 'NestedRecordAbsent'
                                Write-AvmLog -Message "Nested deployment record is absent: $($record.Id)" -Level Warning
                            }
                            $record.ErrorCode = 'DeploymentNotFound'
                            break
                        }
                        throw [AvmProcessException]::new(
                            "Deployment operations lookup failed: HTTP $($response.StatusCode), code '$errorCode', deployment '$($record.Id)'.")
                    }
                    if ($document -isnot [System.Collections.IDictionary] -or
                        -not $document.Contains('value') -or $document['value'] -isnot [array]) {
                        throw [AvmProcessException]::new("Invalid deployment operations response: $($record.Id)")
                    }
                    foreach ($operation in $document['value']) {
                        $properties = Get-AvmPropertyValue -InputObject $operation -Name 'properties'
                        if ($properties -isnot [System.Collections.IDictionary]) {
                            throw [AvmProcessException]::new("Invalid deployment operation properties: $($record.Id)")
                        }
                        if ((Get-AvmPropertyValue -InputObject $properties -Name 'provisioningOperation') -ine 'Create') {
                            continue
                        }
                        $target = Get-AvmPropertyValue -InputObject $properties -Name 'targetResource'
                        if ($null -eq $target) {
                            continue
                        }
                        $targetId = Get-AvmPropertyValue -InputObject $target -Name 'id'
                        if ($targetId -isnot [string] -or [string]::IsNullOrWhiteSpace($targetId)) {
                            throw [AvmProcessException]::new("Deployment operation has an invalid target ID: $($record.Id)")
                        }
                        $resource = ConvertTo-AvmBicepCleanupResource -ResourceIds @($targetId)
                        if ($resource.type -ieq 'Microsoft.Resources/deployments') {
                            if (-not $records.ContainsKey($targetId)) {
                                $records.Add($targetId, @{
                                        Id                = $targetId
                                        Required          = $false
                                        PreflightRejected = $false
                                        Status            = 'Pending'
                                        ErrorCode         = ''
                                        ErrorMessage      = ''
                                    })
                                $queue.Enqueue($targetId)
                            }
                        }
                        else {
                            $null = $resources.Add($targetId)
                        }
                    }
                    $nextPath = Resolve-AvmBicepCleanupNextLink -NextLink (
                        Get-AvmPropertyValue -InputObject $document -Name 'nextLink')
                    if ([string]::IsNullOrEmpty($nextPath)) {
                        $record.Status = 'Resolved'
                        $record.ErrorCode = ''
                    }
                }
            }
            catch {
                if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') {
                    throw
                }
                $record.Status = 'Failed'
                $record.ErrorCode = 'LookupFailed'
                $record.ErrorMessage = $_.Exception.Message
                Write-AvmLog -Message (
                    "Deployment lookup failed for '$($record.Id)'; known targets will still be cleaned. $($_.Exception.Message)"
                ) -Level Warning
            }
        }
        $pending = @($records.Values | Where-Object { $_.Status -eq 'Pending' })
        if ($pending.Count -eq 0 -or $round -eq $SearchRetryLimit) {
            break
        }
        Write-AvmLog -Message (
            "Waiting for $($pending.Count) deployment record(s); lookup round $round/$SearchRetryLimit."
        ) -Level Info
        Start-Sleep -Seconds $SearchRetryInterval
    }

    $issues = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $records.Values) {
        if ($record.Status -eq 'Pending') {
            $record.Status = 'Missing'
            $record.ErrorMessage = "Deployment record not found after $SearchRetryLimit lookups: $($record.Id)"
        }
        if ($record.Status -in @('Missing', 'Failed')) {
            $issues.Add([pscustomobject]@{
                    DeploymentId = $record.Id
                    Code         = $record.ErrorCode
                    Message      = $record.ErrorMessage
                })
        }
    }
    [pscustomobject]@{
        ResourceIds = [string[]]@($resources)
        Deployments = @($records.Values)
        Issues      = $issues.ToArray()
    }
}
