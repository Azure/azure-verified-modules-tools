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
        $response = Invoke-AvmBicepRead -Activity 'Read final deployment summary' -RetryAuthorizationPropagation -Read {
            Invoke-AzRestMethod -Method GET -Path ($DeploymentId + '?api-version=2021-04-01') @profileOptions -ErrorAction Stop
        }
        $document = ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Read final deployment summary'
        $properties = Get-AvmPropertyValue -InputObject $document -Name 'properties' -NoEnumerate
        if ($document['id'] -ine $DeploymentId -or $properties -isnot [System.Collections.IDictionary]) {
            throw [AvmProcessException]::new('Deployment summary did not identify the submitted deployment.')
        }
        $name = Get-AvmPropertyValue -InputObject $document -Name 'name' -NoEnumerate
        $state = [string](Get-AvmPropertyValue -InputObject $properties -Name 'provisioningState' -NoEnumerate)
        $duration = [string](Get-AvmPropertyValue -InputObject $properties -Name 'duration' -NoEnumerate)
        $correlation = Get-AvmPropertyValue -InputObject $properties -Name 'correlationId' -NoEnumerate
        $elapsed = ''
        if ($duration) {
            try {
                $seconds = [long][math]::Round([System.Xml.XmlConvert]::ToTimeSpan($duration).TotalSeconds)
                if ($seconds -ge 0) {
                    $hours = [long][math]::Floor($seconds / 3600)
                    $minutes = [long][math]::Floor(($seconds % 3600) / 60)
                    $remainder = $seconds % 60
                    $elapsed = ' after ' + $(if ($hours -gt 0) { "${hours}h${minutes}m${remainder}s" }
                        elseif ($minutes -gt 0) { "${minutes}m${remainder}s" }
                        else { "${remainder}s" })
                }
            }
            catch [System.FormatException] {
                Write-AvmLog -Level Warning -Message "Could not parse deployment duration for $name."
            }
        }
        $stateText = if ($state) { $state.ToLowerInvariant() } else { 'finished with unknown state' }
        Write-AvmLog -Level Info -Message "Deployment $name $stateText$elapsed."
        Write-AvmLog -Level Info -Message (
            "Deployment ID: $DeploymentId. Scope: $Scope. Location: $Location. Correlation ID: $correlation.")
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
