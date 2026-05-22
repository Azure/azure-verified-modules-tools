$script:AvmMaxRefDepth = 32

function Get-AvmArmParameterDetail {
    <#
    .SYNOPSIS
        Walk a compiled ARM template's top-level parameters and return
        rich per-parameter records suitable for the per-parameter
        '### Parameter:' detail blocks. Inline object children
        (type=object + properties.*) and array element shapes
        (type=array + items) are walked recursively and attached as
        Children. '$ref' values pointing at '#/definitions/<name>'
        entries are resolved through the template's 'definitions'
        bag, with cycle detection and a depth cap.

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

        Slice 4b added inline-object recursion: each top-level
        parameter whose type='object' and that exposes a 'properties'
        object is walked recursively into those children. Each nested
        record has the same shape as a top-level record (so the
        recursion can keep going), uses a dotted Name
        ('parent.child'), inherits the top-level Category, derives
        IsRequired from the absence of 'defaultValue' and a falsy
        'nullable' flag, and folds its description newlines the same
        way as top-level. The AVM '<Category>. ' category-prefix rule
        does NOT apply to nested descriptions; they are emitted
        verbatim.

        Slice 4c adds '$ref' resolution. Any raw record carrying a
        '$ref' of the form '#/definitions/<name>' is resolved against
        the template's 'definitions' bag: the referenced definition
        is deep-cloned and the local raw's fields are overlaid on top
        (local wins, with a one-level deep merge on 'metadata'). The
        merged record drives type detection and the recursive child
        walk. A per-branch ref stack catches cycles (self-recursive
        or indirect A->B->A); a hard depth cap of
        $script:AvmMaxRefDepth (32) bounds runaway chains. On either
        bailout the record is still emitted, but with an empty
        Children array. Malformed '$ref' values and references to
        missing definitions both raise [AvmConfigurationException].

        Slice 4d adds array recursion: when type='array' and 'items'
        is present, the helper emits exactly one synthetic child
        whose Name is the parent name with '[*]' appended (e.g.
        'tags[*]'), matching the AVM published-module README
        convention. The synthetic child's IsRequired is always
        $true because array elements have no defaultValue / nullable
        concept (those live at the array parameter declaration site,
        not at the item shape). The recursive call walks the items
        shape exactly like any other record, so 'items.type=object'
        composes naturally into 'parent[*].field1' / 'parent[*].field2'
        children via the existing object branch, 'items.type=array'
        produces 'parent[*][*]', and 'items.$ref' is resolved through
        the same Resolve-AvmArmRefDefinition plumbing (including
        cycle and depth bailouts). Discriminator dispatch and
        UDT-only constraints land in slices 4e-4f.

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
            -IsRequired  $b.IsRequired `
            -Arm         $Arm `
            -RefStack    @()

        $entries.Add($record)
    }

    return , $entries.ToArray()
}

