function Get-AvmArmParameterDetail {
    <#
    .SYNOPSIS
        Walk a compiled ARM template's top-level parameters and return
        rich per-parameter records suitable for the per-parameter
        '### Parameter:' detail blocks.

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

        Slice 4a scope: top-level primitive-style parameters only.
        For object/array types and User-Defined Types ('$ref') the
        record is emitted with empty Children, leaving the heading +
        bullets visible so the summary table's
        '[name](#parameter-name)' anchor still resolves. The
        recursive walk into '.properties', 'items', '$ref', and
        'discriminator.mapping' lands in slices 4b\u20134e.

        Strict-mode safe via the '.PSObject.Properties[<name>]'
        indexer for every PSObject lookup.

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject) produced by
        Convert-AvmBicepToArm.

    .OUTPUTS
        [pscustomobject[]] with properties:
          - Name                  (string)
          - Type                  (string)
          - Category              (string)
          - Description           (string)  newline-folded
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

    .NOTES
        Propagates [AvmConfigurationException] from Get-AvmArmParameter
        when any parameter is missing its category prefix.
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

        $hasDefault = $false; $defaultText = ''
        $defaultProp = $raw.PSObject.Properties['defaultValue']
        if ($null -ne $defaultProp) {
            $hasDefault = $true
            $defaultText = Format-AvmArmScalarForMarkdown -Value $defaultProp.Value
        }

        $hasAllowed = $false; $allowedText = ''
        $allowedProp = $raw.PSObject.Properties['allowedValues']
        if ($null -ne $allowedProp -and $null -ne $allowedProp.Value) {
            $hasAllowed = $true
            $allowedText = Format-AvmArmAllowedValuesForMarkdown -Values $allowedProp.Value
        }

        $hasMin = $false; $minValue = $null
        $minProp = $raw.PSObject.Properties['minValue']
        if ($null -ne $minProp) { $hasMin = $true; $minValue = $minProp.Value }

        $hasMax = $false; $maxValue = $null
        $maxProp = $raw.PSObject.Properties['maxValue']
        if ($null -ne $maxProp) { $hasMax = $true; $maxValue = $maxProp.Value }

        $hasExample = $false; $exampleLines = @(); $exampleSingle = $false
        $metaProp = $raw.PSObject.Properties['metadata']
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

        $entries.Add([pscustomobject][ordered]@{
                Name                = $b.Name
                Type                = $b.Type
                Category            = $b.Category
                Description         = $b.Description
                IsRequired          = $b.IsRequired
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
            })
    }

    return , $entries.ToArray()
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
