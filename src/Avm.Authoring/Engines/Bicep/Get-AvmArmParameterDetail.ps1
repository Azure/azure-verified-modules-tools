function Get-AvmArmParameterDetail {
    <#
    .SYNOPSIS
        Walk a compiled ARM template's top-level parameters and return
        rich per-parameter records suitable for the per-parameter
        '### Parameter:' detail blocks. Inline object children
        (type=object + properties.*) are walked recursively and
        attached as Children.

    .DESCRIPTION
        Internal helper used by the Bicep docs engine. Builds on
        Get-AvmArmParameter (which validates the category prefix and
        folds description newlines) by also pulling the extra fields
        needed for the README detail block per parameter:
          - HasDefault / Default        ('defaultValue')
          - HasAllowedValues / AllowedValues  ('allowedValues')
          - HasMinValue / MinValue      ('minValue')
          - HasMaxValue / MaxValue      ('maxValue')
          - HasExample / ExampleLines + ExampleIsSingleLine
            (metadata.example)
          - Children                    (pscustomobject[])

        Slice 4b scope: each top-level parameter whose type='object'
        and that exposes a 'properties' object is walked recursively
        into those children. Each nested record has the same shape as
        a top-level record (so the recursion can keep going), uses a
        dotted Name ('parent.child'), inherits the top-level
        Category, derives IsRequired from the absence of
        'defaultValue' and a falsy 'nullable' flag, and folds its
        description newlines the same way as top-level. The AVM
        '<Category>. ' category-prefix rule does NOT apply to nested
        descriptions; they are emitted verbatim. The recursive walk
        into '$ref', 'items', and 'discriminator.mapping' lands in
        slices 4c\u20134e.

        Strict-mode safe via the '.PSObject.Properties[<name>]'
        indexer for every PSObject lookup.

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject) produced by
        Convert-AvmBicepToArm.

    .OUTPUTS
        [pscustomobject[]] with properties (same shape for top-level
        and nested records):
          - Name                  (string)  dotted path for nested, e.g. 'tags.environment'
          - Type                  (string)  ARM 'type' field; '' when absent
          - Category              (string)  inherited from top-level for nested
          - Description           (string)  newline-folded; '' when missing on nested
          - IsRequired            (bool)
          - HasDefault            (bool)
          - Default               (string)  formatted for markdown (no surrounding backticks)
          - HasAllowedValues      (bool)
          - AllowedValues         (string)  formatted for markdown (no surrounding backticks)
          - HasMinValue           (bool)
          - MinValue              (object)  raw value
          - HasMaxValue           (bool)
          - MaxValue              (object)  raw value
          - HasExample            (bool)
          - ExampleLines          (string[]) one entry per line; empty when HasExample = $false
          - ExampleIsSingleLine   (bool)
          - Children              (pscustomobject[])  nested records; empty when none

    .NOTES
        Propagates [AvmConfigurationException] from Get-AvmArmParameter
        when any top-level parameter is missing its category prefix.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        $Arm
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $base = Get-AvmArmParameter -Arm $Arm
    $entries = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($base.Count -eq 0) {
        return , $entries.ToArray()
    }

    $parametersProp = $Arm.PSObject.Properties['parameters']
    foreach ($b in $base) {
        $rawProp = $parametersProp.Value.PSObject.Properties[$b.Name]
        $raw = $rawProp.Value

        $record = Get-AvmArmParameterDetailRecord `
            -Name        $b.Name `
            -Raw         $raw `
            -Type        $b.Type `
            -Category    $b.Category `
            -Description $b.Description `
            -IsRequired  $b.IsRequired

        $entries.Add($record)
    }

    return , $entries.ToArray()
}