function Get-AvmArmParameterDetailRecord {
    <#
    .SYNOPSIS
        Build a single per-parameter detail record (and recurse into
        inline 'properties.*' children for object-typed entries, or
        the synthetic '[*]' element for array-typed entries),
        resolving '$ref' through the template's 'definitions' bag
        along the way.

    .DESCRIPTION
        Internal helper used by Get-AvmArmParameterDetail. At entry
        the raw record is resolved through Resolve-AvmArmRefDefinition
        so '$ref' values are followed into the template's
        'definitions' bag; the referenced definition is deep-cloned
        and the local raw's fields are overlaid on top (local wins,
        with a one-level deep merge on 'metadata'). All scalar-detail
        extraction (defaultValue, allowedValues, minValue, maxValue,
        metadata.example) reads from the merged record, and Type is
        re-derived from the merged 'type' (so a top-level '$ref' param
        whose local raw carries no 'type' still reports the resolved
        type accurately).

        When type='object' with a 'properties' object, each nested
        property is walked recursively. Nested records inherit the
        supplied Category and derive IsRequired from the absence of
        'defaultValue' AND a falsy 'nullable' flag on the LOCAL child
        raw (defaultValue / nullable always live at the parameter or
        property declaration site, never inside a type definition).
        Nested child descriptions fall back to the referenced
        definition's 'metadata.description' when the local child raw
        has none.

        When type='array' with an 'items' shape, the helper emits a
        single synthetic child whose Name is the parent name with
        '[*]' appended (e.g. 'tags[*]'). The synthetic child's
        IsRequired is hard-coded $true because array elements have
        no defaultValue / nullable concept at the items site. The
        recursive call walks the items shape like any other record,
        so 'items.type=object' composes naturally into
        'parent[*].field1' / 'parent[*].field2' children, and an
        'items.$ref' is resolved through the same cycle / depth
        plumbing.

        Cycle and depth protection (slice 4c): a per-branch ref stack
        ($RefStack) carries the names of definitions resolved on the
        path from the top-level walker down to the current record.
        Resolve-AvmArmRefDefinition flags re-entry as a cycle; the
        children walk also stops when $RefStack.Count would reach
        $script:AvmMaxRefDepth (32). Both bailouts emit the record
        with an empty Children array but otherwise preserve scalar
        fields. The cycle case also peeks at the cycled-to
        definition's 'type' so the leaf record still reports a
        useful Type rather than ''.

        Strict-mode safe via the '.PSObject.Properties[<name>]'
        indexer for every PSObject lookup.

    .PARAMETER Name
        Dotted name of the record being built ('parent.child' for
        nested records, plain name for top-level).

    .PARAMETER Raw
        The raw ARM parameter / property definition (PSCustomObject)
        carrying type, defaultValue, allowedValues, minValue, maxValue,
        metadata, properties, nullable, $ref, ...

    .PARAMETER Type
        ARM 'type' for this record as known to the caller. Treated as
        a fallback - the helper re-derives Type from the resolved
        record's 'type' property whenever one is present, which is
        the common case.

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

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject). Carries the
        'definitions' bag used to resolve '$ref' values.

    .PARAMETER RefStack
        Names of '$ref' definitions resolved on the path from the
        top-level walker down to this record. Top-level callers pass
        an empty array. The helper pushes the resolved ref name (if
        any) before recursing into children, so siblings see the
        parent stack and cousins see independent branches.

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
        [bool] $IsRequired,

        [Parameter(Mandatory)]
        $Arm,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $RefStack
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $resolved = Resolve-AvmArmRefDefinition -Raw $Raw -Arm $Arm -RefStack $RefStack
    $effectiveRaw = $Raw
    $effectiveType = $Type
    $nextRefStack = $RefStack
    $isCycleOrDepth = $false

    if ($resolved.HasRef) {
        if ($resolved.IsCycle) {
            $isCycleOrDepth = $true
            $defsProp = $Arm.PSObject.Properties['definitions']
            if ($null -ne $defsProp -and $null -ne $defsProp.Value) {
                $cycleDefProp = $defsProp.Value.PSObject.Properties[$resolved.RefName]
                if ($null -ne $cycleDefProp -and $null -ne $cycleDefProp.Value) {
                    $cycleTypeProp = $cycleDefProp.Value.PSObject.Properties['type']
                    if ($null -ne $cycleTypeProp -and $null -ne $cycleTypeProp.Value) {
                        $effectiveType = [string]$cycleTypeProp.Value
                    }
                }
            }
        }
        else {
            $effectiveRaw = $resolved.Resolved
            $nextRefStack = @($RefStack) + $resolved.RefName
        }
    }

    if (-not $isCycleOrDepth) {
        $effectiveTypeProp = $effectiveRaw.PSObject.Properties['type']
        if ($null -ne $effectiveTypeProp -and $null -ne $effectiveTypeProp.Value) {
            $effectiveType = [string]$effectiveTypeProp.Value
        }
    }

    $hasDefault = $false; $defaultText = ''
    $defaultProp = $effectiveRaw.PSObject.Properties['defaultValue']
    if ($null -ne $defaultProp) {
        $hasDefault = $true
        $defaultText = Format-AvmArmScalarForMarkdown -Value $defaultProp.Value
    }

    $hasAllowed = $false; $allowedText = ''
    $allowedProp = $effectiveRaw.PSObject.Properties['allowedValues']
    if ($null -ne $allowedProp -and $null -ne $allowedProp.Value) {
        $hasAllowed = $true
        $allowedText = Format-AvmArmAllowedValuesForMarkdown -Values $allowedProp.Value
    }

    $hasMin = $false; $minValue = $null
    $minProp = $effectiveRaw.PSObject.Properties['minValue']
    if ($null -ne $minProp) { $hasMin = $true; $minValue = $minProp.Value }

    $hasMax = $false; $maxValue = $null
    $maxProp = $effectiveRaw.PSObject.Properties['maxValue']
    if ($null -ne $maxProp) { $hasMax = $true; $maxValue = $maxProp.Value }

    $hasExample = $false; $exampleLines = @(); $exampleSingle = $false
    $metaProp = $effectiveRaw.PSObject.Properties['metadata']
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
    if (-not $isCycleOrDepth -and $nextRefStack.Count -lt $script:AvmMaxRefDepth) {
        if ($effectiveType -eq 'object') {
            $propsProp = $effectiveRaw.PSObject.Properties['properties']
            if ($null -ne $propsProp -and $null -ne $propsProp.Value) {
                foreach ($childProp in $propsProp.Value.PSObject.Properties) {
                    $childName = '{0}.{1}' -f $Name, [string]$childProp.Name
                    $childRaw = $childProp.Value
                    if ($null -eq $childRaw) { continue }

                    $childDescription = Get-AvmArmChildDescription -ChildRaw $childRaw -Arm $Arm -RefStack $nextRefStack

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
                        -Type        '' `
                        -Category    $Category `
                        -Description $childDescription `
                        -IsRequired  $childIsRequired `
                        -Arm         $Arm `
                        -RefStack    $nextRefStack

                    $children.Add($childRecord)
                }
            }
        }
        elseif ($effectiveType -eq 'array') {
            $itemsProp = $effectiveRaw.PSObject.Properties['items']
            if ($null -ne $itemsProp -and $null -ne $itemsProp.Value) {
                $childName = '{0}[*]' -f $Name
                $childRaw = $itemsProp.Value
                $childDescription = Get-AvmArmChildDescription -ChildRaw $childRaw -Arm $Arm -RefStack $nextRefStack

                $childRecord = Get-AvmArmParameterDetailRecord `
                    -Name        $childName `
                    -Raw         $childRaw `
                    -Type        '' `
                    -Category    $Category `
                    -Description $childDescription `
                    -IsRequired  $true `
                    -Arm         $Arm `
                    -RefStack    $nextRefStack

                $children.Add($childRecord)
            }
        }
    }

    return [pscustomobject][ordered]@{
        Name                = $Name
        Type                = $effectiveType
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

function Get-AvmArmChildDescription {
    <#
    .SYNOPSIS
        Extract a newline-folded description for a nested child raw
        (object property value or array items value), with a peek
        through a child-level '$ref' as a fallback.

    .DESCRIPTION
        Internal helper used by Get-AvmArmParameterDetailRecord when
        walking inline object properties (slice 4b) and array items
        (slice 4d). Reads $childRaw.metadata.description, folds
        newlines using the standard rules (-`n- ' -> '<li>',
        '\r\n' and '\n' -> '<p>'), and returns the result. When the
        child raw has no local metadata.description but does carry a
        '$ref', the referenced definition's metadata.description is
        peeked through Resolve-AvmArmRefDefinition (respecting the
        ref stack so we don't peek through a cycle) and folded
        the same way. Returns '' when neither side carries a
        description.

        Strict-mode safe via the '.PSObject.Properties[<name>]'
        indexer for every PSObject lookup.

    .PARAMETER ChildRaw
        The nested child's raw definition (PSCustomObject), drawn
        either from $properties.<name> (object branch) or from
        $items (array branch).

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject) carrying the
        'definitions' bag. Forwarded to Resolve-AvmArmRefDefinition
        for the peek fallback.

    .PARAMETER RefStack
        Names of '$ref' definitions already on the path from the
        top-level walker down to this child. Forwarded to
        Resolve-AvmArmRefDefinition so the peek doesn't recurse
        through a cycle.

    .OUTPUTS
        [string] - newline-folded description, '' when absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $ChildRaw,

        [Parameter(Mandatory)]
        $Arm,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $RefStack
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($null -eq $ChildRaw) { return '' }

    $description = ''
    $metaProp = $ChildRaw.PSObject.Properties['metadata']
    if ($null -ne $metaProp -and $null -ne $metaProp.Value) {
        $descProp = $metaProp.Value.PSObject.Properties['description']
        if ($null -ne $descProp -and $null -ne $descProp.Value) {
            $raw = [string]$descProp.Value
            $description = $raw.Replace("`n- ", '<li>').Replace("`r`n", '<p>').Replace("`n", '<p>')
        }
    }

    if ([string]::IsNullOrEmpty($description) -and
        $ChildRaw -is [pscustomobject] -and
        $null -ne $ChildRaw.PSObject.Properties['$ref']) {

        $peek = Resolve-AvmArmRefDefinition -Raw $ChildRaw -Arm $Arm -RefStack $RefStack
        if ($peek.HasRef -and -not $peek.IsCycle -and $null -ne $peek.Resolved) {
            $peekMetaProp = $peek.Resolved.PSObject.Properties['metadata']
            if ($null -ne $peekMetaProp -and $null -ne $peekMetaProp.Value) {
                $peekDescProp = $peekMetaProp.Value.PSObject.Properties['description']
                if ($null -ne $peekDescProp -and $null -ne $peekDescProp.Value) {
                    $peekRaw = [string]$peekDescProp.Value
                    $description = $peekRaw.Replace("`n- ", '<li>').Replace("`r`n", '<p>').Replace("`n", '<p>')
                }
            }
        }
    }

    return $description
}

function Resolve-AvmArmRefDefinition {
    <#
    .SYNOPSIS
        Resolve a raw ARM parameter / property record that may carry
        a '$ref' value against the template's 'definitions' bag.

    .DESCRIPTION
        Internal helper used by Get-AvmArmParameterDetailRecord. When
        the supplied raw record carries no '$ref' property the
        function is a no-op: it returns the original raw unchanged
        with HasRef=$false. When a '$ref' is present:
          - The value must match '^#/definitions/<name>$' where
            <name> is a non-empty identifier. Any other shape throws
            [AvmConfigurationException].
          - The named definition must exist on
            $Arm.definitions.<name>. A miss throws
            [AvmConfigurationException].
          - If <name> is already on $RefStack the resolver reports
            a cycle (Resolved=$null, IsCycle=$true). The caller
            emits a leaf record with no Children.
          - Otherwise the referenced definition is deep-cloned (via
            ConvertTo-Json / ConvertFrom-Json) so the source bag is
            never mutated, and the local raw's properties are
            overlaid on top with these rules:
              * '$ref' itself is dropped.
              * 'metadata' is shallow-merged - each local
                metadata.* property overlays the cloned definition's
                metadata.* property of the same name. Definition
                metadata keys not present locally are preserved.
              * Every other local property replaces the cloned
                definition's property of the same name (local wins).
            The net effect: 'type' / 'properties' / 'items' /
            'discriminator' / 'additionalProperties' come from the
            definition (the things UDTs actually define), and
            'defaultValue' / 'nullable' / 'allowedValues' / 'minValue'
            / 'maxValue' / 'metadata.*' come from the local
            declaration (the things parameter authors override).

        Strict-mode safe via the '.PSObject.Properties[<name>]'
        indexer for every PSObject lookup.

    .PARAMETER Raw
        The raw ARM parameter / property definition (PSCustomObject)
        that may or may not carry a '$ref'.

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject) carrying the
        'definitions' bag.

    .PARAMETER RefStack
        Names of '$ref' definitions resolved on the current path
        from the top-level walker down to this record. Used for
        cycle detection.

    .OUTPUTS
        Hashtable with keys:
          - HasRef   ([bool])              $true when $Raw.$ref was present
          - RefName  ([string])            resolved definition name or ''
          - IsCycle  ([bool])              $true when RefName is already on $RefStack
          - Resolved ([pscustomobject])    merged record, or $null on cycle / no-op
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        $Raw,

        [Parameter(Mandatory)]
        $Arm,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $RefStack
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $noOp = @{ HasRef = $false; RefName = ''; IsCycle = $false; Resolved = $Raw }

    if ($null -eq $Raw) { return $noOp }
    if (-not ($Raw -is [pscustomobject])) { return $noOp }

    $refProp = $Raw.PSObject.Properties['$ref']
    if ($null -eq $refProp -or $null -eq $refProp.Value) { return $noOp }

    $refValue = [string]$refProp.Value
    $match = [regex]::Match($refValue, '^#/definitions/(?<name>[A-Za-z0-9_\-]+)$')
    if (-not $match.Success) {
        throw [AvmConfigurationException]::new(
            ("Malformed `$ref value '{0}'. Expected '#/definitions/<name>'." -f $refValue))
    }
    $name = $match.Groups['name'].Value

    $defsProp = $Arm.PSObject.Properties['definitions']
    if ($null -eq $defsProp -or $null -eq $defsProp.Value) {
        throw [AvmConfigurationException]::new(
            ("`$ref '{0}' cannot be resolved: the ARM template has no 'definitions' bag." -f $refValue))
    }
    $defProp = $defsProp.Value.PSObject.Properties[$name]
    if ($null -eq $defProp -or $null -eq $defProp.Value) {
        throw [AvmConfigurationException]::new(
            ("`$ref '{0}' points at a missing definition '{1}'." -f $refValue, $name))
    }

    if ($RefStack -contains $name) {
        return @{ HasRef = $true; RefName = $name; IsCycle = $true; Resolved = $null }
    }

    $merged = $defProp.Value | ConvertTo-Json -Depth 99 -Compress | ConvertFrom-Json -Depth 99

    foreach ($local in $Raw.PSObject.Properties) {
        if ($local.Name -eq '$ref') { continue }

        if ($local.Name -eq 'metadata' -and
            $local.Value -is [pscustomobject] -and
            $null -ne $merged.PSObject.Properties['metadata'] -and
            $merged.PSObject.Properties['metadata'].Value -is [pscustomobject]) {

            $mergedMeta = $merged.PSObject.Properties['metadata'].Value
            foreach ($metaProp in $local.Value.PSObject.Properties) {
                $existing = $mergedMeta.PSObject.Properties[$metaProp.Name]
                if ($null -ne $existing) {
                    $mergedMeta.PSObject.Properties.Remove($metaProp.Name) | Out-Null
                }
                $mergedMeta.PSObject.Properties.Add(
                    [System.Management.Automation.PSNoteProperty]::new($metaProp.Name, $metaProp.Value))
            }
            continue
        }

        $existing = $merged.PSObject.Properties[$local.Name]
        if ($null -ne $existing) {
            $merged.PSObject.Properties.Remove($local.Name) | Out-Null
        }
        $merged.PSObject.Properties.Add(
            [System.Management.Automation.PSNoteProperty]::new($local.Name, $local.Value))
    }

    return @{ HasRef = $true; RefName = $name; IsCycle = $false; Resolved = $merged }
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
