function Test-AvmBicepConventionCompiledOutput {
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
    $outputs = $Template['outputs']
    if ($null -ne $outputs -and $outputs -isnot [System.Collections.IDictionary]) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.output-shape' -Message 'Compiled outputs must be an object.'))
        return $issues.ToArray()
    }
    if ($null -eq $outputs) {
        $outputs = @{}
    }
    foreach ($name in $outputs.psbase.Keys) {
        if ([string]$name -cnotmatch '^[a-z]' -or
            ([string]$name).Contains('-') -or ([string]$name).Contains('_')) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.output-name' -Message "Output '$name' must be camelCase."))
        }
        $output = $outputs[$name]
        $description = if ($output -is [System.Collections.IDictionary] -and
            $output['metadata'] -is [System.Collections.IDictionary]) {
            [string]$output['metadata']['description']
        }
        else { '' }
        if ($description -cnotmatch '(?s)^[A-Z].+\.$') {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.output-description' `
                        -Message "Output '$name' requires a complete sentence for its description."))
        }
    }

    if ($Resources.Count -gt 0 -and
        $Template['$schema'] -ceq 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#' -and
        -not $outputs.Contains('resourceGroupName')) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.output-resource-group' `
                    -Message 'A resource-group deployment with resources requires resourceGroupName output.'))
    }

    $readmePath = Join-Path $Scope.Path 'README.md'
    $primaryType = $null
    if ([System.IO.File]::Exists($readmePath) -and
        -not ([System.IO.File]::GetAttributes($readmePath) -band [System.IO.FileAttributes]::ReparsePoint)) {
        $reader = [System.IO.StreamReader]::new($readmePath)
        try {
            $firstLine = $reader.ReadLine()
        }
        finally {
            $reader.Dispose()
        }
        $typeMatch = [regex]::Match([string]$firstLine, '^.*`\[(?<type>.+)\]`.*')
        if ($typeMatch.Success) {
            $primaryType = $typeMatch.Groups['type'].Value
        }
    }
    if (-not $primaryType -and $Scope.ModuleType -ceq 'res' -and $Resources.Count -gt 0) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $readmePath `
                    -Code 'avm.bicep.primary-resource-type' `
                    -Message 'The README title must identify the primary ARM resource as `[Microsoft.Provider/type]`.'))
    }
    $primary = @($Resources | Where-Object { $_.Resource['type'] -ceq $primaryType })
    if ($primary.Count -gt 0) {
        foreach ($name in @('name', 'resourceId')) {
            if (-not $outputs.Contains($name)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                            -Code "avm.bicep.output-$name" `
                            -Message "Primary resource '$primaryType' requires an output named $name."))
            }
        }
        foreach ($resource in $primary) {
            $location = $resource.Resource['location']
            if (-not $location -or $location -ceq 'global') {
                continue
            }
            $expression = if ($outputs['location'] -is [System.Collections.IDictionary]) {
                [string]$outputs['location']['value']
            }
            else { '' }
            $referencesType = $expression.Contains(
                $primaryType, [System.StringComparison]::OrdinalIgnoreCase)
            $symbolReference = "reference\('" + [regex]::Escape($resource.Identifier) + "'(?:,|\))"
            $referencesSymbol = $resource.Identifier -and
            [regex]::IsMatch($expression, $symbolReference)
            if (-not $outputs.Contains('location') -or
                (-not $referencesType -and -not $referencesSymbol)) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                            -Code 'avm.bicep.output-location' `
                            -Message "Primary resource '$primaryType' with a location requires an output derived from that resource."))
            }
        }
    }

    $parameters = $Template['parameters']
    $definitions = $Template['definitions']
    if ($Scope.ModuleType -ceq 'res' -and
        $parameters -is [System.Collections.IDictionary] -and
        $parameters['managedIdentities'] -is [System.Collections.IDictionary]) {
        $reference = [regex]::Match(
            [string]$parameters['managedIdentities']['$ref'], '^#/definitions/(?<name>.+)$')
        if ($reference.Success -and $definitions -is [System.Collections.IDictionary]) {
            $definitionName = $reference.Groups['name'].Value.Replace('~1', '/').Replace('~0', '~')
            $definition = $definitions[$definitionName]
            if ($definition -is [System.Collections.IDictionary] -and
                $definition['properties'] -is [System.Collections.IDictionary] -and
                $definition['properties'].Contains('systemAssigned')) {
                $principal = $outputs['systemAssignedMIPrincipalId']
                if ($principal -isnot [System.Collections.IDictionary] -or
                    $principal['type'] -cne 'string' -or $principal['nullable'] -ne $true -or
                    [string]$principal['value'] -cmatch "coalesce\(.+, ''\)") {
                    $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                                -Code 'avm.bicep.output-principal-id' `
                                -Message 'A system-assigned managed identity needs nullable string systemAssignedMIPrincipalId without an empty-string fallback.'))
                }
            }
        }
    }

    return $issues.ToArray()
}
