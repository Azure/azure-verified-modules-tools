function Get-AvmBicepDocsOrderedValue {
    [CmdletBinding()]
    [OutputType([object], [System.Collections.Specialized.OrderedDictionary], [object[]])]
    param(
        [AllowNull()]
        [object] $Value
    )

    Set-StrictMode -Version 3.0

    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.psbase.Keys | Sort-Object -Culture 'en-US')) {
            $ordered[$key] = Get-AvmBicepDocsOrderedValue -Value $Value[$key]
        }
        return $ordered
    }
    if ($Value -is [array]) {
        $arrays = [System.Collections.Generic.List[object]]::new()
        $objects = [System.Collections.Generic.List[object]]::new()
        $primitives = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            if ($item -is [array]) {
                $arrays.Add((Get-AvmBicepDocsOrderedValue -Value $item))
            }
            elseif ($item -is [System.Collections.IDictionary]) {
                $objects.Add((Get-AvmBicepDocsOrderedValue -Value $item))
            }
            else {
                $primitives.Add($item)
            }
        }
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $arrays) { $result.Add($item) }
        foreach ($item in $objects) { $result.Add($item) }
        foreach ($item in @($primitives | Sort-Object -Culture 'en-US')) {
            $result.Add($item)
        }
        return , $result.ToArray()
    }
    return $Value
}
