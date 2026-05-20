function Format-AvmBicepResourceTypesSection {
    <#
    .SYNOPSIS
        Render the body of the README "## Resource Types" section for
        a compiled Bicep template.

    .DESCRIPTION
        Internal helper consumed by Invoke-AvmBicepDocs. Walks the
        compiled ARM template's resources (including nested-deployment
        children) via Get-AvmArmResource, de-duplicates on the
        (Type, ApiVersion) pair, sorts by Type with en-US culture, and
        emits the markdown body for the '## Resource Types' section.
        The body is returned without the heading itself
        (Merge-AvmReadmeSection owns the heading line).

        Two forms:
          - '_None_' if the template declares no resources (or every
            resource type is in the exclude list).
          - 3-column table 'Resource Type | API Version | References'
            otherwise. The References cell embeds an inline HTML <ul>
            with two links per row: an AzAdvertizer page and the
            api-version-specific learn.microsoft.com template
            reference, matching the contract of
            Set-ModuleReadMe.ps1 from Azure/bicep-registry-modules.

        URL contracts:
          - AzAdvertizer:
              https://www.azadvertizer.net/azresourcetypes/<type>.html
            where <type> is the resource type lower-cased with '/'
            replaced by '_'.
          - Template reference:
              https://learn.microsoft.com/en-us/azure/templates/<namespace>/<apiVersion>/<typePath>
            where <namespace> is the substring before the first '/'
            and <typePath> is the substring after. Casing is preserved
            verbatim from the ARM 'type' field, matching the legacy
            output exactly (including the '/en-us/' locale segment).

        The default exclude list is @('Microsoft.Resources/deployments')
        so that nested-deployment wrapper resources do not appear in
        the rendered table; their child resources are still included
        because Get-AvmArmResource descends into
        'properties.template.resources'.

        Reserved for follow-on slices: probing the candidate URLs and
        falling back to a non-api-version URL when the typed one 404s
        (the legacy script does this via Test-Url).

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject) produced by
        Convert-AvmBicepToArm.

    .PARAMETER ExcludeTypes
        Resource types to omit from the table. Defaults to
        @('Microsoft.Resources/deployments'). Comparison is
        case-sensitive ordinal to match the literal ARM 'type' string.

    .OUTPUTS
        [string[]] - the lines of the Resource Types section body,
        suitable for passing as -NewBody to Merge-AvmReadmeSection.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Arm,

        [string[]] $ExcludeTypes = @('Microsoft.Resources/deployments')
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $all = Get-AvmArmResource -Arm $Arm

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($t in $ExcludeTypes) {
        if (-not [string]::IsNullOrEmpty($t)) { $null = $excludeSet.Add($t) }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $unique = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($e in $all) {
        if ($excludeSet.Contains($e.Type)) { continue }
        $key = '{0}|{1}' -f $e.Type, $e.ApiVersion
        if ($seen.Add($key)) {
            $unique.Add($e)
        }
    }

    if ($unique.Count -eq 0) {
        return , @('_None_')
    }

    $sorted = @($unique | Sort-Object -Property Type -Culture 'en-US')

    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add('| Resource Type | API Version | References |')
    $rows.Add('| :-- | :-- | :-- |')
    foreach ($e in $sorted) {
        $type = $e.Type
        $apiVersion = $e.ApiVersion
        $slashIndex = $type.IndexOf('/')
        if ($slashIndex -lt 0) {
            $namespace = $type
            $typePath = ''
            $learnUrl = 'https://learn.microsoft.com/en-us/azure/templates/{0}/{1}' -f $namespace, $apiVersion
        }
        else {
            $namespace = $type.Substring(0, $slashIndex)
            $typePath = $type.Substring($slashIndex + 1)
            $learnUrl = 'https://learn.microsoft.com/en-us/azure/templates/{0}/{1}/{2}' -f $namespace, $apiVersion, $typePath
        }
        $azAdvertizerSlug = $type.ToLowerInvariant().Replace('/', '_')
        $azAdvertizerUrl = 'https://www.azadvertizer.net/azresourcetypes/{0}.html' -f $azAdvertizerSlug
        $refsCell = '<ul style="padding-left: 0px;"><li>[AzAdvertizer]({0})</li><li>[Template reference]({1})</li></ul>' -f $azAdvertizerUrl, $learnUrl
        $rows.Add(('| `{0}` | {1} | {2} |' -f $type, $apiVersion, $refsCell))
    }

    return , $rows.ToArray()
}
