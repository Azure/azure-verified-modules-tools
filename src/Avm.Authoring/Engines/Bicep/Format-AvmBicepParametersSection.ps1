function Format-AvmBicepParametersSection {
    <#
    .SYNOPSIS
        Render the body of the README "## Parameters" section for a
        compiled Bicep template.

    .DESCRIPTION
        Internal helper consumed by Invoke-AvmBicepDocs. Collects the
        compiled ARM template's top-level parameters via
        Get-AvmArmParameter, groups them by category, and emits one
        '**<Category> parameters**' subsection per non-empty category.
        Categories are emitted in the order
        @('Required','Conditional','Optional','Generated') first (the
        AVM convention), followed by any other categories in
        first-seen order. Parameters within each category are sorted
        by Name with en-US culture.

        Each subsection is a 3-column markdown table:

            | Parameter | Type | Description |
            | :-- | :-- | :-- |
            | [`<name>`](#parameter-<lowercasename>) | <type> | <desc> |

        The anchor target uses the lower-cased parameter name to
        match GitHub's automatic heading-slug behaviour for the
        '### Parameter: `<name>`' detail blocks that a later slice
        will emit. The description has its '<Category>. ' prefix
        stripped (by Get-AvmArmParameter) and its newlines folded
        (also by the walker, mirroring legacy Set-ModuleReadMe.ps1).

        Two forms:
          - '_None_' if the template declares no parameters;
          - 1..N category subsections otherwise, separated by blank
            lines.

        Reserved for a follow-on slice:
          - per-parameter '### Parameter: <name>' detail blocks
            (Required / Type / Default / Allowed / Example bullets);
          - recursion into object-typed parameters and User-Defined
            Types ('$ref' / definitions resolution).

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject) produced by
        Convert-AvmBicepToArm.

    .PARAMETER CategoryOrder
        Category names in the order they should be rendered. Defaults
        to the AVM convention. Categories that exist in the template
        but are absent from this list are appended in first-seen
        order so unknown categories never disappear silently.

    .OUTPUTS
        [string[]] \u2014 the lines of the Parameters section body,
        suitable for passing as -NewBody to Merge-AvmReadmeSection.
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

    $entries = Get-AvmArmParameter -Arm $Arm
    if ($entries.Count -eq 0) {
        return , @('_None_')
    }

    $groups = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($e in $entries) {
        $cat = $e.Category
        if (-not $groups.Contains($cat)) {
            $groups[$cat] = [System.Collections.Generic.List[pscustomobject]]::new()
        }
        ([System.Collections.Generic.List[pscustomobject]]$groups[$cat]).Add($e)
    }

    $orderedCategories = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $CategoryOrder) {
        if ($groups.Contains($c)) { $orderedCategories.Add($c) }
    }
    foreach ($c in @($groups.Keys)) {
        if ($CategoryOrder -notcontains $c) { $orderedCategories.Add([string]$c) }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $orderedCategories.Count; $i++) {
        if ($i -gt 0) { $lines.Add('') }
        $cat = $orderedCategories[$i]
        $lines.Add(('**{0} parameters**' -f $cat))
        $lines.Add('')
        $lines.Add('| Parameter | Type | Description |')
        $lines.Add('| :-- | :-- | :-- |')
        $rows = @(([System.Collections.Generic.List[pscustomobject]]$groups[$cat]) |
                Sort-Object -Property Name -Culture 'en-US')
        foreach ($r in $rows) {
            $anchor = $r.Name.ToLowerInvariant()
            $lines.Add(('| [`{0}`](#parameter-{1}) | {2} | {3} |' -f $r.Name, $anchor, $r.Type, $r.Description))
        }
    }

    return , $lines.ToArray()
}
