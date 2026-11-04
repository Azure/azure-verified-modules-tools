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
                $page = ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read deployment progress'
                if ($page['value'] -isnot [array]) { throw [AvmProcessException]::new('Deployment progress operations were malformed.') }
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
                    $operationId = [string](Get-AvmPropertyValue -InputObject $operation -Name 'operationId' -NoEnumerate)
                    if (-not $operationId) { $operationId = $id }
                    $key = "$current|$operationId"
                    $previous = $Observed[$key]
                    if ($null -eq $previous -or $previous.State -cne $state) {
                        Write-AvmLog -Level Info -Message "Observed resource state change: time=$timestamp type=$type name=$name state=$state duration=$duration id=$id"
                    }
                    $Observed[$key] = [pscustomobject]@{
                        Id = $id; Type = $type; Name = $name; State = $state; Timestamp = $timestamp; Duration = $duration
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
}
