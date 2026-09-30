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

        [switch] $ExpectCreated
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
                Message = "Cannot verify the resource group '$ResourceGroupName' after a successful creation; manual cleanup verification is required."
            }
        }
        return [pscustomobject]@{ Cleaned = $true; Message = '' }
    }
    $shown = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
        'group', 'show', '--name', $ResourceGroupName,
        '--subscription', $SubscriptionId, '--output', 'json'
    ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($shown.ExitCode -ne 0) {
        return [pscustomobject]@{
            Cleaned = $false
            Message = Add-AvmProcessFailureDetail `
                -Message "Cannot verify ownership of resource group '$ResourceGroupName'." `
                -StdErr $shown.StdErr
        }
    }
    if (-not (Test-Json -Json ([string]$shown.StdOut) -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Cleaned = $false
            Message = "Cannot verify ownership of resource group '$ResourceGroupName': Azure CLI returned invalid JSON."
        }
    }
    $group = [string]$shown.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $expectedId = '/subscriptions/{0}/resourceGroups/{1}' -f $SubscriptionId, $ResourceGroupName
    $ownerKeys = @()
    if ($group -is [System.Collections.IDictionary] -and
        $group['tags'] -is [System.Collections.IDictionary]) {
        $ownerKeys = @($group['tags'].Keys |
                Where-Object { $_ -is [string] -and $_ -ieq 'avm-e2e-run-id' })
    }
    if ($group -isnot [System.Collections.IDictionary] -or
        -not [string]::Equals([string]$group['id'], $expectedId, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$group['name'], $ResourceGroupName, [System.StringComparison]::OrdinalIgnoreCase) -or
        $ownerKeys.Count -ne 1 -or
        $ownerKeys[0] -cne 'avm-e2e-run-id' -or
        $group['tags']['avm-e2e-run-id'] -cne $RunId) {
        return [pscustomobject]@{
            Cleaned = $false
            Message = "Refusing to delete unverified resource group '$ResourceGroupName'; manual cleanup is required."
        }
    }
    if (-not $PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete disposable Bicep test resource group')) {
        return [pscustomobject]@{
            Cleaned = $false
            Message = "Deletion of disposable resource group '$ResourceGroupName' was declined; manual cleanup is required."
        }
    }
    $deleted = Invoke-AvmProcess -FilePath $AzPath -ArgumentList @(
        'group', 'delete', '--name', $ResourceGroupName, '--subscription', $SubscriptionId,
        '--yes', '--output', 'none'
    ) -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($deleted.ExitCode -ne 0) {
        return [pscustomobject]@{
            Cleaned = $false
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
            Message = "Resource group '$ResourceGroupName' still exists after deletion; manual cleanup is required."
        }
    }
    return [pscustomobject]@{ Cleaned = $true; Message = '' }
}
