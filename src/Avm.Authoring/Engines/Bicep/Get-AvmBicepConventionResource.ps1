function Get-AvmBicepConventionResource {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template
    )

    Set-StrictMode -Version 3.0

    $items = [System.Collections.Generic.List[object]]::new()
    $resources = $Template['resources']
    if ($resources -is [System.Collections.IDictionary]) {
        foreach ($name in $resources.psbase.Keys) {
            $items.Add([pscustomobject]@{
                    Identifier = [string]$name
                    Resource   = $resources[$name]
                })
        }
    }
    elseif ($resources -is [array]) {
        foreach ($resource in $resources) {
            $items.Add([pscustomobject]@{
                    Identifier = ''
                    Resource   = $resource
                })
        }
    }
    else {
        throw [AvmConfigurationException]::new('Compiled Bicep resources must be an array or symbolic resource object.')
    }
    foreach ($item in $items) {
        if ($item.Resource -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Compiled Bicep resource '$($item.Identifier)' must be an object.")
        }
    }

    return $items.ToArray()
}
