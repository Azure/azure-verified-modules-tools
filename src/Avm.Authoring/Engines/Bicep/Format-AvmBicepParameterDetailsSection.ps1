function Format-AvmBicepParameterDetailsSection {
    <#
    .SYNOPSIS
        Render the per-parameter '### Parameter:' detail blocks that
        live inside the README "## Parameters" section.

    .DESCRIPTION
        Internal helper consumed by Invoke-AvmBicepDocs. Walks the
        compiled ARM template's top-level parameters via
        Get-AvmArmParameterDetail and emits one
        '### Parameter: `<name>`' block per parameter, grouped by
        category and sorted by Name with en-US culture so they
        align with the summary tables emitted by
        Format-AvmBicepParametersSection.

        Each block looks like:

            ### Parameter: `<name>`

            <description>

            - Required: Yes|No
            - Type: <type>
            - Default: `<formatted-default>`         (only if defaultValue is set)
            - Allowed: `[ 'a', 'b', 'c' ]`            (only if allowedValues is set)
            - MinValue: <n>                          (only if minValue is set)
            - MaxValue: <n>                          (only if maxValue is set)
            - Example: `<single-line>`                (if metadata.example has one line)
            - Example:                               (if metadata.example has multiple lines)
              ```bicep
              <body>
              ```

        Slice 4b scope: top-level grouping (Required \u2192 Conditional
        \u2192 Optional \u2192 Generated, en-US alphabetical within)
        is unchanged. After each top-level block, the per-block
        emitter recurses into any 'Children' returned by
        Get-AvmArmParameterDetail (inline 'type=object' +
        'properties.*' walks) and emits child blocks in declaration
        order immediately after their parent, with the standard
        blank-line separator. Child headings use the dotted name
        from the walker ('parent.child'); the GitHub anchor for
        such headings strips the dot
        ('#parameter-parentchild'). Cross-references from the
        parent block to its children land in a follow-up slice.

        Returns an empty array when the template declares no
        parameters \u2014 the summary formatter already emits
        '_None_' in that case, so detail blocks add nothing.

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject) produced by
        Convert-AvmBicepToArm.

    .PARAMETER CategoryOrder
        Category names in the order they should be rendered. Defaults
        to the AVM convention. Categories that exist in the template
        but are absent from this list are appended in first-seen
        order so unknown categories never disappear silently.

    .OUTPUTS
        [string[]] \u2014 the lines that follow the summary tables
        inside the '## Parameters' section.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Arm,

        [string[]] $CategoryOrder = @('Required', 'Conditional', 'Optional', 'Generated')
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $entries = Get-AvmArmParameterDetail -Arm $Arm
    if ($entries.Count -eq 0) {
        return , @()
    }

    $groups = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($e in $entries) {
        $cat = $e.Category
        if (-not $groups.Contains($cat)) {
            $groups[$cat] = [System.Collections.Generic.List[pscustomobject]]::new()
        }
        ([System.Collections.Generic.List[pscustomobject]]$groups[$cat]).Add($e)
    }

    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $CategoryOrder) {
        if ($groups.Contains($c)) { $ordered.Add($c) }
    }
    foreach ($c in @($groups.Keys)) {
        if ($CategoryOrder -notcontains $c) { $ordered.Add([string]$c) }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($cat in $ordered) {
        $rows = @(([System.Collections.Generic.List[pscustomobject]]$groups[$cat]) |
                Sort-Object -Property Name -Culture 'en-US')
        foreach ($r in $rows) {
            Add-AvmBicepParameterDetailBlock -Record $r -Lines $lines
        }
    }

    return , $lines.ToArray()
}

function Add-AvmBicepParameterDetailBlock {
    <#
    .SYNOPSIS
        Append a single '### Parameter:' block (and its nested child
        blocks) onto the supplied line accumulator.

    .DESCRIPTION
        Internal helper used by Format-AvmBicepParameterDetailsSection.
        Emits the heading, description, and detail bullets for one
        record, then recurses into Children in declaration order so
        nested inline-object properties appear immediately after
        their parent. The standard blank-line separator is inserted
        whenever the accumulator already has content, so the parent
        and each of its children get a blank line between them.

        The helper mutates the supplied List in place \u2014 callers
        do not need to thread an accumulator through return values.

    .PARAMETER Record
        A per-parameter record produced by
        Get-AvmArmParameterDetail (top-level or nested).

    .PARAMETER Lines
        The shared accumulator that the caller is building up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Record,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [System.Collections.Generic.List[string]] $Lines
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Lines.Count -gt 0) { $Lines.Add('') }
    $Lines.Add(('### Parameter: `{0}`' -f $Record.Name))
    $Lines.Add('')
    $Lines.Add([string]$Record.Description)
    $Lines.Add('')
    $Lines.Add(('- Required: {0}' -f ($(if ($Record.IsRequired) { 'Yes' } else { 'No' }))))
    $Lines.Add(('- Type: {0}' -f $Record.Type))
    if ($Record.HasDefault) {
        $Lines.Add(('- Default: `{0}`' -f $Record.Default))
    }
    if ($Record.HasAllowedValues) {
        $Lines.Add(('- Allowed: `{0}`' -f $Record.AllowedValues))
    }
    if ($Record.HasMinValue) {
        $Lines.Add(('- MinValue: {0}' -f [string]$Record.MinValue))
    }
    if ($Record.HasMaxValue) {
        $Lines.Add(('- MaxValue: {0}' -f [string]$Record.MaxValue))
    }
    if ($Record.HasExample) {
        if ($Record.ExampleIsSingleLine) {
            $Lines.Add(('- Example: `{0}`' -f ([string]$Record.ExampleLines[0]).Trim()))
        }
        else {
            $Lines.Add('- Example:')
            $Lines.Add('  ```bicep')
            foreach ($ln in $Record.ExampleLines) {
                $Lines.Add(('  {0}' -f [string]$ln))
            }
            $Lines.Add('  ```')
        }
    }

    if ($null -ne $Record.PSObject.Properties['Children'] -and $Record.Children.Count -gt 0) {
        foreach ($child in $Record.Children) {
            Add-AvmBicepParameterDetailBlock -Record $child -Lines $Lines
        }
    }
}
