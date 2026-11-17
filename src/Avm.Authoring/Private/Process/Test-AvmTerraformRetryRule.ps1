function Test-AvmTerraformRetryRule {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Output,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Rule
    )

    if ($Rule.Contains('anyOf')) {
        foreach ($pattern in $Rule['anyOf']) {
            if ($Output -match $pattern) { return $true }
        }
        return $false
    }

    foreach ($block in ($Output -split '\r?\n[ \t]*\r?\n')) {
        $allMatch = $true
        foreach ($pattern in $Rule['allOf']) {
            if ($block -notmatch $pattern) {
                $allMatch = $false
                break
            }
        }
        if ($allMatch) { return $true }
    }
    return $false
}
