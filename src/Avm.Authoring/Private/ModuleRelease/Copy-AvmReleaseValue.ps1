function Copy-AvmReleaseValue {
    <#
    .SYNOPSIS
        Deep-copy a release-state value.

    .DESCRIPTION
        Copies dictionaries into ordered dictionaries and lists into arrays, recursively. Scalars are returned as they are. With SortKeys, dictionary keys are sorted by ordinal comparison, so serialised state is stable. The release engine copies state before changing it, so a caller's input never changes.

    .PARAMETER Value
        The value to copy.

    .PARAMETER SortKeys
        Sort dictionary keys by ordinal comparison.

    .EXAMPLE
        $copy = Copy-AvmReleaseValue -Value $state

        Returns a copy of the state that can be changed safely.

    .OUTPUTS
        The copied value.
    #>
    [CmdletBinding()]
    [OutputType([object], [System.Collections.Specialized.OrderedDictionary], [object[]])]
    param(
        [AllowNull()]
        [object] $Value,

        [switch] $SortKeys
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys | ForEach-Object { [string]$_ })
        if ($SortKeys) {
            [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        }
        $copy = [ordered]@{}
        foreach ($key in $keys) {
            $copy[$key] = Copy-AvmReleaseValue -Value $Value[$key] -SortKeys:$SortKeys
        }
        return $copy
    }

    if ($Value -is [System.Collections.IList]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((Copy-AvmReleaseValue -Value $item -SortKeys:$SortKeys))
        }
        return , $items.ToArray()
    }

    throw [System.ArgumentException]::new("Release state cannot hold a value of type '$($Value.GetType().FullName)'.")
}
