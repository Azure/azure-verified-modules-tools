function Test-AvmBicepRetryErrorRecord {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,

        [ValidateSet('Regional', 'Transient', 'MetadataTimeout')]
        [string] $Kind = 'Regional'
    )

    Set-StrictMode -Version 3.0
    $errorKind = Get-AvmBicepDeploymentErrorKind -ErrorRecord $ErrorRecord
    if (($Kind -eq 'MetadataTimeout' -and $errorKind -ne 'Timeout') -or
        ($Kind -ne 'MetadataTimeout' -and $errorKind -ne 'Other')) {
        return $false
    }
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $visited = [System.Collections.Generic.HashSet[object]]::new()
    $pending.Enqueue($ErrorRecord)
    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        if (-not $visited.Add($item)) { continue }
        if ($visited.Count -gt 100) { return $false }
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            if ($item.CategoryInfo.Category -in @('AuthenticationError', 'PermissionDenied', 'SecurityError') -or
                ($item -eq $ErrorRecord -and $Kind -ne 'MetadataTimeout' -and $item.CategoryInfo.Category -eq 'OperationStopped')) {
                return $false
            }
            $pending.Enqueue($item.Exception)
            continue
        }
        if ($item -is [System.UnauthorizedAccessException] -or
            $item -is [System.Security.Authentication.AuthenticationException] -or
            $item -is [System.Security.SecurityException] -or
            $item -is [System.Management.Automation.PipelineStoppedException]) {
            return $false
        }
        $containers = @($item)
        $responseProperty = $item.PSObject.Properties['Response']
        if ($null -ne $responseProperty) { $containers += , $responseProperty.Value }
        foreach ($container in $containers) {
            if ($null -eq $container) { continue }
            if ($container -is [array]) { return $false }
            if ($container -is [System.Collections.IDictionary]) { $status = $container['StatusCode'] }
            else {
                $property = $container.PSObject.Properties['StatusCode']
                if ($null -eq $property) { continue }
                $status = $property.Value
            }
            if ($null -eq $status) { continue }
            if ($Kind -eq 'MetadataTimeout') { return $false }
            if ($status -isnot [int] -and $status -isnot [System.Net.HttpStatusCode]) { return $false }
            if ([int]$status -in @(401, 403)) { return $false }
            $allowed = if ($Kind -eq 'Transient') { @(400, 409, 500, 503) } else { @(400, 409, 503) }
            if ($Kind -ne 'MetadataTimeout' -and [int]$status -notin $allowed) { return $false }
        }
        if ($item -is [System.AggregateException]) {
            foreach ($inner in $item.InnerExceptions) {
                if ($Kind -eq 'MetadataTimeout') {
                    $record = [System.Management.Automation.ErrorRecord]::new($inner, 'BicepReadFailure', 'NotSpecified', $null)
                    if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $record) -ne 'Timeout') { return $false }
                }
                $pending.Enqueue($inner)
            }
        }
        elseif ($null -ne $item.InnerException) { $pending.Enqueue($item.InnerException) }
        if ($item -is [System.Management.Automation.IContainsErrorRecord] -and $null -ne $item.ErrorRecord) {
            if ($Kind -eq 'MetadataTimeout' -and
                (Get-AvmBicepDeploymentErrorKind -ErrorRecord $item.ErrorRecord) -ne 'Timeout') { return $false }
            $pending.Enqueue($item.ErrorRecord)
        }
    }
    return $true
}