function Get-AvmArmParameterDetailRecord {
    <#
    .SYNOPSIS
        Build a single per-parameter detail record (and recurse into
        inline 'properties.*' children for object-typed entries).

    .DESCRIPTION
        Internal helper used by Get-AvmArmParameterDetail. Reads the
        scalar-detail fields (defaultValue, allowedValues, minValue,
        maxValue, metadata.example) from the raw ARM parameter
        definition and, when type='object' with a 'properties'
        object, recursively walks each nested property to build a
        Children array. Nested records inherit the supplied Category
        and derive IsRequired from the absence of 'defaultValue' AND
        a falsy 'nullable' flag, matching the common AVM authoring
        convention where nested optionality is signalled via
        'nullable: true' rather than the parent's 'required' array
        (which ARM templates rarely populate).

        Strict-mode safe via the '.PSObject.Properties[<name>]'
        indexer for every PSObject lookup. Inline object recursion
        cannot cycle (the JSON shape is a tree), so no depth or
        cycle guard is required at this layer; the guards land with
        the '$ref' walker in slice 4c.

    .PARAMETER Name
        Dotted name of the record being built ('parent.child' for
        nested records, plain name for top-level).

    .PARAMETER Raw
        The raw ARM parameter / property definition (PSCustomObject)
        carrying type, defaultValue, allowedValues, minValue, maxValue,
        metadata, properties, nullable, ...

    .PARAMETER Type
        ARM 'type' for this record (already extracted by the caller).

    .PARAMETER Category
        Category tag for this record. Top-level callers pass the
        validated AVM category; nested records inherit from their
        top-level ancestor.

    .PARAMETER Description
        Newline-folded description text. Top-level callers pass the
        category-stripped folded description; nested callers compute
        the folded value before invoking this helper.

    .PARAMETER IsRequired
        Whether the record is required. Top-level callers derive this
        from the absence of 'defaultValue'; nested callers apply the
        '!defaultValue AND !nullable' rule before invoking this
        helper.

    .OUTPUTS
        [pscustomobject] with the same shape returned by
        Get-AvmArmParameterDetail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        $Raw,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Type,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Category,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Description,

        [Parameter(Mandatory)]
        [bool] $IsRequired
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $hasDefault = $false; $defaultText = ''
    $defaultProp = $Raw.PSObject.Properties['defaultValue']
    if ($null -ne $defaultProp) {
        $hasDefault = $true
        $defaultText = Format-AvmArmScalarForMarkdown -Value $defaultProp.Value
    }

    $hasAllowed = $false; $allowedText = ''
    $allowedProp = $Raw.PSObject.Properties['allowedValues']
    if ($null -ne $allowedProp -and $null -ne $allowedProp.Value) {
        $hasAllowed = $true
        $allowedText = Format-AvmArmAllowedValuesForMarkdown -Values $allowedProp.Value
    }

    $hasMin = $false; $minValue = $null
    $minProp = $Raw.PSObject.Properties['minValue']
    if ($null -ne $minProp) { $hasMin = $true; $minValue = $minProp.Value }

    $hasMax = $false; $maxValue = $null
    $maxProp = $Raw.PSObject.Properties['maxValue']
    if ($null -ne $maxProp) { $hasMax = $true; $maxValue = $maxProp.Value }

    $hasExample = $false; $exampleLines = @(); $exampleSingle = $false
    $metaProp = $Raw.PSObject.Properties['metadata']
    if ($null -ne $metaProp -and $null -ne $metaProp.Value) {
        $exProp = $metaProp.Value.PSObject.Properties['example']
        if ($null -ne $exProp -and $null -ne $exProp.Value -and -not [string]::IsNullOrWhiteSpace([string]$exProp.Value)) {
            $hasExample = $true
            $normalised = ([string]$exProp.Value) -replace "`r`n", "`n"
            $split = $normalised -split "`n"
            $exampleLines = @($split | Where-Object { $_ -ne '' -or $exampleSingle })
            if ($exampleLines.Count -eq 0) { $exampleLines = @($normalised) }
            $exampleSingle = ($exampleLines.Count -eq 1)
        }
    }

    $children = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($Type -eq 'object') {
        $propsProp = $Raw.PSObject.Properties['properties']
        if ($null -ne $propsProp -and $null -ne $propsProp.Value) {
            foreach ($childProp in $propsProp.Value.PSObject.Properties) {
                $childName = '{0}.{1}' -f $Name, [string]$childProp.Name
                $childRaw = $childProp.Value
                if ($null -eq $childRaw) { continue }

                $childTypeProp = $childRaw.PSObject.Properties['type']
                $childType = if ($null -ne $childTypeProp) { [string]$childTypeProp.Value } else { '' }

                $childDescription = ''
                $childMetaProp = $childRaw.PSObject.Properties['metadata']
                if ($null -ne $childMetaProp -and $null -ne $childMetaProp.Value) {
                    $childDescProp = $childMetaProp.Value.PSObject.Properties['description']
                    if ($null -ne $childDescProp -and $null -ne $childDescProp.Value) {
                        $childDescRaw = [string]$childDescProp.Value
                        $childDescription = $childDescRaw.Replace("`n- ", '<li>').Replace("`r`n", '<p>').Replace("`n", '<p>')
                    }
                }

                $childHasDefault = $null -ne $childRaw.PSObject.Properties['defaultValue']
                $childNullable = $false
                $childNullableProp = $childRaw.PSObject.Properties['nullable']
                if ($null -ne $childNullableProp -and $null -ne $childNullableProp.Value) {
                    $childNullable = [bool]$childNullableProp.Value
                }
                $childIsRequired = -not ($childHasDefault -or $childNullable)

                $childRecord = Get-AvmArmParameterDetailRecord `
                    -Name        $childName `
                    -Raw         $childRaw `
                    -Type        $childType `
                    -Category    $Category `
                    -Description $childDescription `
                    -IsRequired  $childIsRequired

                $children.Add($childRecord)
            }
        }
    }

    return [pscustomobject][ordered]@{
        Name                = $Name
        Type                = $Type
        Category            = $Category
        Description         = $Description
        IsRequired          = $IsRequired
        HasDefault          = $hasDefault
        Default             = $defaultText
        HasAllowedValues    = $hasAllowed
        AllowedValues       = $allowedText
        HasMinValue         = $hasMin
        MinValue            = $minValue
        HasMaxValue         = $hasMax
        MaxValue            = $maxValue
        HasExample          = $hasExample
        ExampleLines        = $exampleLines
        ExampleIsSingleLine = $exampleSingle
        Children            = $children.ToArray()
    }
}

