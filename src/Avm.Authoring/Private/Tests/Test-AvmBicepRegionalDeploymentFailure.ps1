function Test-AvmBicepRegionalDeploymentFailure {
    <#
    .SYNOPSIS
        Returns $true only when a failed deployment's operation errors are all regional.
    .DESCRIPTION
        Re-reads the deployment and requires it to be exactly Failed, then reads raw operation
        pages so statusMessage.error keeps its structure. Unknown, canceled, mixed or malformed
        errors return $false; unreadable responses throw.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $DeploymentId
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $response = Invoke-AzRestMethod -Method GET -Path ($DeploymentId + '?api-version=2021-04-01') -ErrorAction Stop
    $deployment = ConvertFrom-Json -InputObject $response.Content -AsHashtable -ErrorAction Stop
    if ([int]$response.StatusCode -ne 200 -or $deployment -isnot [System.Collections.IDictionary] -or
        (Get-AvmPropertyValue -InputObject $deployment -Name 'id') -ine $DeploymentId) {
        throw [AvmProcessException]::new("Deployment state could not be confirmed for '$DeploymentId' (HTTP $($response.StatusCode)).")
    }
    $properties = Get-AvmPropertyValue -InputObject $deployment -Name 'properties'
    if ((Get-AvmPropertyValue -InputObject $properties -Name 'provisioningState') -cne 'Failed') {
        return $false
    }

    $operationsPath = $DeploymentId + '/operations'
    $nextPath = $operationsPath + '?api-version=2021-04-01'
    $visitedPages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $errors = [System.Collections.Generic.List[object]]::new()
    while (-not [string]::IsNullOrEmpty($nextPath)) {
        if (-not $visitedPages.Add($nextPath) -or $visitedPages.Count -gt 1000) {
            throw [AvmProcessException]::new("Deployment returned repeated or excessive operation pages: $DeploymentId")
        }
        $page = Invoke-AzRestMethod -Method GET -Path $nextPath -ErrorAction Stop
        $document = ConvertFrom-Json -InputObject $page.Content -AsHashtable -ErrorAction Stop
        if ([int]$page.StatusCode -ne 200 -or $document -isnot [System.Collections.IDictionary] -or
            -not $document.Contains('value') -or $document['value'] -isnot [array]) {
            throw [AvmProcessException]::new("Deployment operations could not be read for '$DeploymentId' (HTTP $($page.StatusCode)).")
        }
        foreach ($operation in $document['value']) {
            $operationProperties = Get-AvmPropertyValue -InputObject $operation -Name 'properties'
            if ($operationProperties -isnot [System.Collections.IDictionary]) { return $false }
            $operationState = Get-AvmPropertyValue -InputObject $operationProperties -Name 'provisioningState'
            if ($operationState -ceq 'Succeeded') { continue }
            if ($operationState -cne 'Failed') { return $false }
            $statusMessage = Get-AvmPropertyValue -InputObject $operationProperties -Name 'statusMessage'
            if ($statusMessage -isnot [System.Collections.IDictionary] -or -not $statusMessage.Contains('error')) {
                return $false
            }
            $errors.Add($statusMessage['error'])
        }
        $nextPath = Resolve-AvmBicepCleanupNextLink -ExpectedPath $operationsPath -NextLink (
            Get-AvmPropertyValue -InputObject $document -Name 'nextLink')
    }
    if ($errors.Count -eq 0) {
        return $false
    }
    foreach ($errorNode in $errors) {
        if (-not (Test-AvmBicepRegionalErrorNode -Node $errorNode)) {
            return $false
        }
    }
    return $true
}
