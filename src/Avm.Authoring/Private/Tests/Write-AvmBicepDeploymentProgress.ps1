function Write-AvmBicepDeploymentProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DeploymentId,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Observed,
        [AllowEmptyCollection()] [string[]] $SensitiveValues = @(),
        [object] $DefaultProfile
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $profileOptions = @{}
    if ($PSBoundParameters.ContainsKey('DefaultProfile')) { $profileOptions.DefaultProfile = $DefaultProfile }
    $subscription = [regex]::Match($DeploymentId, '^/subscriptions/([^/]+)/', 'IgnoreCase')
    $rootIndex = $DeploymentId.LastIndexOf('/providers/Microsoft.Resources/deployments/', [System.StringComparison]::OrdinalIgnoreCase)
    if ($rootIndex -lt 0) { throw [AvmConfigurationException]::new('Invalid root deployment ID for progress.') }
    $rootScope = $DeploymentId.Substring(0, $rootIndex)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($DeploymentId)
    $deployments = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $pages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $snapshot = @{}
    try {
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            if (-not $deployments.Add($current)) { continue }
            if ($deployments.Count -gt 20) { throw [AvmProcessException]::new('Deployment progress nesting exceeded its limit.') }
            $path = $current + '/operations'
            $next = $path + '?api-version=2025-04-01'
            while ($next) {
                if (-not $pages.Add($next) -or $pages.Count -gt 40) {
                    throw [AvmProcessException]::new('Deployment progress pagination exceeded its limit.')
                }
                $response = Invoke-AvmBicepRead -Activity 'Read deployment progress' -Read {
                    Invoke-AzRestMethod -Method GET -Path $next @profileOptions -ErrorAction Stop
                }
                $status = Get-AvmPropertyValue -InputObject $response -Name 'StatusCode' -NoEnumerate
                if ($current -ieq $DeploymentId -and -not $Observed.Contains('__progressStarted') -and
                    ($status -is [int] -or $status -is [System.Net.HttpStatusCode]) -and [int]$status -eq 404) {
                    $missing = ConvertFrom-AvmBicepRestResponse -Response $response `
                        -Activity 'Read deployment progress' -AllowedStatus @(404)
                    $errorBody = Get-AvmPropertyValue -InputObject $missing -Name 'error' -NoEnumerate
                    $errorCode = Get-AvmPropertyValue -InputObject $errorBody -Name 'code' -NoEnumerate
                    if ($errorCode -ceq 'DeploymentNotFound') {
                        if (-not $Observed.Contains('__waitingForDeployment')) {
                            Write-AvmLog -Level Info -Message 'Waiting for the deployment to start.'
                            $Observed['__waitingForDeployment'] = 'shown'
                        }
                        return
                    }
                }
                $page = ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read deployment progress'
                if ($page['value'] -isnot [array]) { throw [AvmProcessException]::new('Deployment progress operations were malformed.') }
                if ($current -ieq $DeploymentId) { $Observed['__progressStarted'] = 'yes' }
                foreach ($operation in $page['value']) {
                    $properties = Get-AvmPropertyValue -InputObject $operation -Name 'properties' -NoEnumerate
                    $target = Get-AvmPropertyValue -InputObject $properties -Name 'targetResource' -NoEnumerate
                    $id = [string](Get-AvmPropertyValue -InputObject $target -Name 'id' -NoEnumerate)
                    $type = [string](Get-AvmPropertyValue -InputObject $target -Name 'resourceType' -NoEnumerate)
                    $name = [string](Get-AvmPropertyValue -InputObject $target -Name 'resourceName' -NoEnumerate)
                    $state = [string](Get-AvmPropertyValue -InputObject $properties -Name 'provisioningState' -NoEnumerate)
                    if (-not $id -or -not $type -or -not $state) { continue }
                    $timestamp = [string](Get-AvmPropertyValue -InputObject $properties -Name 'timestamp' -NoEnumerate)
                    $duration = [string](Get-AvmPropertyValue -InputObject $properties -Name 'duration' -NoEnumerate)
                    $operationKind = [string](Get-AvmPropertyValue -InputObject $properties -Name 'provisioningOperation' -NoEnumerate)
                    $sortTime = [datetimeoffset]::MinValue
                    $null = [datetimeoffset]::TryParse($timestamp, [ref]$sortTime)
                    $key = 'resource:' + $id.ToLowerInvariant()
                    $candidate = [pscustomobject]@{
                        Id = $id; Type = $type; Name = $name; State = $state; Timestamp = $timestamp
                        Duration = $duration; SortTime = $sortTime; Operation = $operationKind
                    }
                    $existing = $snapshot[$key]
                    if ($null -eq $existing -or $candidate.SortTime -gt $existing.SortTime -or
                        ($candidate.SortTime -eq $existing.SortTime -and
                        $candidate.State -in @('Succeeded', 'Failed', 'Canceled') -and
                        $existing.State -notin @('Succeeded', 'Failed', 'Canceled'))) {
                        $snapshot[$key] = $candidate
                    }
                    if ($type -ine 'Microsoft.Resources/deployments') { continue }
                    $withinScope = if ($subscription.Success) {
                        $id.StartsWith("/subscriptions/$($subscription.Groups[1].Value)/", [System.StringComparison]::OrdinalIgnoreCase)
                    }
                    else { $id.StartsWith($rootScope + '/providers/', [System.StringComparison]::OrdinalIgnoreCase) }
                    if (-not $withinScope) { continue }
                    $parsed = @(ConvertTo-AvmBicepCleanupResource -ResourceIds @($id))
                    if ($parsed.Count -eq 1 -and $parsed[0].type -ieq 'Microsoft.Resources/deployments') {
                        $queue.Enqueue($id)
                    }
                }
                $next = Resolve-AvmBicepCleanupNextLink -ExpectedPath $path -NextLink (
                    Get-AvmPropertyValue -InputObject $page -Name 'nextLink' -NoEnumerate)
            }
        }
    }
    catch {
        if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') { throw }
        $detail = Protect-AvmBicepDiagnosticText -Text $_.Exception.Message -SensitiveValues $SensitiveValues
        if (-not $Observed.Contains('__readFailure') -or $Observed['__readFailure'] -cne $detail) {
            Write-AvmLog -Level Warning -Message "Deployment progress is incomplete: $detail"
            $Observed['__readFailure'] = $detail
        }
    }
    foreach ($resource in @($snapshot.Values | Sort-Object SortTime, Id)) {
        $key = 'resource:' + $resource.Id.ToLowerInvariant()
        $previous = $Observed[$key]
        if ($null -ne $previous -and $resource.SortTime -lt $previous.SortTime) { continue }
        if ($null -ne $previous -and $resource.SortTime -eq $previous.SortTime -and
            $previous.State -in @('Succeeded', 'Failed', 'Canceled') -and
            $resource.State -in @('Running', 'Accepted', 'Creating', 'Updating', 'Deleting')) { continue }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $previous) { $seen = $previous.SeenStates }
        if ($null -eq $previous -or $previous.State -cne $resource.State) {
            $verb = switch ($resource.Operation) {
                'Delete' { @('Deleting', 'Deleted') }
                'Update' { @('Updating', 'Updated') }
                default { @('Creating', 'Created') }
            }
            $statusText = switch ($resource.State) {
                { $_ -in @('Running', 'Accepted', 'Creating', 'Updating', 'Deleting') } { "$($verb[0])..." }
                'Succeeded' {
                    $elapsed = ''
                    if ($resource.Duration) {
                        try {
                            $seconds = [System.Xml.XmlConvert]::ToTimeSpan($resource.Duration).TotalSeconds
                            if ($seconds -ge 0) { $elapsed = ' after {0}s' -f [math]::Round($seconds) }
                        }
                        catch [System.FormatException] {
                            Write-AvmLog -Level Warning -Message "Could not parse deployment duration for $($resource.Name)."
                        }
                    }
                    "$($verb[1])$elapsed"
                }
                default { $resource.State }
            }
            $stateKey = switch ($resource.State) {
                { $_ -in @('Running', 'Accepted', 'Creating', 'Updating', 'Deleting') } { $verb[0] }
                'Succeeded' { $verb[1] }
                default { $resource.State }
            }
            if ($seen.Add($stateKey)) {
                Write-AvmLog -Level Info -Message "$($resource.Name) ($($resource.Type)): $statusText"
            }
        }
        $resource | Add-Member -NotePropertyName SeenStates -NotePropertyValue $seen
        $Observed[$key] = $resource
    }
}
