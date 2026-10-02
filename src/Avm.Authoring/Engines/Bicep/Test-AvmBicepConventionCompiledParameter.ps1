function Test-AvmBicepConventionCompiledParameter {
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

        [bool] $StrictObjectTypes
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $parameters = $Template['parameters']
    $definitions = $Template['definitions']
    foreach ($entry in @(Get-AvmBicepConventionParameter -Template $Template)) {
        $schema = $entry.Schema
        $leaf = ($entry.Name -split '\.')[-1]
        $exceptions = @('bandwidthPercentage_SMB', 'priorityValue8021Action_Cluster', 'priorityValue8021Action_SMB')
        $excepted = $Scope.ModuleRelativePath -clike 'avm/res/azure-stack-hci/cluster/deployment-settings*' -and
        $leaf -cin $exceptions
        if (-not $excepted -and
            ($leaf -cnotmatch '^[a-z]' -or $leaf.Contains('-') -or $leaf.Contains('_'))) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.parameter-name' `
                        -Message "Parameter or UDT property '$($entry.Name)' must be camelCase."))
        }

        $metadata = $schema['metadata']
        $description = if ($metadata -is [System.Collections.IDictionary] -and
            $metadata['description'] -is [string]) { $metadata['description'] } else { '' }
        if (-not [regex]::IsMatch($description, '(?s)^[A-Z][a-zA-Z]+\. .+\.$')) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.parameter-description' `
                        -Message "Parameter or UDT property '$($entry.Name)' needs a category and a complete description (e.g. 'Optional. Description.')."))
        }
        if ($description.StartsWith('Conditional.', [System.StringComparison]::Ordinal) -and
            $description -cnotmatch '\. Required if .+') {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.parameter-condition' `
                        -Message "Conditional parameter '$($entry.Name)' must explain when it is required."))
        }

        $nullableDefinition = $false
        if ($schema.Contains('$ref')) {
            $reference = [regex]::Match([string]$schema['$ref'], '^#/definitions/(?<name>.+)$')
            $definitionName = $reference.Groups['name'].Value.Replace('~1', '/').Replace('~0', '~')
            $nullableDefinition = $definitions[$definitionName]['nullable'] -eq $true
        }
        $required = -not $schema.Contains('defaultValue') -and
        $schema['nullable'] -ne $true -and -not $nullableDefinition
        if (-not $required -and $description.StartsWith('Required.', [System.StringComparison]::Ordinal)) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.parameter-optional' `
                        -Message "Optional parameter '$($entry.Name)' must not be described as required."))
        }
        if ($required -and
            -not ($description.StartsWith('Required.', [System.StringComparison]::Ordinal) -or
                $description.StartsWith('Conditional.', [System.StringComparison]::Ordinal))) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.parameter-required' `
                        -Message "Required parameter '$($entry.Name)' needs a Required. or Conditional. description."))
        }

        $item = $schema['items']
        $object = $schema['type'] -ceq 'object'
        $arrayOfObjects = $schema['type'] -ceq 'array' -and
        $item -is [System.Collections.IDictionary] -and $item['type'] -ceq 'object'
        $typed = if ($arrayOfObjects) {
            $derived = $item['metadata'] -is [System.Collections.IDictionary] -and
            $item['metadata'].Contains('__bicep_resource_derived_type!')
            $item.Contains('properties') -or $derived
        }
        else {
            $derived = $metadata -is [System.Collections.IDictionary] -and
            $metadata.Contains('__bicep_resource_derived_type!')
            $schema.Contains('properties') -or $schema.Contains('$ref') -or $derived
        }
        if (($object -or $arrayOfObjects) -and -not $typed) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                        -Code 'avm.bicep.parameter-untyped-object' `
                        -Severity $(if ($StrictObjectTypes) { 'error' } else { 'warning' }) `
                        -Message "Object parameter '$($entry.Name)' should use an explicit UDT, object properties, or a resource-derived type."))
        }
    }

    if ($definitions -is [System.Collections.IDictionary]) {
        foreach ($name in $definitions.psbase.Keys) {
            $definition = $definitions[$name]
            if ($definition -isnot [System.Collections.IDictionary]) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                            -Code 'avm.bicep.udt-shape' -Message "UDT '$name' must be an object."))
                continue
            }
            if ($definition['type'] -ceq 'array') {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                            -Code 'avm.bicep.udt-array' -Message "UDT '$name' must not itself be an array."))
            }
            if ($definition['nullable'] -eq $true) {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                            -Code 'avm.bicep.udt-nullable' -Message "UDT '$name' must not itself be nullable."))
            }
            if ([string]$name -cnotmatch '^(.+\.)?[a-z][a-zA-Z0-9]*Type$') {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                            -Code 'avm.bicep.udt-name' -Message "UDT '$name' must be camelCase and end in Type."))
            }
        }
    }

    if ($Scope.ModuleType -ceq 'res' -and $parameters -is [System.Collections.IDictionary]) {
        foreach ($name in @('diagnosticSettings', 'roleAssignments', 'lock', 'managedIdentities', 'privateEndpoints', 'customerManagedKey')) {
            if (-not $parameters.Contains($name)) {
                continue
            }
            $schema = $parameters[$name]
            $reference = if ($schema['items'] -is [System.Collections.IDictionary]) {
                $schema['items']['$ref']
            }
            else { $schema['$ref'] }
            if ([string]$reference -cnotmatch '^#/definitions/.+$') {
                $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                            -Code 'avm.bicep.parameter-udt-ref' `
                            -Message "Resource parameter '$name' must use a compiled UDT reference."))
            }
        }
    }
    if ($parameters -is [System.Collections.IDictionary] -and
        $parameters.Contains('tags') -and $parameters['tags']['nullable'] -ne $true) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Root -Path $SourcePath `
                    -Code 'avm.bicep.parameter-tags-nullable' -Message 'The tags parameter must be nullable.'))
    }

    return $issues.ToArray()
}
