function Test-AvmBicepConventionCompiledTelemetry {
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
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Resources
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $variables = $Template['variables']
    if ($null -ne $variables -and $variables -isnot [System.Collections.IDictionary]) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.variable-shape' -Message 'Compiled variables must be an object.'))
        $variables = @{}
    }
    if ($null -eq $variables) {
        $variables = @{}
    }
    foreach ($name in $variables.psbase.Keys) {
        if ([string]$name -cnotmatch '^(?:[a-z]+[a-zA-Z0-9]+|\$fxv#[0-9]+)$' -or
            ([string]$name).Contains('-')) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.variable-name' `
                        -Message "Compiled variable '$name' must be camelCase (compiler-generated `"`$fxv#N`" is allowed)."))
        }
    }

    $versioned = [System.IO.File]::Exists((Join-Path $Scope.Path 'version.json'))
    $source = Get-AvmBicepCommentFreeSource -Source ([System.IO.File]::ReadAllText($SourcePath))
    $legacyDeclaration = [regex]::IsMatch(
        $source, "(?m)^[ \t]*var[ \t]+telemetryIdPrefix[ \t]*=[ \t]*loadJsonContent\('metadata.json',[ \t]*'telemetryIdPrefix'\)[ \t]*\r?$")
    $scaffoldDeclaration = [regex]::IsMatch(
        $source, '(?m)^[ \t]*var[ \t]+avmTelemetryIdPrefix[ \t]*=[ \t]*loadJsonContent\(''metadata.json'',[ \t]*''\$\.telemetryIdPrefix''\)[ \t]*\r?$')
    $prefixName = if ($scaffoldDeclaration -and -not $legacyDeclaration) {
        'avmTelemetryIdPrefix'
    }
    else { 'telemetryIdPrefix' }
    $description = if ($prefixName -ceq 'avmTelemetryIdPrefix') {
        'Optional. Enable/disable usage telemetry for this module.'
    }
    else {
        'Optional. Enable/Disable usage telemetry for module.'
    }
    $hasPrefixDeclaration = $legacyDeclaration -or $scaffoldDeclaration
    if ($legacyDeclaration -and $scaffoldDeclaration) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.telemetry-source' `
                    -Message 'Use exactly one metadata-backed telemetry prefix declaration.'))
    }
    if ($versioned -and $Resources.Count -gt 0) {
        $telemetryParameter = if ($Template['parameters'] -is [System.Collections.IDictionary]) {
            $Template['parameters']['enableTelemetry']
        }
        else { $null }
        if ($telemetryParameter -isnot [System.Collections.IDictionary] -or
            $telemetryParameter['type'] -cne 'bool' -or
            $telemetryParameter['defaultValue'] -isnot [bool] -or
            -not $telemetryParameter['defaultValue'] -or
            $telemetryParameter['metadata'] -isnot [System.Collections.IDictionary] -or
            $telemetryParameter['metadata']['description'] -cne $description) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.telemetry-parameter' `
                        -Message "A versioned module with resources requires enableTelemetry: bool = true and description '$description'."))
        }
    }

    $deployments = @($Resources | Where-Object { $_.Resource['type'] -ceq 'Microsoft.Resources/deployments' })
    $telemetry = [System.Collections.Generic.List[object]]::new()
    foreach ($deployment in $deployments) {
        $name = $deployment.Resource['name']
        if ($name -isnot [string]) {
            continue
        }
        $legacy = $name.Contains('46d3xbcp', [System.StringComparison]::OrdinalIgnoreCase)
        $legacyVariable = $name.Contains("variables('telemetryIdPrefix')", [System.StringComparison]::Ordinal)
        $scaffoldVariable = $name.Contains("variables('avmTelemetryIdPrefix')", [System.StringComparison]::Ordinal)
        if ($legacy -or $legacyVariable -or $scaffoldVariable) {
            $telemetry.Add($deployment)
        }
    }
    if ($versioned -and $Resources.Count -gt 0 -and $telemetry.Count -eq 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.telemetry-deployment' `
                    -Message 'A versioned module with resources requires a telemetry deployment.'))
    }

    foreach ($deployment in $telemetry) {
        $resource = $deployment.Resource
        if ($resource['condition'] -cne "[parameters('enableTelemetry')]") {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.telemetry-condition' `
                        -Message "Telemetry deployment '$($deployment.Identifier)' must be gated by enableTelemetry."))
        }
        $nested = if ($resource['properties'] -is [System.Collections.IDictionary]) {
            $resource['properties']['template']
        }
        else { $null }
        $outputs = if ($nested -is [System.Collections.IDictionary]) { $nested['outputs'] } else { $null }
        $value = if ($outputs -is [System.Collections.IDictionary] -and
            $outputs['telemetry'] -is [System.Collections.IDictionary]) {
            $outputs['telemetry']['value']
        }
        else { $null }
        if ($value -cne 'For more information, see https://aka.ms/avm/TelemetryInfo') {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.telemetry-output' `
                        -Message "Telemetry deployment '$($deployment.Identifier)' needs the standard nested telemetry output."))
        }
        $prefixReference = "variables('$prefixName')"
        $escapedPrefix = [regex]::Escape($prefixReference)
        $formatPrefix = "^\[format\('\{0\}[^']*'\s*,\s*$escapedPrefix\s*(?:,|\))"
        $concatPrefix = "^\[concat\(\s*$escapedPrefix\s*(?:,|\))"
        if ([string]$resource['name'] -cnotmatch $formatPrefix -and
            [string]$resource['name'] -cnotmatch $concatPrefix) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.telemetry-name' `
                        -Message "Telemetry deployment '$($deployment.Identifier)' must start its name with $prefixReference through format or concat."))
        }
    }

    if ($versioned -and $Resources.Count -gt 0 -and -not $hasPrefixDeclaration) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.telemetry-source' `
                    -Message 'Load the telemetry prefix from metadata.json rather than a literal in main.bicep.'))
    }
    if ($source -match '46d3xbcp\.') {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.telemetry-literal' `
                    -Message 'Do not hardcode a 46d3xbcp telemetry prefix in main.bicep.'))
    }

    if (($versioned -and $Resources.Count -gt 0) -or $hasPrefixDeclaration) {
        $metadataPath = Join-Path $Scope.Path 'metadata.json'
        $metadataPrefix = $null
        if (-not [System.IO.File]::Exists($metadataPath) -or
            ([System.IO.File]::GetAttributes($metadataPath) -band [System.IO.FileAttributes]::ReparsePoint)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $metadataPath `
                        -Code 'avm.bicep.telemetry-metadata' `
                        -Message 'A regular metadata.json is required to verify the compiled telemetry prefix.'))
        }
        else {
            $metadataFile = $null
            try {
                $metadataFile = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($metadataPath))
            }
            catch [System.Text.Json.JsonException] {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $metadataPath `
                            -Code 'avm.bicep.telemetry-metadata' `
                            -Message "metadata.json is invalid JSON: $($_.Exception.Message)"))
            }
            if ($null -ne $metadataFile) {
                try {
                    $prefixElement = [System.Text.Json.JsonElement]::new()
                    if ($metadataFile.RootElement.ValueKind -eq [System.Text.Json.JsonValueKind]::Object -and
                        $metadataFile.RootElement.TryGetProperty('telemetryIdPrefix', [ref]$prefixElement) -and
                        $prefixElement.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                        $metadataPrefix = $prefixElement.GetString()
                    }
                }
                finally {
                    $metadataFile.Dispose()
                }
                if ([string]::IsNullOrWhiteSpace($metadataPrefix)) {
                    $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $metadataPath `
                                -Code 'avm.bicep.telemetry-metadata' `
                                -Message 'metadata.json needs a nonempty telemetryIdPrefix for this compiled module.'))
                }
            }
        }

        $compiledPrefix = $variables[$prefixName]
        if ($compiledPrefix -is [string]) {
            $alias = [regex]::Match($compiledPrefix, "^\[variables\('(?<name>[^']+)'\)\]$")
            if ($alias.Success) {
                $compiledPrefix = $variables[$alias.Groups['name'].Value]
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$compiledPrefix) -or
            ($null -ne $metadataPrefix -and $compiledPrefix -cne $metadataPrefix)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.telemetry-prefix' `
                        -Message "Compiled $prefixName must equal metadata.json.telemetryIdPrefix."))
        }
    }

    $referenced = @($deployments | Where-Object {
            $properties = $_.Resource['properties']
            $nested = if ($properties -is [System.Collections.IDictionary]) { $properties['template'] } else { $null }
            $nested -is [System.Collections.IDictionary] -and
            $nested['parameters'] -is [System.Collections.IDictionary] -and
            $nested['parameters'].Contains('enableTelemetry')
        })
    if ($referenced.Count -gt 0) {
        $multiScopeParent = $Scope.IsTopLevel -and $Scope.ScopeDirectories.Count -gt 0
        $disableChildren = $Scope.ModuleType -ceq 'res' -and -not $multiScopeParent
        $expected = if ($disableChildren) {
            "[variables('enableReferencedModulesTelemetry')]"
        }
        else {
            "[parameters('enableTelemetry')]"
        }
        $variableDisabled = $variables.Contains('enableReferencedModulesTelemetry') -and
        $variables['enableReferencedModulesTelemetry'] -is [bool] -and
        -not $variables['enableReferencedModulesTelemetry']
        if ($disableChildren -and -not $variableDisabled) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.telemetry-child-variable' `
                        -Message 'Resource modules must set enableReferencedModulesTelemetry to false for referenced modules.'))
        }
        foreach ($deployment in $referenced) {
            $parameters = $deployment.Resource['properties']['parameters']
            $forwarded = if ($parameters -is [System.Collections.IDictionary] -and
                $parameters['enableTelemetry'] -is [System.Collections.IDictionary]) {
                $parameters['enableTelemetry']['value']
            }
            else { $null }
            if ($forwarded -cne $expected) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                            -Code 'avm.bicep.telemetry-child-forwarding' `
                            -Message "Referenced deployment '$($deployment.Identifier)' must pass enableTelemetry as $expected."))
            }
        }
    }

    return $issues.ToArray()
}
