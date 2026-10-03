function Get-AvmBicepCleanupRestCollection {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $nextPath = $Path
    while (-not [string]::IsNullOrEmpty($nextPath)) {
        if (-not $nextPath.StartsWith('/') -or $nextPath.StartsWith('//') -or
            -not $visited.Add($nextPath)) {
            throw [AvmProcessException]::new("Invalid or repeated Azure collection page: $nextPath")
        }
        $response = Invoke-AzRestMethod -Method GET -Path $nextPath -ErrorAction Stop
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
            throw [AvmProcessException]::new(
                "Azure collection request failed with HTTP $($response.StatusCode): $nextPath")
        }
        $document = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($document -isnot [System.Collections.IDictionary] -or
            -not $document.Contains('value') -or $document['value'] -isnot [array]) {
            throw [AvmProcessException]::new("Azure collection has no value array: $nextPath")
        }
        foreach ($item in $document['value']) {
            $item
        }
        $nextPath = Resolve-AvmBicepCleanupNextLink -NextLink (
            Get-AvmPropertyValue -InputObject $document -Name 'nextLink')
    }
}
