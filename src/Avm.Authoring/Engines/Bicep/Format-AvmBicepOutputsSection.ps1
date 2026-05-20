function Format-AvmBicepOutputsSection {
    <#
    .SYNOPSIS
        Render the body of the README "## Outputs" section for a
        compiled Bicep template.

    .DESCRIPTION
        Internal helper consumed by Invoke-AvmBicepDocs. Walks the
        outputs of a compiled ARM template and produces the markdown
        body for the '## Outputs' section. The body is returned without
        the heading itself (Merge-AvmReadmeSection owns the heading line).

        Three forms:
          - '_None_' if the template declares no outputs (or the
            outputs object is empty).
          - 3-column table 'Output | Type | Description' if any output
            has metadata.description.
          - 2-column table 'Output | Type' otherwise.

        Outputs are sorted by name using en-US culture, matching the
        legacy Set-ModuleReadMe.ps1 contract from Azure/bicep-registry-modules.

        Multi-line descriptions are folded so the table row stays on a
        single line: CRLF and LF are both replaced with the HTML 'p'
        token, mirroring legacy behaviour.

    .PARAMETER Arm
        The parsed ARM JSON object (PSCustomObject) as produced by
        Convert-AvmBicepToArm.

    .OUTPUTS
        [string[]] - the lines of the Outputs section body, suitable
        for passing as -NewBody to Merge-AvmReadmeSection.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Arm
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $outputsProp = $Arm.PSObject.Properties['outputs']
    if ($null -eq $outputsProp -or $null -eq $outputsProp.Value) {
        return , @('_None_')
    }
    $outputs = $outputsProp.Value

    $props = @($outputs.PSObject.Properties)
    if ($props.Count -eq 0) {
        return , @('_None_')
    }

    $sortedProps = @($props | Sort-Object -Property Name -Culture 'en-US')

    $hasDescription = $false
    foreach ($p in $sortedProps) {
        $o = $p.Value
        $metaProp = $o.PSObject.Properties['metadata']
        if ($null -ne $metaProp -and $null -ne $metaProp.Value) {
            $descProp = $metaProp.Value.PSObject.Properties['description']
            if ($null -ne $descProp -and -not [string]::IsNullOrWhiteSpace([string]$descProp.Value)) {
                $hasDescription = $true
                break
            }
        }
    }

    $rows = [System.Collections.Generic.List[string]]::new()
    if ($hasDescription) {
        $rows.Add('| Output | Type | Description |')
        $rows.Add('| :-- | :-- | :-- |')
        foreach ($p in $sortedProps) {
            $name = $p.Name
            $o = $p.Value
            $desc = ''
            $metaProp = $o.PSObject.Properties['metadata']
            if ($null -ne $metaProp -and $null -ne $metaProp.Value) {
                $descProp = $metaProp.Value.PSObject.Properties['description']
                if ($null -ne $descProp -and $null -ne $descProp.Value) {
                    $desc = ([string]$descProp.Value).Replace("`r`n", '<p>').Replace("`n", '<p>')
                }
            }
            $rows.Add(('| `{0}` | {1} | {2} |' -f $name, $o.type, $desc))
        }
    }
    else {
        $rows.Add('| Output | Type |')
        $rows.Add('| :-- | :-- |')
        foreach ($p in $sortedProps) {
            $rows.Add(('| `{0}` | {1} |' -f $p.Name, $p.Value.type))
        }
    }

    return , $rows.ToArray()
}
