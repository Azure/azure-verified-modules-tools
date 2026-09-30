function Test-AvmBicepConventionCompiledTemplate {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        $Scope,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [string] $SourcePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $schema = [string]$Template['$schema']
    $schemas = @(
        'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
        'https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#'
        'https://schema.management.azure.com/schemas/2019-08-01/tenantDeploymentTemplate.json#'
    )
    if ($schema -cnotin $schemas) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.compiled-schema' `
                    -Message 'The compiled template must use a current deployment schema for its scope.'))
    }
    if (-not $schema.StartsWith('https://', [System.StringComparison]::Ordinal)) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.compiled-schema-https' `
                    -Message 'The compiled ARM schema reference must use HTTPS.'))
    }
    $metadata = $Template['metadata']
    foreach ($name in @('name', 'description')) {
        if ($metadata -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$metadata[$name])) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code "avm.bicep.compiled-metadata-$name" `
                        -Message "The compiled template requires nonempty metadata.$name."))
        }
    }

    $resources = @()
    try {
        $resources = @(Get-AvmBicepConventionResource -Template $Template)
    }
    catch [AvmConfigurationException] {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.compiled-resource-shape' -Message $_.Exception.Message))
    }

    $strictObjects = $false
    $versionPath = Join-Path $Scope.Path 'version.json'
    if ([System.IO.File]::Exists($versionPath)) {
        $strictObjects = $true
        $versionMatch = [regex]::Match(
            [System.IO.File]::ReadAllText($versionPath), '"version"\s*:\s*"(?<number>[0-9]+\.[0-9]+)"')
        $version = $null
        if ($versionMatch.Success -and
            [version]::TryParse($versionMatch.Groups['number'].Value, [ref]$version)) {
            $strictObjects = $version -ge [version]'1.0'
        }
    }
    try {
        foreach ($issue in @(Test-AvmBicepConventionCompiledParameter -Root $Root `
                    -Scope $Scope -Template $Template -SourcePath $SourcePath `
                    -StrictObjectTypes $strictObjects)) {
            $issues.Add($issue)
        }
    }
    catch [AvmConfigurationException] {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.compiled-parameter-shape' -Message $_.Exception.Message))
    }
    if ($null -ne $Template['resources']) {
        foreach ($issue in @(Test-AvmBicepConventionCompiledTelemetry -Root $Root `
                    -Scope $Scope -Template $Template -SourcePath $SourcePath -Resources $resources)) {
            $issues.Add($issue)
        }
        foreach ($issue in @(Test-AvmBicepConventionCompiledOutput -Root $Root `
                    -Scope $Scope -Template $Template -SourcePath $SourcePath -Resources $resources)) {
            $issues.Add($issue)
        }
    }

    if ($schema -ceq $schemas[0] -and
        $Template['parameters'] -is [System.Collections.IDictionary] -and
        $Template['parameters'].Contains('location')) {
        $default = $Template['parameters']['location']['defaultValue']
        if ($default -ne '[resourceGroup().Location]' -and $default -ne 'global') {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.parameter-location' `
                        -Message "The location default for a resource-group template must be resourceGroup().Location or global."))
        }
    }

    return $issues.ToArray()
}
