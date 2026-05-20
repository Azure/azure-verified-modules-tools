function Get-AvmArmResource {
    <#
    .SYNOPSIS
        Walk a compiled ARM template and return a flat list of every
        resource it declares, including nested-deployment children.

    .DESCRIPTION
        Internal helper used by the Bicep docs engine. Walks the top-level
        'resources' array of a compiled ARM template (as produced by
        Convert-AvmBicepToArm) and recursively descends into:

          - each resource's own 'resources' child array (inline child
            resources, when present);
          - each Microsoft.Resources/deployments resource's
            'properties.template.resources' (nested-deployment body).

        Each entry is returned as a PSCustomObject with Type and
        ApiVersion (both strings, exactly as ARM JSON spells them).
        Order is the natural walk order; the caller is expected to
        de-duplicate and sort.

        Strict-mode safe: every PSObject property lookup uses the
        '.PSObject.Properties[<name>]' indexer so missing properties
        return $null instead of throwing.

        Known limitations (deferred to follow-on slices):
          - Bicep generally promotes child resources to the top level
            of the compiled ARM JSON, so the inline-children branch is
            a defensive recursion path that is rarely exercised in
            practice. Relative child types (e.g. 'accessPolicies'
            instead of 'Microsoft.KeyVault/vaults/accessPolicies') are
            emitted verbatim and are not stitched back to their parent.

    .PARAMETER Arm
        The parsed ARM template (PSCustomObject) produced by
        Convert-AvmBicepToArm.

    .OUTPUTS
        [pscustomobject[]] with properties Type and ApiVersion.
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

    $resourcesProp = $Arm.PSObject.Properties['resources']
    if ($null -eq $resourcesProp -or $null -eq $resourcesProp.Value) {
        return , $entries.ToArray()
    }

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($resourcesProp.Value)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($r in $current) {
            if ($null -eq $r) { continue }

            $typeProp = $r.PSObject.Properties['type']
            $apiVersionProp = $r.PSObject.Properties['apiVersion']
            if ($null -ne $typeProp -and $null -ne $apiVersionProp) {
                $entries.Add([pscustomobject][ordered]@{
                        Type       = [string]$typeProp.Value
                        ApiVersion = [string]$apiVersionProp.Value
                    })
            }

            $childProp = $r.PSObject.Properties['resources']
            if ($null -ne $childProp -and $null -ne $childProp.Value) {
                $queue.Enqueue($childProp.Value)
            }

            $propsProp = $r.PSObject.Properties['properties']
            if ($null -ne $propsProp -and $null -ne $propsProp.Value) {
                $templateProp = $propsProp.Value.PSObject.Properties['template']
                if ($null -ne $templateProp -and $null -ne $templateProp.Value) {
                    $nestedResProp = $templateProp.Value.PSObject.Properties['resources']
                    if ($null -ne $nestedResProp -and $null -ne $nestedResProp.Value) {
                        $queue.Enqueue($nestedResProp.Value)
                    }
                }
            }
        }
    }

    return , $entries.ToArray()
}
