function Write-AvmBicepDeploymentDiagnostic {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $DeploymentId,
        [AllowNull()] [System.Management.Automation.ErrorRecord] $Failure,
        [AllowEmptyCollection()] [string[]] $SensitiveValues = @(),
        [switch] $ReadDeployment,
        [object] $DefaultProfile
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $nodes = [System.Collections.Generic.Queue[object]]::new()
    if ($null -ne $Failure) {
        $response = Get-AvmBicepErrorResponse -ErrorRecord $Failure
        if ($null -ne $response) { $nodes.Enqueue($response) }
        else {
            $message = Protect-AvmBicepDiagnosticText -Text $Failure.Exception.Message -SensitiveValues $SensitiveValues
            Write-AvmLog -Level Warning -Message "Azure submission error: $message"
        }
    }
    $outcome = ''
    if ($ReadDeployment) {
        try {
            $profileOptions = @{}
            if ($PSBoundParameters.ContainsKey('DefaultProfile')) { $profileOptions.DefaultProfile = $DefaultProfile }
            $response = Invoke-AvmBicepRead -Activity 'Read deployment diagnostics' -Read {
                Invoke-AzRestMethod -Method GET -Path ($DeploymentId + '?api-version=2021-04-01') @profileOptions -ErrorAction Stop
            }
            $document = ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read deployment diagnostics'
            $properties = Get-AvmPropertyValue -InputObject $document -Name 'properties' -NoEnumerate
            if ($document['id'] -isnot [string] -or $document['id'] -ine $DeploymentId -or
                $properties -isnot [System.Collections.IDictionary]) {
                throw [AvmProcessException]::new('Deployment diagnostic response did not identify the submitted deployment.')
            }
            if ($properties['provisioningState'] -ceq 'Failed') { $outcome = 'Failed' }
            $correlation = Get-AvmPropertyValue -InputObject $properties -Name 'correlationId' -NoEnumerate
            if ($correlation -is [string] -and $correlation -match '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
                Write-AvmLog -Level Warning -Message "Azure deployment correlation ID: $correlation"
            }
            $errorNode = Get-AvmPropertyValue -InputObject $properties -Name 'error' -NoEnumerate
            if ($null -ne $errorNode) { $nodes.Enqueue($errorNode) }
            $deployments = [System.Collections.Generic.Queue[string]]::new()
            $deployments.Enqueue($DeploymentId)
            $seenDeployments = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $subscriptionMatch = [regex]::Match($DeploymentId, '^/subscriptions/([^/]+)/', 'IgnoreCase')
            while ($deployments.Count -gt 0) {
                $current = $deployments.Dequeue()
                if (-not $seenDeployments.Add($current)) { continue }
                if ($seenDeployments.Count -gt 20) {
                    throw [AvmProcessException]::new('Deployment diagnostic nesting exceeded its limit.')
                }
                $operationsPath = $current + '/operations'
                $nextPath = $operationsPath + '?api-version=2025-04-01'
                while (-not [string]::IsNullOrEmpty($nextPath)) {
                    if (-not $visited.Add($nextPath) -or $visited.Count -gt 40) {
                        throw [AvmProcessException]::new('Deployment diagnostic operation pagination exceeded its limit.')
                    }
                    $page = Invoke-AvmBicepRead -Activity 'Read deployment diagnostic operations' -Read {
                        Invoke-AzRestMethod -Method GET -Path $nextPath @profileOptions -ErrorAction Stop
                    }
                    $result = ConvertFrom-AvmBicepRestResponse -Response $page -Activity 'Read deployment diagnostic operations'
                    if ($result['value'] -isnot [array]) {
                        throw [AvmProcessException]::new('Deployment diagnostic operations were malformed.')
                    }
                    foreach ($operation in $result['value']) {
                        $operationProperties = Get-AvmPropertyValue -InputObject $operation -Name 'properties' -NoEnumerate
                        if ($operationProperties -isnot [System.Collections.IDictionary] -or
                            $operationProperties['provisioningState'] -cne 'Failed') { continue }
                        $target = Get-AvmPropertyValue -InputObject $operationProperties -Name 'targetResource' -NoEnumerate
                        $targetId = Get-AvmPropertyValue -InputObject $target -Name 'id' -NoEnumerate
                        $targetType = Get-AvmPropertyValue -InputObject $target -Name 'resourceType' -NoEnumerate
                        if ($targetId -is [string]) {
                            $nodes.Enqueue(@{ target = $targetId })
                            if ($targetType -ieq 'Microsoft.Resources/deployments' -and $subscriptionMatch.Success -and
                                $targetId.StartsWith("/subscriptions/$($subscriptionMatch.Groups[1].Value)/",
                                    [System.StringComparison]::OrdinalIgnoreCase)) {
                                $resource = @(ConvertTo-AvmBicepCleanupResource -ResourceIds @($targetId))
                                if ($resource.Count -eq 1 -and $resource[0].type -ieq 'Microsoft.Resources/deployments') {
                                    $deployments.Enqueue($targetId)
                                }
                            }
                        }
                        $status = Get-AvmPropertyValue -InputObject $operationProperties -Name 'statusMessage' -NoEnumerate
                        if ($status -is [string]) {
                            try { $status = ConvertFrom-AvmStrictJson -Json $status -RejectCaseInsensitiveDuplicates }
                            catch [System.ArgumentException] { $status = @{ message = $status } }
                        }
                        if ($null -ne $status) { $nodes.Enqueue($status) }
                    }
                    $nextPath = Resolve-AvmBicepCleanupNextLink -ExpectedPath $operationsPath -NextLink (
                        Get-AvmPropertyValue -InputObject $result -Name 'nextLink' -NoEnumerate)
                }
            }
        }
        catch {
            if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') { throw }
            Write-AvmLog -Level Warning -Message 'Azure deployment diagnostics could not be read completely; the original outcome and cleanup safeguards are unchanged.'
        }
    }
    for ($visited = 0; $nodes.Count -gt 0 -and $visited -lt 100; $visited++) {
        $node = $nodes.Dequeue()
        if ($null -eq $node -or $node -is [string] -or $node -is [ValueType]) { continue }
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [System.Collections.IDictionary]) {
            foreach ($child in $node) { $nodes.Enqueue($child) }
            continue
        }
        if ($node -is [System.Collections.IDictionary]) {
            $map = @{}
            foreach ($key in $node.Keys) { $map[[string]$key] = $node[$key] }
            $node = $map
        }
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($name in @('code', 'message', 'target')) {
            $value = Get-AvmPropertyValue -InputObject $node -Name $name -NoEnumerate
            if ($value -is [string] -and -not [string]::IsNullOrEmpty($value)) {
                $safe = Protect-AvmBicepDiagnosticText -Text $value -SensitiveValues $SensitiveValues
                $parts.Add("$($name): $safe")
            }
        }
        if ($parts.Count -gt 0) { Write-AvmLog -Level Warning -Message "Azure deployment error: $($parts -join '; ')" }
        foreach ($name in @('error', 'details', 'innererror')) {
            $child = Get-AvmPropertyValue -InputObject $node -Name $name -NoEnumerate
            if ($null -ne $child) { $nodes.Enqueue($child) }
        }
    }
    if ($nodes.Count -gt 0) { Write-AvmLog -Level Warning -Message 'Azure deployment diagnostics were truncated.' }
    return $outcome
}
