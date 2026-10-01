function Select-AvmBicepTestCase {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Cases = @(),

        [AllowEmptyCollection()]
        [string[]] $Example = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Example.Count -eq 0) {
        foreach ($case in $Cases) {
            if (-not $case.Ignored) {
                $case
            }
        }
        return
    }

    $valid = (@($Cases | Where-Object { -not $_.Ignored } |
                ForEach-Object { $_.RelativeDirectory }) -join ', ')
    if ([string]::IsNullOrWhiteSpace($valid)) {
        $valid = '<none>'
    }
    $selected = [System.Collections.Generic.HashSet[string]]::new(
        $(if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }))
    foreach ($requested in $Example) {
        if ([string]::IsNullOrWhiteSpace($requested)) {
            throw [AvmConfigurationException]::new('Bicep test example selectors cannot be empty.')
        }
        $selector = $requested.Replace('\', '/').Trim().Trim('/')
        $selector = $selector -replace '^\./', ''
        $selectionMatches = @($Cases | Where-Object {
                $_.Name -eq $selector -or
                $_.RelativeDirectory -eq $selector -or
                $_.RelativePath -eq $selector
            })
        if ($selectionMatches.Count -eq 0) {
            throw [AvmConfigurationException]::new(
                "Unknown Bicep test example '$requested'. Runnable examples: $valid.")
        }
        if ($selectionMatches.Count -gt 1) {
            throw [AvmConfigurationException]::new(
                "Ambiguous Bicep test example '$requested'. Select a relative directory: $valid.")
        }
        if ($selectionMatches[0].Ignored) {
            throw [AvmConfigurationException]::new(
                "Bicep test example '$requested' is opted out by .e2eignore and cannot be targeted explicitly.")
        }
        if ($selected.Add($selectionMatches[0].Path)) {
            $selectionMatches[0]
        }
    }
}
