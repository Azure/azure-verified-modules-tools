function Test-AvmBicepNativeDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $DeploymentInput,

        [Parameter(Mandatory)]
        [string] $TemplateContent,

        [string] $ResourceType,

        [string] $ResourceLocation,

        [string] $TokenResourceLocation,

        [ValidateRange(1, 3)]
        [int] $RetryLimit = 3
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $parameters = $DeploymentInput.Parameters
    $pinned = @(
        @($ResourceLocation, $TokenResourceLocation, $parameters['resourceLocation']) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_ -replace '\s', '').ToLowerInvariant() } |
            Sort-Object -Unique
    )
    if ($pinned.Count -gt 1) {
        throw [AvmConfigurationException]::new('Conflicting resource locations were supplied by parameters, CI inputs or tokens.')
    }
    $hasToken = $TemplateContent -match '#_resourceLocation_#'
    $hasParameter = $parameters.ContainsKey('resourceLocation')
    $canRetry = $pinned.Count -eq 0 -and $DeploymentInput.Scope -ne 'group' -and ($hasParameter -or $hasToken)
    $attempted = @()
    for ($attempt = 1; $attempt -le $RetryLimit; $attempt++) {
        $selection = if ($pinned.Count -gt 0) {
            [pscustomobject]@{ Location = $pinned[0]; IsGlobal = $false }
        }
        else {
            Get-AvmBicepResourceLocation -ResourceType $ResourceType `
                -MetadataLocation $DeploymentInput.MetadataLocation -UnavailableRegions $attempted
        }
        if ($selection.Location -in $attempted) {
            throw [AvmProcessException]::new('Resource location selection repeated a rejected region.')
        }
        $attempted += $selection.Location
        $inputOptions = $DeploymentInput.Clone()
        $inputOptions.Parameters = $parameters.Clone()
        if ($hasParameter) { $inputOptions.Parameters['resourceLocation'] = $selection.Location }
        $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $map.Add('resourceLocation', $selection.Location)
        $content = Resolve-AvmBicepTestToken -Content $TemplateContent -SourcePath $DeploymentInput.TemplatePath -Tokens $map
        if (-not $PSCmdlet.ShouldProcess($DeploymentInput.TemplatePath, "Validate Bicep resources in $($selection.Location)")) {
            return
        }
        $validated = $false
        try {
            [System.IO.File]::WriteAllText($DeploymentInput.TemplatePath, $content, [System.Text.UTF8Encoding]::new($false))
            Invoke-AvmBicepNativeArmOperation @inputOptions -Operation Validate -Confirm:$false
            $validated = $true
            return [pscustomobject]@{ Location = $selection.Location; DeploymentInput = $inputOptions; Attempts = $attempt }
        }
        catch {
            if (-not $canRetry -or $selection.IsGlobal -or $attempt -eq $RetryLimit -or
                -not (Test-AvmBicepRegionalValidationError -ErrorRecord $_)) { throw }
            Write-AvmLog -Level Warning -Message (
                "Regional validation failed in '$($selection.Location)'; selecting another eligible region ($attempt/$RetryLimit).")
        }
        finally {
            if (-not $validated) {
                [System.IO.File]::WriteAllText(
                    $DeploymentInput.TemplatePath, $TemplateContent, [System.Text.UTF8Encoding]::new($false))
            }
        }
    }
}
