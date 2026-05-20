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

        Slice 4a scope: every top-level parameter gets its heading +
        bullets (including object, array, and UDT parameters). The
        recursive walk into '.properties', 'items', '$ref', and
        'discriminator.mapping' adds nested subsections inside each
        block in slices 4b\u20134e; it does NOT change the top-level
        emission.

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
            if ($lines.Count -gt 0) { $lines.Add('') }
            $lines.Add(('### Parameter: `{0}`' -f $r.Name))
            $lines.Add('')
            $lines.Add([string]$r.Description)
            $lines.Add('')
            $lines.Add(('- Required: {0}' -f ($(if ($r.IsRequired) { 'Yes' } else { 'No' }))))
            $lines.Add(('- Type: {0}' -f $r.Type))
            if ($r.HasDefault) {
                $lines.Add(('- Default: `{0}`' -f $r.Default))
            }
            if ($r.HasAllowedValues) {
                $lines.Add(('- Allowed: `{0}`' -f $r.AllowedValues))
            }
            if ($r.HasMinValue) {
                $lines.Add(('- MinValue: {0}' -f [string]$r.MinValue))
            }
            if ($r.HasMaxValue) {
                $lines.Add(('- MaxValue: {0}' -f [string]$r.MaxValue))
            }
            if ($r.HasExample) {
                if ($r.ExampleIsSingleLine) {
                    $lines.Add(('- Example: `{0}`' -f ([string]$r.ExampleLines[0]).Trim()))
                }
                else {
                    $lines.Add('- Example:')
                    $lines.Add('  ```bicep')
                    foreach ($ln in $r.ExampleLines) {
                        $lines.Add(('  {0}' -f [string]$ln))
                    }
                    $lines.Add('  ```')
                }
            }
        }
    }

    return , $lines.ToArray()
}
