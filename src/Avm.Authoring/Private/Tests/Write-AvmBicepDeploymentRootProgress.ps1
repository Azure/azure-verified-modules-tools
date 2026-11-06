function Write-AvmBicepDeploymentRootProgress {
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
    try {
        $response = Invoke-AvmBicepRead -Activity 'Read root deployment progress' -RetryAuthorizationPropagation -Read {
            Invoke-AvmBicepAzureOperation -Activity 'Root deployment progress read' -Operation {
                Invoke-AzRestMethod -Method GET -Path ($DeploymentId + '?api-version=2021-04-01') @profileOptions -ErrorAction Stop
            }
        }
        $document = ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read root deployment progress'
        $properties = Get-AvmPropertyValue -InputObject $document -Name 'properties' -NoEnumerate
        if ($document['id'] -isnot [string] -or $document['id'] -ine $DeploymentId -or
            $document.Contains('error') -or $properties -isnot [System.Collections.IDictionary] -or
            $properties['provisioningState'] -isnot [string] -or
            $properties['provisioningState'] -cnotin @('Accepted', 'Running', 'Creating', 'Updating', 'Deleting', 'Succeeded', 'Failed', 'Canceled', 'Canceling')) {
            throw [AvmProcessException]::new('Root deployment progress did not identify a deployment state.')
        }
        $state = $properties['provisioningState']
        if (-not $Observed.Contains('__rootState') -or $Observed['__rootState'] -cne $state) {
            Write-AvmLog -Level Info -Message "Deployment $($DeploymentId.Split('/')[-1]): $state."
            $Observed['__rootState'] = $state
        }
    }
    catch [System.OperationCanceledException] {
        if (-not (Test-AvmBicepAzureOperationCancellation -Exception $_.Exception)) { throw }
        $detail = Protect-AvmBicepDiagnosticText -Text $_.Exception.Message -SensitiveValues $SensitiveValues
        if (-not $Observed.Contains('__rootReadFailure') -or $Observed['__rootReadFailure'] -cne $detail) {
            Write-AvmLog -Level Warning -Message "Root deployment progress is incomplete: $detail"
            $Observed['__rootReadFailure'] = $detail
        }
    }
    catch {
        if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') { throw }
        $detail = Protect-AvmBicepDiagnosticText -Text $_.Exception.Message -SensitiveValues $SensitiveValues
        if (-not $Observed.Contains('__rootReadFailure') -or $Observed['__rootReadFailure'] -cne $detail) {
            Write-AvmLog -Level Warning -Message "Root deployment progress is incomplete: $detail"
            $Observed['__rootReadFailure'] = $detail
        }
    }
}
