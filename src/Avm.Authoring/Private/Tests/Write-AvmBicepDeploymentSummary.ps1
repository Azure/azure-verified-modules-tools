function Write-AvmBicepDeploymentSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DeploymentId,
        [Parameter(Mandatory)] [string] $Scope,
        [Parameter(Mandatory)] [string] $Location,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Observed,
        [AllowEmptyCollection()] [string[]] $SensitiveValues = @(),
        [object] $DefaultProfile
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $profileOptions = @{}
    if ($PSBoundParameters.ContainsKey('DefaultProfile')) { $profileOptions.DefaultProfile = $DefaultProfile }
    try {
        $response = Invoke-AvmBicepRead -Activity 'Read final deployment summary' -Read {
            Invoke-AzRestMethod -Method GET -Path ($DeploymentId + '?api-version=2021-04-01') @profileOptions -ErrorAction Stop
        }
        $document = ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read final deployment summary'
        $properties = Get-AvmPropertyValue -InputObject $document -Name 'properties' -NoEnumerate
        if ($document['id'] -ine $DeploymentId -or $properties -isnot [System.Collections.IDictionary]) {
            throw [AvmProcessException]::new('Deployment summary did not identify the submitted deployment.')
        }
        $name = Get-AvmPropertyValue -InputObject $document -Name 'name' -NoEnumerate
        $state = Get-AvmPropertyValue -InputObject $properties -Name 'provisioningState' -NoEnumerate
        $duration = Get-AvmPropertyValue -InputObject $properties -Name 'duration' -NoEnumerate
        $correlation = Get-AvmPropertyValue -InputObject $properties -Name 'correlationId' -NoEnumerate
        Write-AvmLog -Level Info -Message (
            "Finished deployment: name=$name id=$DeploymentId scope=$Scope location=$Location " +
            "state=$state duration=$duration correlationId=$correlation")
        Write-AvmLog -Level Info -Message 'Listing deployment resources.'
        $resources = @($Observed.Keys | Where-Object { $_ -is [string] -and $_.StartsWith('resource:') } |
                ForEach-Object { $Observed[$_] } | Sort-Object Type, Name)
        foreach ($resource in $resources) {
            Write-AvmLog -Level Info -Message "  $($resource.Type) $($resource.Name) $($resource.State) $($resource.Duration) $($resource.Id)"
        }
        $outputs = Get-AvmPropertyValue -InputObject $properties -Name 'outputs' -NoEnumerate
        if ($null -ne $outputs -and $outputs -isnot [System.Collections.IDictionary]) {
            throw [AvmProcessException]::new('Deployment summary outputs were malformed.')
        }
        if ($null -eq $outputs) { $outputs = @{} }
        if ($outputs.Count -eq 0) {
            Write-AvmLog -Level Info -Message 'No outputs.'
        }
        else {
            Write-AvmLog -Level Info -Message 'Listing deployment outputs.'
        }
        foreach ($outputName in @($outputs.Keys | Sort-Object)) {
            $output = $outputs[$outputName]
            $type = [string](Get-AvmPropertyValue -InputObject $output -Name 'type' -NoEnumerate)
            $value = Get-AvmPropertyValue -InputObject $output -Name 'value' -NoEnumerate
            if ($type -iin @('secureString', 'secureObject') -and $null -ne $value) {
                throw [AvmProcessException]::new('ARM returned an unexpected value for a secure deployment output.')
            }
            $rendered = ConvertTo-Json -InputObject $value -Depth 100 -Compress
            Write-AvmLog -Level Info -Message "  $outputName ($type): $rendered"
        }
    }
    catch {
        if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') { throw }
        $detail = Protect-AvmBicepDiagnosticText -Text $_.Exception.Message -SensitiveValues $SensitiveValues
        Write-AvmLog -Level Warning -Message "Deployment summary is incomplete: $detail"
    }
}
