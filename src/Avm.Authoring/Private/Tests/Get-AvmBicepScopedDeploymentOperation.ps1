function Get-AvmBicepScopedDeploymentOperation {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [ValidateSet('sub', 'mg', 'tenant', 'group')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [pscustomobject] $Plan,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]] $Pending,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string] $ManagementGroupId,

        [string] $OwnedGroupName,

        [System.Collections.Generic.HashSet[string]] $Visited,

        [System.Collections.Generic.HashSet[string]] $SeenResources,

        [switch] $DirectGroup,

        [int] $Depth = 0
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Depth -ge 64) {
        throw [AvmProcessException]::new('Bicep e2e nested deployment depth exceeded the safety limit.')
    }
    if ($Scope -eq 'group' -and [string]::IsNullOrWhiteSpace($OwnedGroupName)) {
        throw [AvmConfigurationException]::new(
            'Nested Bicep group operations require an explicit run-owned group.')
    }
    if ($DirectGroup -and $Scope -ne 'group') {
        throw [AvmConfigurationException]::new(
            'Direct Bicep group operations must remain within their run-owned resource group.')
    }
    if ($null -eq $Visited) {
        $Visited = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
    }
    if ($null -eq $SeenResources) {
        $SeenResources = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
    }
    $deploymentInput = @{
        AzPath            = $AzPath
        Scope             = $Scope
        SubscriptionId    = $SubscriptionId
        ManagementGroupId = $ManagementGroupId
        DeploymentName    = $DeploymentName
        WorkingDirectory  = $WorkingDirectory
    }
    if ($Scope -eq 'group') {
        $deploymentInput.ResourceGroupName = $OwnedGroupName
    }
    $deploymentId = Get-AvmBicepScopedDeploymentId -Scope $Scope `
        -SubscriptionId $SubscriptionId -ManagementGroupId $ManagementGroupId `
        -ResourceGroupName $OwnedGroupName -DeploymentName $DeploymentName
    if (-not $Visited.Add($deploymentId)) {
        throw [AvmProcessException]::new(
            "Deployment '$deploymentId' was visited twice; refusing ambiguous operations.")
    }
    $deployment = Get-AvmBicepScopedDeployment @deploymentInput
    if ($null -eq $deployment -or $deployment.State -notin @('Succeeded', 'Failed', 'Canceled')) {
        throw [AvmProcessException]::new(
            "Cannot confirm a terminal $Scope deployment '$deploymentId'; refusing cleanup.")
    }
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]]@(
            'deployment', 'operation', $Scope, 'list', '--name', $DeploymentName,
            '--subscription', $SubscriptionId, '--output', 'json'
        ))
    if ($Scope -eq 'mg') {
        $arguments.AddRange([string[]]@('--management-group-id', $ManagementGroupId))
    }
    elseif ($Scope -eq 'group') {
        $arguments.AddRange([string[]]@('--resource-group', $OwnedGroupName))
    }
    $result = Invoke-AvmProcess -FilePath $AzPath -ArgumentList $arguments.ToArray() `
        -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($result.ExitCode -ne 0) {
        $message = Add-AvmProcessFailureDetail `
            -Message "Cannot inspect operations for $Scope deployment '$deploymentId'." `
            -StdErr $result.StdErr
        throw [AvmProcessException]::new($message)
    }
    if (-not (Test-Json -Json ([string]$result.StdOut) -ErrorAction SilentlyContinue)) {
        throw [AvmProcessException]::new(
            "Azure CLI returned invalid deployment operations for '$deploymentId'.")
    }
    $operations = ConvertFrom-Json -InputObject ([string]$result.StdOut) `
        -AsHashtable -NoEnumerate -ErrorAction Stop
    if ($operations -isnot [System.Collections.IList] -or $operations.Count -eq 0) {
        throw [AvmProcessException]::new(
            "Azure CLI returned no inspectable deployment operations for '$deploymentId'.")
    }
    $observed = [System.Collections.Generic.List[object]]::new()
    $operationPrefix = "$deploymentId/operations/"
    $operationIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($operation in $operations) {
        if ($operation -isnot [System.Collections.IDictionary] -or
            -not ([string]$operation['id']).StartsWith(
                $operationPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $operation['properties'] -isnot [System.Collections.IDictionary]) {
            throw [AvmProcessException]::new(
                "Deployment '$deploymentId' returned an unrelated or malformed operation.")
        }
        $operationKey = ([string]$operation['id']).Substring($operationPrefix.Length)
        $operationName = [string]$operation['operationId']
        $nameMatches = [string]::IsNullOrWhiteSpace($operationName)
        if (-not $nameMatches) {
            $nameMatches = [string]::Equals($operationName, $operationKey, [System.StringComparison]::OrdinalIgnoreCase)
        }
        if ([string]::IsNullOrWhiteSpace($operationKey) -or
            $operationKey.Contains('/') -or -not $nameMatches -or
            -not $operationIds.Add($operationKey)) {
            throw [AvmProcessException]::new(
                "Deployment '$deploymentId' returned an invalid scoped operation ID.")
        }
        $properties = $operation['properties']
        if ($properties['provisioningOperation'] -eq 'EvaluateDeploymentOutput' -and
            $null -eq $properties['targetResource']) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($OwnedGroupName) -and
            ($properties['provisioningState'] -isnot [string] -or
            $properties['provisioningState'] -cnotin @('Succeeded', 'Failed', 'Canceled'))) {
            throw [AvmProcessException]::new(
                "Deployment '$deploymentId' returned a nonterminal group operation.")
        }
        $target = $properties['targetResource']
        if ($target -is [System.Collections.IDictionary] -and
            -not [string]::IsNullOrWhiteSpace([string]$target['id'])) {
            $null = $Pending.Add([string]$target['id'])
        }
        if ($properties['provisioningOperation'] -cne 'Create' -or
            $target -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$target['id']) -or
            [string]::IsNullOrWhiteSpace([string]$target['resourceType'])) {
            throw [AvmProcessException]::new(
                "Deployment '$deploymentId' returned an uninspectable or unsafe operation.")
        }
        $resource = if ($DirectGroup) {
            Get-AvmBicepTestGroupResource -ResourceId ([string]$target['id']) `
                -SubscriptionId $SubscriptionId -ResourceGroupName $OwnedGroupName -RunId $RunId
        }
        else {
            Get-AvmBicepScopedResource -ResourceId ([string]$target['id']) `
                -Scope $Scope -SubscriptionId $SubscriptionId -ManagementGroupId $ManagementGroupId `
                -RunId $RunId -OwnedGroupName $OwnedGroupName
        }
        if (-not [string]::Equals([string]$target['resourceType'], $resource.Type,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [AvmProcessException]::new(
                "Deployment '$deploymentId' returned a mismatched type for '$($resource.Id)'.")
        }
        if (-not [string]::IsNullOrWhiteSpace($OwnedGroupName) -and
            $target.Contains('resourceName') -and
            -not [string]::Equals([string]$target['resourceName'], $resource.Name,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [AvmProcessException]::new(
                "Deployment '$deploymentId' returned a mismatched resource name for '$($resource.Id)'.")
        }
        $predicted = @(
            if ($resource.Kind -eq 'Deployment') { $Plan.Deployments } else { $Plan.Resources }
        ) | Where-Object {
            [string]::Equals($_.Id, $resource.Id, [System.StringComparison]::OrdinalIgnoreCase)
        }
        if (@($predicted).Count -ne 1) {
            throw [AvmProcessException]::new(
                "Deployment '$deploymentId' changed '$($resource.Id)' without an exact Create prediction.")
        }
        if ($resource.Kind -eq 'Deployment') {
            $nestedScope = if ($resource.GroupName) { 'group' } else { $Scope }
            foreach ($nested in @(Get-AvmBicepScopedDeploymentOperation -AzPath $AzPath `
                        -Scope $nestedScope -SubscriptionId $SubscriptionId `
                        -ManagementGroupId $ManagementGroupId -DeploymentName $resource.Name `
                        -RunId $RunId -Plan $Plan -WorkingDirectory $WorkingDirectory `
                        -OwnedGroupName $OwnedGroupName -Pending $Pending `
                        -Visited $Visited -SeenResources $SeenResources -DirectGroup:$DirectGroup `
                        -Depth ($Depth + 1))) {
                $observed.Add($nested)
            }
            $null = $Pending.Remove($resource.Id)
        }
        else {
            if (-not $SeenResources.Add($resource.Id)) {
                throw [AvmProcessException]::new(
                    "Deployment '$deploymentId' repeated a Create operation for '$($resource.Id)'.")
            }
            $observed.Add($resource)
        }
    }
    return $observed.ToArray()
}
