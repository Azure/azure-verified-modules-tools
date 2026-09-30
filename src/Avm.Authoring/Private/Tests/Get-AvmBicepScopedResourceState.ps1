function Get-AvmBicepScopedResourceState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $AzPath,

        [Parameter(Mandatory)]
        [pscustomobject] $Resource,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Resource.Kind -eq 'Group') {
        if (-not (Test-AvmBicepResourceGroup -AzPath $AzPath `
                    -SubscriptionId $SubscriptionId -ResourceGroupName $Resource.GroupName `
                    -WorkingDirectory $WorkingDirectory)) {
            return [pscustomobject]@{ Exists = $false }
        }
        $arguments = @(
            'group', 'show', '--name', $Resource.GroupName,
            '--subscription', $SubscriptionId, '--output', 'json'
        )
    }
    else {
        $arguments = @(
            'resource', 'show', '--ids', $Resource.Id,
            '--subscription', $SubscriptionId, '--output', 'json'
        )
    }
    $result = Invoke-AvmProcess -FilePath $AzPath -ArgumentList $arguments `
        -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    if ($result.ExitCode -ne 0) {
        if ($Resource.Kind -ne 'Group' -and
            (Test-AvmBicepAzNotFound -StdErr ([string]$result.StdErr))) {
            return [pscustomobject]@{ Exists = $false }
        }
        $message = Add-AvmProcessFailureDetail `
            -Message "Cannot inspect Bicep e2e resource '$($Resource.Id)'." `
            -StdErr $result.StdErr
        throw [AvmProcessException]::new($message)
    }
    if (-not (Test-Json -Json ([string]$result.StdOut) -ErrorAction SilentlyContinue)) {
        throw [AvmProcessException]::new(
            "Azure CLI returned invalid JSON for Bicep e2e resource '$($Resource.Id)'.")
    }
    $shown = [string]$result.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($shown -isnot [System.Collections.IDictionary]) {
        throw [AvmProcessException]::new(
            "Azure CLI returned an invalid Bicep e2e resource for '$($Resource.Id)'.")
    }
    $idMatches = [string]::Equals([string]$shown['id'], $Resource.Id, [System.StringComparison]::OrdinalIgnoreCase)
    $nameMatches = [string]::Equals([string]$shown['name'], $Resource.Name, [System.StringComparison]::OrdinalIgnoreCase)
    $typeMatches = [string]::Equals([string]$shown['type'], $Resource.Type, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $idMatches -or -not $nameMatches -or -not $typeMatches) {
        throw [AvmProcessException]::new(
            "Azure CLI returned an unrelated Bicep e2e resource for '$($Resource.Id)'.")
    }
    $tags = $shown['tags']
    $ownedGroup = $tags -is [System.Collections.IDictionary]
    if ($ownedGroup) {
        $ownedGroup = $tags['avm-e2e-run-id'] -ceq $RunId
    }
    if ($Resource.Kind -eq 'Group' -and -not $ownedGroup) {
        throw [AvmConfigurationException]::new(
            "Refusing to delete Bicep e2e group '$($Resource.Id)' without its verified ownership tag.")
    }
    if ($Resource.Kind -eq 'Resource' -and
        $shown['tags'] -is [System.Collections.IDictionary] -and
        $shown['tags'].Contains('avm-e2e-run-id') -and
        $shown['tags']['avm-e2e-run-id'] -cne $RunId) {
        throw [AvmConfigurationException]::new(
            "Refusing to delete Bicep e2e resource '$($Resource.Id)' with a foreign ownership tag.")
    }
    return [pscustomobject]@{ Exists = $true }
}
