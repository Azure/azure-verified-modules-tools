function Get-AvmBicepDocsCompiledResource {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template
    )

    Set-StrictMode -Version 3.0
    $pending = [System.Collections.Generic.Stack[object]]::new()
    $resources = [System.Collections.Generic.List[object]]::new()
    $pending.Push([pscustomobject]@{ Template = $Template; Entry = $null })

    while ($pending.Count -gt 0) {
        $work = $pending.Pop()
        if ($null -ne $work.Entry) {
            $item = $work.Entry
            $resource = $item.Resource
            if ($resource -isnot [System.Collections.IDictionary] -or
                $resource['existing'] -eq $true) {
                continue
            }
            $resources.Add($item)
            $properties = $resource['properties']
            if ($properties -is [System.Collections.IDictionary] -and
                $properties['template'] -is [System.Collections.IDictionary]) {
                $pending.Push([pscustomobject]@{
                        Template = $properties['template']
                        Entry    = $null
                    })
            }
            if ($resource.Contains('resources')) {
                $pending.Push([pscustomobject]@{ Template = $resource; Entry = $null })
            }
            continue
        }

        $node = $work.Template
        $entries = $node['resources']
        $items = [System.Collections.Generic.List[object]]::new()
        if ($entries -is [System.Collections.IDictionary]) {
            foreach ($identifier in $entries.psbase.Keys) {
                $items.Add([pscustomobject]@{
                        Identifier = [string]$identifier
                        Resource   = $entries[$identifier]
                    })
            }
        }
        elseif ($entries -is [array]) {
            foreach ($resource in $entries) {
                $items.Add([pscustomobject]@{
                        Identifier = ''
                        Resource   = $resource
                    })
            }
        }

        for ($index = $items.Count - 1; $index -ge 0; $index--) {
            $pending.Push([pscustomobject]@{
                    Template = $null
                    Entry    = $items[$index]
                })
        }
    }

    return $resources.ToArray()
}
