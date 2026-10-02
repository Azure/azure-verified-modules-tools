function Get-AvmBicepConventionParameter {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $parameters = $Template['parameters']
    if ($null -eq $parameters) {
        return @()
    }
    if ($parameters -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new('Compiled Bicep parameters must be an object.')
    }

    $definitions = $Template['definitions']
    $entries = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.Stack[object]]::new()
    foreach ($name in $parameters.psbase.Keys) {
        $pending.Push([pscustomobject]@{
                Name       = [string]$name
                Schema     = $parameters[$name]
                Emit       = $true
                References = [string[]]@()
            })
    }

    while ($pending.Count -gt 0) {
        $entry = $pending.Pop()
        $schema = $entry.Schema
        if ($schema -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Compiled Bicep parameter '$($entry.Name)' must be an object.")
        }
        if ($entry.Emit) {
            $entries.Add([pscustomobject]@{ Name = $entry.Name; Schema = $schema })
        }

        if ($schema.Contains('$ref')) {
            $reference = [regex]::Match([string]$schema['$ref'], '^#/definitions/(?<name>.+)$')
            if (-not $reference.Success) {
                throw [AvmConfigurationException]::new(
                    "Compiled Bicep parameter '$($entry.Name)' has an invalid definition reference.")
            }
            $definitionName = $reference.Groups['name'].Value.Replace('~1', '/').Replace('~0', '~')
            if ($entry.References -ccontains $definitionName) {
                continue
            }
            if ($definitions -isnot [System.Collections.IDictionary] -or
                -not $definitions.Contains($definitionName) -or
                $definitions[$definitionName] -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new(
                    "Compiled Bicep parameter '$($entry.Name)' references missing definition '$definitionName'.")
            }
            $pending.Push([pscustomobject]@{
                    Name       = $entry.Name
                    Schema     = $definitions[$definitionName]
                    Emit       = $false
                    References = [string[]]@($entry.References + $definitionName)
                })
        }

        if ($schema['items'] -is [System.Collections.IDictionary]) {
            $pending.Push([pscustomobject]@{
                    Name       = $entry.Name
                    Schema     = $schema['items']
                    Emit       = $false
                    References = $entry.References
                })
        }
        if ($schema['properties'] -is [System.Collections.IDictionary]) {
            foreach ($name in $schema['properties'].psbase.Keys) {
                $pending.Push([pscustomobject]@{
                        Name       = "$($entry.Name).$name"
                        Schema     = $schema['properties'][$name]
                        Emit       = $true
                        References = $entry.References
                    })
            }
        }
        if ($schema['discriminator'] -is [System.Collections.IDictionary] -and
            $schema['discriminator']['mapping'] -is [System.Collections.IDictionary]) {
            foreach ($name in $schema['discriminator']['mapping'].psbase.Keys) {
                $variant = $schema['discriminator']['mapping'][$name]
                if ($variant -is [string]) {
                    $variant = @{ '$ref' = $variant }
                }
                $pending.Push([pscustomobject]@{
                        Name       = "$($entry.Name).$name"
                        Schema     = $variant
                        Emit       = $false
                        References = $entry.References
                    })
            }
        }
    }

    return $entries.ToArray()
}
