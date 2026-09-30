function Remove-AvmBicepScopedDeploymentResource {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [ValidateSet('sub', 'mg', 'tenant')]
        [string] $Scope,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [pscustomobject] $Plan,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string] $ManagementGroupId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $remaining = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($resource in $Plan.Resources) {
        $null = $remaining.Add($resource.Id)
    }
    try {
        Assert-AvmBicepScopedAccount -AzPath $AzPath -SubscriptionId $SubscriptionId `
            -TenantId $TenantId -ManagementGroupId $(if ($Scope -eq 'mg') { $ManagementGroupId }) `
            -WorkingDirectory $WorkingDirectory
        $observed = @(Get-AvmBicepScopedDeploymentOperation -AzPath $AzPath `
                -Scope $Scope -SubscriptionId $SubscriptionId `
                -ManagementGroupId $ManagementGroupId -DeploymentName $DeploymentName `
                -RunId $RunId -Plan $Plan -Pending $remaining `
                -WorkingDirectory $WorkingDirectory)
        $operationIds = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($resource in $observed) {
            $null = $operationIds.Add($resource.Id)
        }
        $existing = [System.Collections.Generic.List[object]]::new()
        foreach ($resource in $Plan.Resources) {
            $state = Get-AvmBicepScopedResourceState -AzPath $AzPath `
                -Resource $resource -SubscriptionId $SubscriptionId -RunId $RunId `
                -WorkingDirectory $WorkingDirectory
            if ($state.Exists) {
                if (-not $operationIds.Contains($resource.Id)) {
                    throw [AvmProcessException]::new(
                        "Resource '$($resource.Id)' exists without a matching scoped deployment operation; manual cleanup is required.")
                }
                $existing.Add($resource)
            }
            else {
                $null = $remaining.Remove($resource.Id)
            }
        }

        $ordered = @($existing | Sort-Object -Property @{
                Expression = {
                    if ($_.Kind -eq 'Group') { 2 }
                    elseif ($_.Type -eq 'Microsoft.Authorization/policyDefinitions') { 1 }
                    else { 0 }
                }
            }, Id)
        foreach ($resource in $ordered) {
            if ($resource.Kind -eq 'Group') {
                $listed = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
                    'resource', 'list', '--resource-group', $resource.GroupName,
                    '--subscription', $SubscriptionId, '--output', 'json'
                ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
                if ($listed.ExitCode -ne 0 -or
                    -not (Test-Json -Json ([string]$listed.StdOut) -ErrorAction SilentlyContinue)) {
                    throw [AvmProcessException]::new(
                        "Cannot verify that group '$($resource.Id)' is empty before deletion.")
                }
                $contents = ConvertFrom-Json -InputObject ([string]$listed.StdOut) `
                    -AsHashtable -NoEnumerate -ErrorAction Stop
                if ($contents -isnot [System.Collections.IList]) {
                    throw [AvmProcessException]::new(
                        "Cannot inspect current contents of group '$($resource.Id)'.")
                }
                if ($contents.Count -gt 0) {
                    foreach ($content in $contents) {
                        if ($content -is [System.Collections.IDictionary] -and
                            -not [string]::IsNullOrWhiteSpace([string]$content['id'])) {
                            $null = $remaining.Add([string]$content['id'])
                        }
                    }
                    throw [AvmProcessException]::new(
                        "Group '$($resource.Id)' contains resources not proven owned by this test; refusing group deletion.")
                }
                if (-not $PSCmdlet.ShouldProcess($resource.Id, 'Delete verified empty Bicep test group')) {
                    throw [AvmProcessException]::new(
                        "Deletion of Bicep e2e group '$($resource.Id)' was declined.")
                }
                $removed = Remove-AvmBicepTestResourceGroup -AzPath $AzPath `
                    -SubscriptionId $SubscriptionId -ResourceGroupName $resource.GroupName `
                    -RunId $RunId -WorkingDirectory $WorkingDirectory `
                    -ExpectCreated -Confirm:$false
                if (-not $removed.Cleaned) {
                    throw [AvmProcessException]::new($removed.Message)
                }
            }
            else {
                if (-not $PSCmdlet.ShouldProcess($resource.Id, 'Delete verified Bicep test resource')) {
                    throw [AvmProcessException]::new(
                        "Deletion of Bicep e2e resource '$($resource.Id)' was declined.")
                }
                $deleted = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
                    'resource', 'delete', '--ids', $resource.Id,
                    '--subscription', $SubscriptionId, '--output', 'none'
                ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
                if ($deleted.ExitCode -ne 0) {
                    $message = Add-AvmProcessFailureDetail `
                        -Message "Could not delete Bicep e2e resource '$($resource.Id)'." `
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
            }
            $null = $remaining.Remove($resource.Id)
        }
        if ($remaining.Count -gt 0) {
            throw [AvmProcessException]::new(
                'Bicep e2e cleanup left unverified deployment resources; manual cleanup is required.')
        }
    }
    catch [AvmProcessException] {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @($remaining | Sort-Object)
            Message = $_.Exception.Message
        }
    }
    catch [AvmConfigurationException] {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @($remaining | Sort-Object)
            Message = $_.Exception.Message
        }
    }
    catch [System.TimeoutException] {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @($remaining | Sort-Object)
            Message = $_.Exception.Message
        }
    }
    return [pscustomobject]@{ Cleaned = $true; Pending = @(); Message = '' }
}
