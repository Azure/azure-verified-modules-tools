function Get-AvmBicepCompiledConventionInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object] $Module
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $template = $Module.Template
    $scope = $Module.Scope
    $resources = @()
    $resourceError = $null
    try { $resources = @(Get-AvmBicepConventionResource -Template $template) }
    catch [AvmConfigurationException] { $resourceError = $_.Exception.Message }
    $parameters = @()
    $parameterError = $null
    try { $parameters = @(Get-AvmBicepConventionParameter -Template $template) }
    catch [AvmConfigurationException] { $parameterError = $_.Exception.Message }
    $versionPath = Join-Path $scope.Path 'version.json'
    $versioned = [System.IO.File]::Exists($versionPath)
    $strictObjects = $false
    if ($versioned) {
        $strictObjects = $true
        $versionMatch = [regex]::Match(
            [System.IO.File]::ReadAllText($versionPath), '"version"\s*:\s*"(?<number>[0-9]+\.[0-9]+)"')
        $version = $null
        if ($versionMatch.Success -and [version]::TryParse($versionMatch.Groups['number'].Value, [ref]$version)) {
            $strictObjects = $version -ge [version]'1.0'
        }
    }
    $source = Get-AvmBicepCommentFreeSource -Source ([System.IO.File]::ReadAllText($Module.Path))
    $legacy = [regex]::IsMatch(
        $source, "(?m)^[ \t]*var[ \t]+telemetryIdPrefix[ \t]*=[ \t]*loadJsonContent\('metadata.json',[ \t]*'telemetryIdPrefix'\)[ \t]*\r?$")
    $scaffold = [regex]::IsMatch(
        $source, '(?m)^[ \t]*var[ \t]+avmTelemetryIdPrefix[ \t]*=[ \t]*loadJsonContent\(''metadata.json'',[ \t]*''\$\.telemetryIdPrefix''\)[ \t]*\r?$')
    $prefixName = if ($scaffold -and -not $legacy) { 'avmTelemetryIdPrefix' } else { 'telemetryIdPrefix' }
    $telemetryDescription = if ($prefixName -ceq 'avmTelemetryIdPrefix') {
        'Optional. Enable/disable usage telemetry for this module.'
    }
    else { 'Optional. Enable/Disable usage telemetry for module.' }
    $deployments = @($resources | Where-Object { $_.Resource['type'] -ceq 'Microsoft.Resources/deployments' })
    $telemetry = @($deployments | Where-Object {
            $name = $_.Resource['name']
            $name -is [string] -and (
                $name.Contains('46d3xbcp', [System.StringComparison]::OrdinalIgnoreCase) -or
                $name.Contains("variables('telemetryIdPrefix')", [System.StringComparison]::Ordinal) -or
                $name.Contains("variables('avmTelemetryIdPrefix')", [System.StringComparison]::Ordinal))
        })
    $referenced = @($deployments | Where-Object {
            $properties = $_.Resource['properties']
            $nested = if ($properties -is [System.Collections.IDictionary]) { $properties['template'] } else { $null }
            $nested -is [System.Collections.IDictionary] -and
            $nested['parameters'] -is [System.Collections.IDictionary] -and
            $nested['parameters'].Contains('enableTelemetry')
        })
    $metadataPath = Join-Path $scope.Path 'metadata.json'
    $metadata = $null
    $metadataError = $null
    $metadataRegular = [System.IO.File]::Exists($metadataPath) -and
    -not ([System.IO.File]::GetAttributes($metadataPath) -band [System.IO.FileAttributes]::ReparsePoint)
    if ($metadataRegular) {
        try { $metadata = ConvertFrom-AvmMetadataJson -Json (Read-AvmMetadataJson -Path $metadataPath) }
        catch [System.ArgumentException] { $metadataError = $_.Exception.Message }
    }
    $readmePath = Join-Path $scope.Path 'README.md'
    $primaryType = $null
    if ([System.IO.File]::Exists($readmePath) -and
        -not ([System.IO.File]::GetAttributes($readmePath) -band [System.IO.FileAttributes]::ReparsePoint)) {
        $reader = [System.IO.StreamReader]::new($readmePath)
        try { $firstLine = $reader.ReadLine() }
        finally { $reader.Dispose() }
        $typeMatch = [regex]::Match([string]$firstLine, '^.*`\[(?<type>.+)\]`.*')
        if ($typeMatch.Success) { $primaryType = $typeMatch.Groups['type'].Value }
    }
    $artifactPath = Join-Path $scope.Path 'main.json'
    $artifacts = @(Get-ChildItem -LiteralPath $scope.Path -Force | Where-Object { $_.Name -ieq 'main.json' })
    $artifactBytes = $null
    $artifactInspectable = $artifacts.Count -eq 0
    if ($artifacts.Count -eq 1 -and $artifacts[0].Name -ceq 'main.json' -and
        -not $artifacts[0].PSIsContainer -and
        -not ($artifacts[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $artifactInspectable = $true
        $artifactBytes = [System.IO.File]::ReadAllBytes($artifactPath)
    }
    $variables = if ($template['variables'] -is [System.Collections.IDictionary]) { $template['variables'] } else { @{} }
    $outputs = if ($template['outputs'] -is [System.Collections.IDictionary]) { $template['outputs'] } else { @{} }
    $definitions = if ($template['definitions'] -is [System.Collections.IDictionary]) { $template['definitions'] } else { @{} }
    $templateParameters = if ($template['parameters'] -is [System.Collections.IDictionary]) { $template['parameters'] } else { @{} }
    $identityDefinition = $null
    if ($templateParameters['managedIdentities'] -is [System.Collections.IDictionary]) {
        $reference = [regex]::Match(
            [string]$templateParameters['managedIdentities']['$ref'], '^#/definitions/(?<name>.+)$')
        if ($reference.Success) {
            $identityDefinition = $definitions[$reference.Groups['name'].Value.Replace('~1', '/').Replace('~0', '~')]
        }
    }
    return @{
        Scope                   = $scope
        Template                = $template
        Source                  = $source
        IssuePath               = $Module.Path
        Label                   = $scope.ModuleRelativePath
        Resources               = $resources
        ResourceError           = $resourceError
        Parameters              = $parameters
        TemplateParameters      = $templateParameters
        Variables               = $variables
        Outputs                 = $outputs
        Definitions             = $definitions
        IdentityDefinition      = $identityDefinition
        ParameterError          = $parameterError
        Versioned               = $versioned
        StrictObjects           = $strictObjects
        LegacyPrefix            = $legacy
        ScaffoldPrefix          = $scaffold
        PrefixName              = $prefixName
        TelemetryDescription    = $telemetryDescription
        Telemetry               = $telemetry
        Referenced              = $referenced
        MetadataPath            = $metadataPath
        Metadata                = $metadata
        MetadataError           = $metadataError
        MetadataRegular         = $metadataRegular
        ReadmePath              = $readmePath
        PrimaryType             = $primaryType
        PrimaryResources        = @($resources | Where-Object { $_.Resource['type'] -ceq $primaryType })
        ArtifactPath            = $artifactPath
        ArtifactBytes           = $artifactBytes
        ArtifactInspectable     = $artifactInspectable
        CompiledJson            = $Module.Json
        ParameterNameExceptions = @((Get-AvmBicepConfiguration)['conventionExemptions']['parameterNameExceptions'])
    }
}
