function Get-AvmArmParameter {
    <#
    .SYNOPSIS
        Walk a compiled ARM template's top-level parameters and return
        a flat list of categorised entries.

    .DESCRIPTION
        Internal helper used by the Bicep docs engine. Reads the
        'parameters' object of a compiled ARM template (as produced by
        Convert-AvmBicepToArm) and emits one PSCustomObject per
        top-level parameter with the fields the README walker needs to
        render the '## Parameters' summary tables.

        Categorisation matches the AVM convention enforced by the
        legacy Set-ModuleReadMe.ps1: every parameter's
        metadata.description must begin with a single-word category
        followed by a period and a space, e.g. 'Required. The name of
        the resource.', 'Optional. Tags ...', 'Conditional. The parent
        name ...', 'Generated. The deployment location.'. The category
        word is captured into the Category field and stripped from the
        emitted Description.

        Description newline folding mirrors the legacy script exactly,
        in this order:
          - '\n- ' becomes '<li>' (markdown bullet conversion);
          - '\r\n'  becomes '<p>';
          - '\n'    becomes '<p>'.

        Strict-mode safe via the '.PSObject.Properties[<name>]'
        indexer for every PSObject lookup. Slice 3 walks top-level
        parameters only \u2014 nested object/User-Defined-Type
        recursion is reserved for the slice that renders per-parameter
        '### Parameter:' detail blocks.

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject) produced by
        Convert-AvmBicepToArm.

    .OUTPUTS
        [pscustomobject[]] with properties:
          - Name        (string)  parameter key, original case
          - Type        (string)  ARM 'type' field, e.g. 'string', 'object'
          - Category    (string)  e.g. 'Required', 'Optional', 'Conditional', 'Generated'
          - Description (string)  category prefix stripped, newlines folded
          - IsRequired  (bool)    true when no 'defaultValue' is set

    .NOTES
        Throws [AvmConfigurationException] if any parameter has no
        metadata.description or whose description does not start with
        a '<Word>. ' category prefix. The exception message lists
        every offender so the author can fix them in one pass.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        $Arm
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $entries = [System.Collections.Generic.List[pscustomobject]]::new()

    $parametersProp = $Arm.PSObject.Properties['parameters']
    if ($null -eq $parametersProp -or $null -eq $parametersProp.Value) {
        return , $entries.ToArray()
    }

    $offenders = [System.Collections.Generic.List[string]]::new()
    $categoryPattern = '^(?<cat>\w+)\.\s+(?<rest>.*)$'

    foreach ($paramProp in $parametersProp.Value.PSObject.Properties) {
        $name = [string]$paramProp.Name
        $param = $paramProp.Value
        if ($null -eq $param) {
            $offenders.Add($name)
            continue
        }

        $typeProp = $param.PSObject.Properties['type']
        $type = if ($null -ne $typeProp) { [string]$typeProp.Value } else { '' }

        $hasDefault = $null -ne $param.PSObject.Properties['defaultValue']

        $descriptionRaw = ''
        $metadataProp = $param.PSObject.Properties['metadata']
        if ($null -ne $metadataProp -and $null -ne $metadataProp.Value) {
            $descProp = $metadataProp.Value.PSObject.Properties['description']
            if ($null -ne $descProp -and $null -ne $descProp.Value) {
                $descriptionRaw = [string]$descProp.Value
            }
        }

        $match = [regex]::Match($descriptionRaw, $categoryPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $match.Success) {
            $offenders.Add($name)
            continue
        }

        $category = $match.Groups['cat'].Value
        $body = $match.Groups['rest'].Value
        $description = $body.Replace("`n- ", '<li>').Replace("`r`n", '<p>').Replace("`n", '<p>')

        $entries.Add([pscustomobject][ordered]@{
                Name        = $name
                Type        = $type
                Category    = $category
                Description = $description
                IsRequired  = -not $hasDefault
            })
    }

    if ($offenders.Count -gt 0) {
        $list = ($offenders | ForEach-Object { "  - $_" }) -join "`n"
        throw [AvmConfigurationException]::new(
            ("One or more parameters are missing an AVM category prefix in their metadata.description.`n" +
                "Every parameter must start with a single-word category followed by '. ', e.g. 'Required. ...', 'Optional. ...', 'Conditional. ...', 'Generated. ...'.`n" +
                "Offending parameters:`n{0}" -f $list))
    }

    return , $entries.ToArray()
}