function Format-AvmArmScalarForMarkdown {
    <#
    .SYNOPSIS
        Render a scalar / array / object value as a single-line
        markdown-safe string (no surrounding backticks).

    .DESCRIPTION
        Used by Get-AvmArmParameterDetail for 'defaultValue'. Strings
        come back as their plain text (the caller wraps in backticks);
        booleans as 'true'/'false'; numbers as their invariant string
        form; complex values (array / object / hashtable) as
        compressed JSON. $null becomes the literal 'null'. This is the
        4a baseline; slice 4b+ may refine complex-value rendering if
        the legacy comparison diverges visibly.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    Set-StrictMode -Version 3.0
    if ($null -eq $Value) { return 'null' }

    if ($Value -is [bool]) {
        return ([bool]$Value).ToString().ToLowerInvariant()
    }

    if ($Value -is [string]) { return [string]$Value }

    if ($Value -is [System.Collections.IEnumerable] -or $Value -is [pscustomobject] -or $Value -is [hashtable]) {
        return ($Value | ConvertTo-Json -Depth 99 -Compress)
    }

    return [string]$Value
}

function Format-AvmArmAllowedValuesForMarkdown {
    <#
    .SYNOPSIS
        Render an ARM 'allowedValues' array as a markdown-safe string
        (no surrounding backticks).

    .DESCRIPTION
        Mirrors the legacy Set-DefinitionSection convention: scalar
        values become a Bicep-style array literal
        ([ 'a', 'b', 'c' ] for strings; [ 1, 2, 3 ] for numbers).
        Complex values (rare for allowedValues) are emitted as
        compressed JSON to avoid lossy formatting.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Values
    )

    Set-StrictMode -Version 3.0

    $items = @($Values)
    if ($items.Count -eq 0) { return '[]' }

    $allScalar = $true
    foreach ($v in $items) {
        if ($v -is [pscustomobject] -or $v -is [hashtable] -or
            ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string]))) {
            $allScalar = $false; break
        }
    }

    if (-not $allScalar) {
        return ($items | ConvertTo-Json -Depth 99 -Compress)
    }

    $rendered = foreach ($v in $items) {
        if ($v -is [string]) { "'$v'" }
        elseif ($v -is [bool]) { ([bool]$v).ToString().ToLowerInvariant() }
        else { [string]$v }
    }
    return '[ ' + ($rendered -join ', ') + ' ]'
}
