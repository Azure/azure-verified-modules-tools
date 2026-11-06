function Test-AvmBicepObservedNestedReadFailure {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [Parameter(Mandatory)] [string] $DeploymentId,
        [Parameter(Mandatory)] [object] $DefaultProfile,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Observed
    )

    Set-StrictMode -Version 3.0
    if ($ErrorRecord.CategoryInfo.Category -in @('AuthenticationError', 'PermissionDenied', 'SecurityError') -or
        (Get-AvmBicepDeploymentErrorKind -ErrorRecord $ErrorRecord) -ne 'Other' -or
        $DeploymentId -notmatch '\A/subscriptions/(?<subscription>[0-9a-f-]{36})/providers/Microsoft\.Resources/deployments/(?<name>[a-z0-9_.()-]+)\z') {
        return $false
    }
    $subscription = [guid]::Empty
    if (-not [guid]::TryParseExact($Matches.subscription, 'D', [ref]$subscription) -or $subscription -eq [guid]::Empty) { return $false }
    $profileSubscription = Get-AvmPropertyValue -InputObject $DefaultProfile -Name 'Subscription' -NoEnumerate
    $profileId = Get-AvmPropertyValue -InputObject $profileSubscription -Name 'Id' -NoEnumerate
    $selected = [guid]::Empty
    if ($profileId -isnot [string] -or -not [guid]::TryParseExact($profileId, 'D', [ref]$selected) -or
        $selected -ne $subscription) { return $false }

    $pattern = @(
        '\A(?:The running command stopped because the preference variable "ErrorActionPreference" or common parameter is set to Stop: )?'
        "Deployment '(?<name>[a-zA-Z0-9_.()-]+)' could not be found\. StatusCode: 404 ReasonPhrase: Not Found"
        '(?: OperationID\s*:\s*[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})?\s*\z'
    ) -join ''
    $name = $null
    $visited = [System.Collections.Generic.HashSet[System.Exception]]::new()
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if (-not $visited.Add($exception) -or $visited.Count -gt 100 -or
            $exception -is [System.UnauthorizedAccessException] -or $exception -is [System.OperationCanceledException] -or
            $exception -is [System.Security.Authentication.AuthenticationException] -or
            $exception -is [System.Security.SecurityException]) { return $false }
        if ($exception -is [System.AggregateException]) {
            if ($exception.InnerExceptions.Count -ne 1) { return $false }
            $exception = $exception.InnerExceptions[0]
            continue
        }
        foreach ($propertyName in @('Request', 'Response', 'StatusCode', 'Body')) {
            if ($null -ne (Get-AvmPropertyValue -InputObject $exception -Name $propertyName -NoEnumerate)) { return $false }
        }
        if ($exception.Message -cnotmatch $pattern) { return $false }
        if ($null -ne $name -and $name -ine $Matches.name) { return $false }
        $name = $Matches.name
        $next = $exception.InnerException
        if ($exception -is [System.Management.Automation.RuntimeException] -and $null -ne $exception.ErrorRecord) {
            if ($exception.ErrorRecord.CategoryInfo.Category -in @('AuthenticationError', 'PermissionDenied', 'SecurityError')) {
                return $false
            }
            $recordException = $exception.ErrorRecord.Exception
            if (-not [object]::ReferenceEquals($recordException, $exception)) {
                if ($null -ne $next -and -not [object]::ReferenceEquals($next, $recordException)) { return $false }
                $next = $recordException
            }
        }
        $exception = $next
    }
    if (-not $name) { return $false }
    $childIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Observed.Keys) {
        if ($key -isnot [string] -or -not $key.StartsWith('resource:')) { continue }
        $resource = $Observed[$key]
        $id = Get-AvmPropertyValue -InputObject $resource -Name 'Id' -NoEnumerate
        $type = Get-AvmPropertyValue -InputObject $resource -Name 'Type' -NoEnumerate
        if ($id -isnot [string] -or $type -isnot [string] -or $type -ine 'Microsoft.Resources/deployments' -or
            $id -ieq $DeploymentId -or $key -ine ('resource:' + $id) -or
            $id -notmatch '\A/subscriptions/(?<subscription>[0-9a-f-]{36})/(?:resourceGroups/[^/]+/)?providers/Microsoft\.Resources/deployments/(?<name>[a-z0-9_.()-]+)\z' -or
            $Matches.name -ine $name) { continue }
        $childSubscription = [guid]::Empty
        if ([guid]::TryParseExact($Matches.subscription, 'D', [ref]$childSubscription) -and $childSubscription -eq $subscription) {
            $null = $childIds.Add($id)
        }
    }
    return $childIds.Count -eq 1
}
