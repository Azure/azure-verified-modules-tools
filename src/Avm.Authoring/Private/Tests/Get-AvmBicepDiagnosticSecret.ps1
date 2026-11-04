function Get-AvmBicepDiagnosticSecret {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()] [object] $Parameters,
        [AllowNull()] [object] $SecretInputs
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $values = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $pending.Enqueue($Parameters)
    $pending.Enqueue($SecretInputs)
    $visited = 0
    while ($pending.Count -gt 0) {
        $visited++
        if ($visited -gt 10000) {
            throw [AvmConfigurationException]::new('Diagnostic redaction input exceeds the supported size.')
        }
        $item = $pending.Dequeue()
        if ($null -eq $item) { continue }
        if ($item -is [securestring]) {
            $item = [System.Net.NetworkCredential]::new('', $item).Password
        }
        if ($item -is [string]) {
            if ($item.Length -gt 0) { $null = $values.Add($item) }
        }
        elseif ($item -is [System.Collections.IDictionary]) {
            foreach ($value in $item.Values) { $pending.Enqueue($value) }
        }
        elseif ($item -is [pscustomobject]) {
            foreach ($property in $item.PSObject.Properties) { $pending.Enqueue($property.Value) }
        }
        elseif ($item -is [System.Collections.IEnumerable]) {
            foreach ($value in $item) { $pending.Enqueue($value) }
        }
    }
    return [string[]]@($values | Sort-Object -Property Length -Descending)
}
