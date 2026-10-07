function Remove-AvmBicepTestResourceGroup {
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
        [string] $WorkingDirectory,

        [switch] $ExpectCreated,

        [pscustomobject] $Plan,

        [string] $DeploymentName,

        [switch] $DeploymentAttempted
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $exists = Test-AvmBicepResourceGroup -AzPath $AzPath `
        -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
        -WorkingDirectory $WorkingDirectory
    if (-not $exists) {
        if ($ExpectCreated) {
            return [pscustomobject]@{
                Cleaned = $false
                Pending = @()
                Message = "Cannot verify the resource group '$ResourceGroupName' after a successful creation; manual cleanup verification is required."
            }
        }
        return [pscustomobject]@{ Cleaned = $true; Pending = @(); Message = '' }
    }
    $shown = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
        'group', 'show', '--name', $ResourceGroupName,
        '--subscription', $SubscriptionId, '--output', 'json'
    ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($shown.ExitCode -ne 0) {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @()
            Message = Add-AvmProcessFailureDetail `
                -Message "Cannot verify ownership of resource group '$ResourceGroupName'." `
                -StdErr $shown.StdErr
        }
    }
    if (-not (Test-Json -Json ([string]$shown.StdOut) -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @()
            Message = "Cannot verify ownership of resource group '$ResourceGroupName': Azure CLI returned invalid JSON."
        }
    }
    $group = [string]$shown.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $expectedId = '/subscriptions/{0}/resourceGroups/{1}' -f $SubscriptionId, $ResourceGroupName
    if ($group -isnot [System.Collections.IDictionary] -or
        -not [string]::Equals([string]$group['id'], $expectedId, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$group['name'], $ResourceGroupName, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Get-AvmBicepRunOwnership -Tags $group['tags'] -RunId $RunId).State -ne 'Owned') {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @()
            Message = "Refusing to delete unverified resource group '$ResourceGroupName'; manual cleanup is required."
        }
    }
    if (-not $PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete verified Bicep test resources and empty group')) {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @()
            Message = "Deletion of disposable resource group '$ResourceGroupName' was declined; manual cleanup is required."
        }
    }
    try {
        $contents = @(Get-AvmBicepTestGroupContent -AzPath $AzPath `
                -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
                -WorkingDirectory $WorkingDirectory)
    }
    catch [AvmProcessException] {
        return [pscustomobject]@{ Cleaned = $false; Pending = @(); Message = $_.Exception.Message }
    }
    if ($DeploymentAttempted) {
        if ($null -eq $Plan -or [string]::IsNullOrWhiteSpace($DeploymentName)) {
            return [pscustomobject]@{
                Cleaned = $false
                Pending = @($contents | ForEach-Object { [string]$_['id'] })
                Message = "Cannot reconcile attempted Bicep deployment in '$ResourceGroupName' without its exact preview and deployment name."
            }
        }
        $cleaned = Remove-AvmBicepTestGroupDeploymentResource -AzPath $AzPath `
            -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
            -RunId $RunId -DeploymentName $DeploymentName -Plan $Plan `
            -Contents $contents -WorkingDirectory $WorkingDirectory -Confirm:$false
        if (-not $cleaned.Cleaned) {
            return $cleaned
        }
    }
    elseif ($contents.Count -gt 0) {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @($contents | ForEach-Object { [string]$_['id'] })
            Message = "Refusing to delete group '$ResourceGroupName' containing resources without a verified deployment."
        }
    }
    try {
        $remaining = @(Get-AvmBicepTestGroupContent -AzPath $AzPath `
                -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
                -WorkingDirectory $WorkingDirectory)
        if ($remaining.Count -gt 0) {
            return [pscustomobject]@{
                Cleaned = $false
                Pending = @($remaining | ForEach-Object { [string]$_['id'] })
                Message = "Group '$ResourceGroupName' is not empty after owned-resource reconciliation; refusing deletion."
            }
        }
        $owned = [pscustomobject]@{
            Id        = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
            Type      = 'Microsoft.Resources/resourceGroups'
            Name      = $ResourceGroupName
            GroupName = $ResourceGroupName
            Kind      = 'Group'
        }
        $state = Get-AvmBicepScopedResourceState -AzPath $AzPath `
            -Resource $owned -SubscriptionId $SubscriptionId -RunId $RunId `
            -WorkingDirectory $WorkingDirectory
        if (-not $state.Exists) {
            throw [AvmProcessException]::new(
                "Cannot reverify ownership of group '$ResourceGroupName' immediately before deletion.")
        }
    }
    catch [AvmProcessException] {
        return [pscustomobject]@{ Cleaned = $false; Pending = @(); Message = $_.Exception.Message }
    }
    catch [AvmConfigurationException] {
        return [pscustomobject]@{ Cleaned = $false; Pending = @(); Message = $_.Exception.Message }
    }
    $deleted = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
        'group', 'delete', '--name', $ResourceGroupName, '--subscription', $SubscriptionId,
        '--yes', '--output', 'none'
    ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($deleted.ExitCode -ne 0) {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @()
            Message = Add-AvmProcessFailureDetail `
                -Message "Failed to delete disposable resource group '$ResourceGroupName'." `
                -StdErr $deleted.StdErr
        }
    }
    if (Test-AvmBicepResourceGroup -AzPath $AzPath `
            -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
            -WorkingDirectory $WorkingDirectory) {
        return [pscustomobject]@{
            Cleaned = $false
            Pending = @()
            Message = "Resource group '$ResourceGroupName' still exists after deletion; manual cleanup is required."
        }
    }
    return [pscustomobject]@{ Cleaned = $true; Pending = @(); Message = '' }
}
