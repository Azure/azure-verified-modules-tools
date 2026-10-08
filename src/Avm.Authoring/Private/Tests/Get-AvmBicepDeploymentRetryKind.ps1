function Get-AvmBicepDeploymentRetryKind {
    <#
    .SYNOPSIS
        Classify a confirmed failed deployment as Regional, Transient or None.
    .DESCRIPTION
        Re-reads the deployment and requires it to be exactly Failed, then reads raw operation
        pages so statusMessage.error keeps its structure. Unknown, canceled, mixed or malformed
        errors return None; unreadable responses throw.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $DeploymentId,

        [string] $SubscriptionId,
        [string] $ResourceLocation,

        [AllowNull()]
        [System.Management.Automation.ErrorRecord] $Failure
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $response = Invoke-AzRestMethod -Method GET -Path ($DeploymentId + '?api-version=2021-04-01') -ErrorAction Stop
    $deployment = ConvertFrom-AvmStrictJson -Json $response.Content -RejectCaseInsensitiveDuplicates
    if (($response.StatusCode -isnot [int] -and $response.StatusCode -isnot [System.Net.HttpStatusCode]) -or
        $response.StatusCode -ne 200 -or $deployment -isnot [System.Collections.IDictionary] -or
        $deployment['id'] -isnot [string] -or $deployment.Contains('error') -or
        (Get-AvmPropertyValue -InputObject $deployment -Name 'id') -ine $DeploymentId) {
        throw [AvmProcessException]::new("Deployment state could not be confirmed for '$DeploymentId' (HTTP $($response.StatusCode)).")
    }
    $properties = Get-AvmPropertyValue -InputObject $deployment -Name 'properties'
    if ($properties -isnot [System.Collections.IDictionary] -or
        $properties['provisioningState'] -isnot [string] -or $properties['provisioningState'] -cne 'Failed') {
        return 'None'
    }

    $operationsPath = $DeploymentId + '/operations'
    $nextPath = $operationsPath + '?api-version=2025-04-01'
    $visitedPages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $errors = [System.Collections.Generic.List[object]]::new()
    while (-not [string]::IsNullOrEmpty($nextPath)) {
        if (-not $visitedPages.Add($nextPath) -or $visitedPages.Count -gt 1000) {
            throw [AvmProcessException]::new("Deployment returned repeated or excessive operation pages: $DeploymentId")
        }
        $page = Invoke-AzRestMethod -Method GET -Path $nextPath -ErrorAction Stop
        $document = ConvertFrom-AvmStrictJson -Json $page.Content -RejectCaseInsensitiveDuplicates
        if (($page.StatusCode -isnot [int] -and $page.StatusCode -isnot [System.Net.HttpStatusCode]) -or
            $page.StatusCode -ne 200 -or $document -isnot [System.Collections.IDictionary] -or
            -not $document.Contains('value') -or $document['value'] -isnot [array]) {
            throw [AvmProcessException]::new("Deployment operations could not be read for '$DeploymentId' (HTTP $($page.StatusCode)).")
        }
        foreach ($operation in $document['value']) {
            $operationProperties = Get-AvmPropertyValue -InputObject $operation -Name 'properties'
            if ($operationProperties -isnot [System.Collections.IDictionary] -or
                $operationProperties['provisioningOperation'] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($operationProperties['provisioningOperation']) -or
                $operationProperties['provisioningState'] -isnot [string]) { return 'None' }
            $operationState = Get-AvmPropertyValue -InputObject $operationProperties -Name 'provisioningState'
            if ($operationState -ceq 'Succeeded') { continue }
            if ($operationState -cne 'Failed') { return 'None' }
            $statusMessage = Get-AvmPropertyValue -InputObject $operationProperties -Name 'statusMessage'
            if ($statusMessage -isnot [System.Collections.IDictionary] -or -not $statusMessage.Contains('error')) {
                return 'None'
            }
            $errors.Add($statusMessage)
        }
        $nextPath = Resolve-AvmBicepCleanupNextLink -ExpectedPath $operationsPath -NextLink (
            Get-AvmPropertyValue -InputObject $document -Name 'nextLink')
    }
    if ($errors.Count -eq 0) {
        return 'None'
    }
    foreach ($kind in @('Regional', 'Transient')) {
        if ($null -ne $Failure -and -not (Test-AvmBicepRetryErrorRecord -ErrorRecord $Failure -Kind $kind)) {
            continue
        }
        if (Test-AvmBicepRetryErrorNode -Node $errors.ToArray() -RetryKind $kind `
                -SubscriptionId $SubscriptionId -ResourceLocation $ResourceLocation) {
            return $kind
        }
    }
    return 'None'
}
