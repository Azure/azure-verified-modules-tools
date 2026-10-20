function Test-AvmBicepNativeDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $DeploymentInput,

        [Parameter(Mandatory)]
        [string] $TemplateContent,

        [string] $ResourceType,

        [string] $SubscriptionId,

        [string] $ResourceLocation,

        [string] $TokenResourceLocation,

        [switch] $ParameterResourceLocationToken,

        # Regions already rejected for this case. They count towards RetryLimit and are never selected again.
        [string[]] $UnavailableRegions = @(),

        [ValidateRange(1, 3)]
        [int] $RetryLimit = 3
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $parameters = $DeploymentInput.Parameters
    $parameterLocation = $parameters['resourceLocation']
    if ($parameterLocation -ceq '#_resourceLocation_#') { $parameterLocation = '' }
    $pinned = @(
        @($ResourceLocation, $TokenResourceLocation, $parameterLocation) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_ -replace '\s', '').ToLowerInvariant() } |
            Sort-Object -Unique
    )
    if ($pinned.Count -gt 1) {
        throw [AvmConfigurationException]::new('Conflicting resource locations were supplied by parameters, CI inputs or tokens.')
    }
    $hasToken = $TemplateContent -match '#_resourceLocation_#' -or $ParameterResourceLocationToken
    $hasParameter = $parameters.ContainsKey('resourceLocation')
    $canRetry = $pinned.Count -eq 0 -and $DeploymentInput.Scope -ne 'group' -and ($hasParameter -or $hasToken)
    $attempted = [System.Collections.Generic.List[string]]::new([string[]]@($UnavailableRegions))
    while ($attempted.Count -lt $RetryLimit) {
        $selection = if ($pinned.Count -gt 0) {
            [pscustomobject]@{ Location = $pinned[0]; IsGlobal = $false }
        }
        else {
            Get-AvmBicepResourceLocation -ResourceType $ResourceType `
                -MetadataLocation $DeploymentInput.MetadataLocation -UnavailableRegions $attempted.ToArray()
        }
        if ($selection.Location -in $attempted) {
            throw [AvmProcessException]::new('Resource location selection repeated a rejected region.')
        }
        $attempted.Add($selection.Location)
        $inputOptions = $DeploymentInput.Clone()
        $inputOptions.Parameters = $parameters.Clone()
        if ($hasParameter) { $inputOptions.Parameters['resourceLocation'] = $selection.Location }
        $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $map.Add('resourceLocation', $selection.Location)
        $inputOptions.Parameters = Resolve-AvmBicepParameterToken -Value $inputOptions.Parameters -Tokens $map
        $content = Resolve-AvmBicepTestToken -Content $TemplateContent -SourcePath $DeploymentInput.TemplatePath -Tokens $map
        if (-not $PSCmdlet.ShouldProcess($DeploymentInput.TemplatePath, "Validate Bicep resources in $($selection.Location)")) {
            return
        }
        $validated = $false
        try {
            [System.IO.File]::WriteAllText($DeploymentInput.TemplatePath, $content, [System.Text.UTF8Encoding]::new($false))
            Invoke-AvmBicepNativeArmOperation @inputOptions -Operation Validate -Confirm:$false
            $validated = $true
            return [pscustomobject]@{
                Location         = $selection.Location
                DeploymentInput  = $inputOptions
                Attempts         = $attempted.Count - $UnavailableRegions.Count
                AttemptedRegions = $attempted.ToArray()
                CanRelocate      = $canRetry -and -not $selection.IsGlobal
            }
        }
        catch {
            if (-not $canRetry -or $selection.IsGlobal -or $attempted.Count -ge $RetryLimit -or
                -not (Test-AvmBicepRegionalValidationError -ErrorRecord $_ -SubscriptionId $SubscriptionId `
                        -ResourceLocation $selection.Location)) { throw }
            Write-AvmLog -Level Warning -Message (
                "Regional validation failed in '$($selection.Location)'; selecting another eligible region ($($attempted.Count)/$RetryLimit).")
        }
        finally {
            if (-not $validated) {
                [System.IO.File]::WriteAllText(
                    $DeploymentInput.TemplatePath, $TemplateContent, [System.Text.UTF8Encoding]::new($false))
            }
        }
    }
    throw [AvmProcessException]::new('The regional candidate budget is exhausted.')
}
