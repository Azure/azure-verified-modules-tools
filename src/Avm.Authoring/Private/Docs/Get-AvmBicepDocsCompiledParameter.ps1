function Get-AvmBicepDocsCompiledParameter {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, object]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [string] $SourcePath
    )

    Set-StrictMode -Version 3.0
    $details = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::Ordinal)
    $parameters = $Template['parameters']
    if ($parameters -isnot [System.Collections.IDictionary]) {
        return $details
    }
    $definitions = $Template['definitions']
    $pending = [System.Collections.Generic.Stack[object]]::new()
    foreach ($name in $parameters.psbase.Keys) {
        $pending.Push([pscustomobject]@{
                Path           = [string]$name
                Schema         = $parameters[$name]
                References     = [string[]]@()
                ReferenceDepth = 0
                FromArrayItem  = $false
            })
    }

    while ($pending.Count -gt 0) {
        $entry = $pending.Pop()
        $schema = $entry.Schema
        if ($schema -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Compiled Bicep parameter '$($entry.Path)' must be a JSON object in '$SourcePath'.")
        }
        if (-not $details.ContainsKey($entry.Path)) {
            $required = -not $schema.Contains('defaultValue') -and $schema['nullable'] -ne $true
            $details[$entry.Path] = [pscustomobject]@{
                Type                       = $null
                LegacyType                 = $null
                DocumentChildren           = $true
                Required                   = $required
                AllowedValues              = @()
                AllowedValuesFromReference = $false
                MinValue                   = $null
                MaxValue                   = $null
                Description                = $null
                Example                    = $null
                IsResourceDerived          = $false
                HasDiscriminator           = $false
                VariantOrder               = @()
            }
        }
        $current = $details[$entry.Path]
        if ($null -eq $current.Type) {
            if ($schema.Contains('type')) {
                $current.Type = [string]$schema['type']
            }
            elseif (-not $schema.Contains('$ref')) {
                $current.Type = ''
            }
        }
        if ($schema.Contains('minValue') -and $null -eq $current.MinValue) {
            $current.MinValue = $schema['minValue']
        }
        if ($schema.Contains('maxValue') -and $null -eq $current.MaxValue) {
            $current.MaxValue = $schema['maxValue']
        }
        if ($schema['type'] -eq 'secureObject' -and $entry.ReferenceDepth -eq 0) {
            $current.DocumentChildren = $false
        }
        if ((-not $entry.FromArrayItem -or $entry.ReferenceDepth -gt 0) -and
            $schema['allowedValues'] -is [array] -and
            $schema['allowedValues'].Count -gt 0 -and
            $current.AllowedValues.Count -eq 0) {
            $values = @($schema['allowedValues'])
            $scalar = @($values | Where-Object {
                    $_ -is [string] -or $_ -is [System.ValueType]
                }).Count -eq $values.Count
            if ($scalar) {
                $current.AllowedValues = [object[]]@($values | Sort-Object -Culture 'en-US')
            }
            else {
                $current.AllowedValues = [object[]]$values
            }
            $current.AllowedValuesFromReference = $entry.ReferenceDepth -gt 0
        }
        if ($schema['metadata'] -is [System.Collections.IDictionary]) {
            $metadata = $schema['metadata']
            if ($metadata.Contains('__bicep_resource_derived_type!')) {
                $current.IsResourceDerived = $true
            }
            if ($null -eq $current.Description -and $metadata['description'] -is [string]) {
                $current.Description = $metadata['description']
            }
            if ($null -eq $current.Example -and $metadata.Contains('example')) {
                $example = $metadata['example']
                $normalizedExample = $null
                if ($example -is [string]) {
                    $normalizedExample = $example
                }
                elseif ($example -is [array] -and
                    @($example | Where-Object { $_ -isnot [string] }).Count -eq 0) {
                    $normalizedExample = [string[]]$example
                }
                elseif ($example -is [System.Collections.IDictionary]) {
                    $normalizedExample = $example
                }
                else {
                    throw [AvmConfigurationException]::new(
                        "Compiled Bicep example for '$($entry.Path)' must be a string, an object, or an array of strings in '$SourcePath'.")
                }
                if (-not $entry.FromArrayItem) {
                    $current.Example = $normalizedExample
                }
            }
        }
        if ($schema['type'] -eq 'array' -and $schema['prefixItems'] -is [array] -and
            $schema['items'] -is [bool] -and -not $schema['items']) {
            $current.DocumentChildren = $false
        }
        if ($current.IsResourceDerived -and -not $schema.Contains('$ref') -and
            $schema['properties'] -isnot [System.Collections.IDictionary] -and
            $schema['additionalProperties'] -isnot [System.Collections.IDictionary] -and
            $schema['items'] -isnot [System.Collections.IDictionary] -and
            $schema['discriminator'] -isnot [System.Collections.IDictionary]) {
            $current.DocumentChildren = $false
        }

        if ($schema.Contains('$ref')) {
            $reference = [string]$schema['$ref']
            if ($reference -cnotmatch '^#/definitions/(.+)$') {
                throw [AvmConfigurationException]::new(
                    "Compiled Bicep parameter '$($entry.Path)' has an invalid definition reference '$reference' in '$SourcePath'.")
            }
            $definitionName = $matches[1].Replace('~1', '/').Replace('~0', '~')
            if ($entry.References -ccontains $definitionName) {
                continue
            }
            if ($definitions -isnot [System.Collections.IDictionary] -or
                -not $definitions.Contains($definitionName) -or
                $definitions[$definitionName] -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new(
                    "Compiled Bicep parameter '$($entry.Path)' references missing definition '$definitionName' in '$SourcePath'.")
            }
            if ($entry.ReferenceDepth -eq 0 -and
                $definitions[$definitionName].Contains('$ref') -and
                -not $definitions[$definitionName].Contains('type')) {
                $current.DocumentChildren = $false
                if ($null -eq $current.Type) {
                    $current.LegacyType = ''
                }
            }
            $pending.Push([pscustomobject]@{
                    Path           = $entry.Path
                    Schema         = $definitions[$definitionName]
                    References     = [string[]]@($entry.References + $definitionName)
                    ReferenceDepth = $entry.ReferenceDepth + 1
                    FromArrayItem  = $entry.FromArrayItem
                })
            continue
        }

        $discriminator = $schema['discriminator']
        if ($discriminator -is [System.Collections.IDictionary]) {
            $current.HasDiscriminator = $true
            $propertyName = [string]$discriminator['propertyName']
            $mapping = $discriminator['mapping']
            if ([string]::IsNullOrWhiteSpace($propertyName) -or
                $mapping -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new(
                    "Compiled Bicep discriminator for '$($entry.Path)' is invalid in '$SourcePath'.")
            }
            $current.VariantOrder = [string[]]@($mapping.psbase.Keys)
            foreach ($value in $mapping.psbase.Keys) {
                $caseSchema = $mapping[$value]
                if ($caseSchema -is [string]) {
                    $caseSchema = @{ '$ref' = $caseSchema }
                }
                if ($caseSchema -isnot [System.Collections.IDictionary]) {
                    throw [AvmConfigurationException]::new(
                        "Compiled Bicep discriminator case '$value' for '$($entry.Path)' is invalid in '$SourcePath'.")
                }
                $pending.Push([pscustomobject]@{
                        Path           = "$($entry.Path).$propertyName-$value"
                        Schema         = $caseSchema
                        References     = $entry.References
                        ReferenceDepth = 0
                        FromArrayItem  = $false
                    })
            }
        }

        $properties = $schema['properties']
        if ($properties -is [System.Collections.IDictionary]) {
            foreach ($name in $properties.psbase.Keys) {
                $pending.Push([pscustomobject]@{
                        Path           = "$($entry.Path).$name"
                        Schema         = $properties[$name]
                        References     = $entry.References
                        ReferenceDepth = 0
                        FromArrayItem  = $false
                    })
            }
        }
        if ($schema['additionalProperties'] -is [System.Collections.IDictionary]) {
            $pending.Push([pscustomobject]@{
                    Path           = "$($entry.Path).>Any_other_property<"
                    Schema         = $schema['additionalProperties']
                    References     = $entry.References
                    ReferenceDepth = 0
                    FromArrayItem  = $false
                })
        }
        if ($schema['items'] -is [System.Collections.IDictionary]) {
            $pending.Push([pscustomobject]@{
                    Path           = $entry.Path
                    Schema         = $schema['items']
                    References     = $entry.References
                    ReferenceDepth = $entry.ReferenceDepth
                    FromArrayItem  = $true
                })
        }
    }

    return $details
}
