function Get-AvmMetadataBackfillValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object[]] $Record = @(),
        [Parameter(Mandatory)]
        [string[]] $Name
    )

    $values = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $Record) {
        foreach ($column in $Name) {
            $value = if ($row -is [System.Collections.IDictionary]) {
                $row[$column]
            }
            elseif ($row.PSObject.Properties[$column]) {
                $row.$column
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                $null = $values.Add([string]$value)
            }
        }
    }
    if ($values.Count -gt 1) {
        throw [System.ArgumentException]::new("Conflicting existing values for '$($Name[0])'; specify the correct value.")
    }
    foreach ($value in $values) {
        return $value
    }
}
