function Remove-AvmBicepTestGroupDeploymentResource {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [pscustomobject] $Plan,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Contents,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $pending = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($resource in @($Plan.Resources) + @($Plan.Deployments)) {
        $null = $pending.Add($resource.Id)
    }
    foreach ($resource in $Contents) {
        $null = $pending.Add([string]$resource['id'])
    }
    try {
        $visited = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $observed = @(Get-AvmBicepScopedDeploymentOperation -AzPath $AzPath `
                -Scope group -SubscriptionId $SubscriptionId -DeploymentName $DeploymentName `
                -RunId $RunId -Plan $Plan -Pending $pending -Visited $visited `
                -OwnedGroupName $ResourceGroupName -WorkingDirectory $WorkingDirectory -DirectGroup)
        $created = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($resource in $observed) {
            $null = $created.Add($resource.Id)
        }
        foreach ($deployment in $Plan.Deployments) {
            if (-not $visited.Contains($deployment.Id)) {
                throw [AvmProcessException]::new(
                    "Nested deployment '$($deployment.Id)' lacks verified group operation history.")
            }
            $null = $pending.Remove($deployment.Id)
        }

        $listed = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $Contents) {
            $resource = Get-AvmBicepTestGroupResource -ResourceId ([string]$entry['id']) `
                -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -RunId $RunId
            if (-not $listed.Add($resource.Id) -or
                -not [string]::Equals([string]$entry['type'], $resource.Type,
                    [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string]$entry['name'], $resource.Name,
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                throw [AvmProcessException]::new(
                    "Group '$ResourceGroupName' contains a repeated or mismatched resource '$($resource.Id)'.")
            }
            $expected = @(
                if ($resource.Kind -eq 'Deployment') { $Plan.Deployments } else { $Plan.Resources }
            ) | Where-Object {
                [string]::Equals($_.Id, $resource.Id,
                    [System.StringComparison]::OrdinalIgnoreCase)
            }
            if (@($expected).Count -ne 1 -or
                ($resource.Kind -eq 'Deployment' -and -not $visited.Contains($resource.Id)) -or
                ($resource.Kind -eq 'Resource' -and -not $created.Contains($resource.Id))) {
                throw [AvmProcessException]::new(
                    "Group '$ResourceGroupName' contains unproven resource '$($resource.Id)'; deletion was refused.")
            }
            $tags = $entry['tags']
            if ($null -ne $tags -and $tags -isnot [System.Collections.IDictionary]) {
                throw [AvmProcessException]::new(
                    "Group '$ResourceGroupName' has uninspectable ownership tags on '$($resource.Id)'.")
            }
            if ((Get-AvmBicepRunOwnership -Tags $tags -RunId $RunId).State -in @('Ambiguous', 'Foreign')) {
                throw [AvmProcessException]::new(
                    "Group '$ResourceGroupName' has foreign ownership on '$($resource.Id)'.")
            }
        }

        $existing = [System.Collections.Generic.List[object]]::new()
        foreach ($resource in $Plan.Resources) {
            $state = Get-AvmBicepScopedResourceState -AzPath $AzPath `
                -Resource $resource -SubscriptionId $SubscriptionId -RunId $RunId `
                -WorkingDirectory $WorkingDirectory
            if ($state.Exists) {
                if (-not $listed.Contains($resource.Id) -or
                    -not $created.Contains($resource.Id)) {
                    throw [AvmProcessException]::new(
                        "Resource '$($resource.Id)' exists without a matching inventory and Create operation.")
                }
                $existing.Add($resource)
            }
            elseif ($listed.Contains($resource.Id)) {
                throw [AvmProcessException]::new(
                    "Group '$ResourceGroupName' changed while inspecting '$($resource.Id)'.")
            }
            else {
                $null = $pending.Remove($resource.Id)
            }
        }
        $group = [pscustomobject]@{
            Id        = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
            Type      = 'Microsoft.Resources/resourceGroups'
            Name      = $ResourceGroupName
            GroupName = $ResourceGroupName
            Kind      = 'Group'
        }
        $groupState = Get-AvmBicepScopedResourceState -AzPath $AzPath `
            -Resource $group -SubscriptionId $SubscriptionId -RunId $RunId `
            -WorkingDirectory $WorkingDirectory
        if (-not $groupState.Exists) {
            throw [AvmProcessException]::new(
                "Run-owned group '$ResourceGroupName' disappeared before owned-child cleanup.")
        }
        $ordered = @($existing | Sort-Object -Property @{
                Expression = { $_.Id.Split('/').Length }
                Descending = $true
            }, Id)
        foreach ($resource in $ordered) {
            if (-not $PSCmdlet.ShouldProcess($resource.Id, 'Delete verified Bicep test-group resource')) {
                throw [AvmProcessException]::new(
                    "Deletion of Bicep e2e resource '$($resource.Id)' was declined.")
            }
            $deleted = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
                'resource', 'delete', '--ids', $resource.Id,
                '--subscription', $SubscriptionId, '--output', 'none'
            ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
            if ($deleted.ExitCode -ne 0) {
                $message = Add-AvmProcessFailureDetail `
                    -Message "Cannot delete proven Bicep e2e resource '$($resource.Id)'." `
                    -StdErr $deleted.StdErr
                throw [AvmProcessException]::new($message)
            }
            $state = Get-AvmBicepScopedResourceState -AzPath $AzPath `
                -Resource $resource -SubscriptionId $SubscriptionId -RunId $RunId `
                -WorkingDirectory $WorkingDirectory
            if ($state.Exists) {
                throw [AvmProcessException]::new(
                    "Bicep e2e resource '$($resource.Id)' still exists after deletion.")
            }
            $null = $pending.Remove($resource.Id)
        }
    }
    catch [AvmProcessException] {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @($pending | Sort-Object)
            Message = $_.Exception.Message
        }
    }
    catch [AvmConfigurationException] {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @($pending | Sort-Object)
            Message = $_.Exception.Message
        }
    }
    catch [System.TimeoutException] {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @($pending | Sort-Object)
            Message = $_.Exception.Message
        }
    }
    return [pscustomobject]@{ Cleaned = $true; Pending = @(); Message = '' }
}
