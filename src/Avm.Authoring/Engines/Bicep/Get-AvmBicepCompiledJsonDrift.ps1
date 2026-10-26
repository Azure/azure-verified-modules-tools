function Get-AvmBicepCompiledJsonDrift {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $CompiledJson,

        [AllowNull()]
        [byte[]] $CurrentBytes
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $expectedText = Get-AvmBicepCompiledJsonComparisonText -Json $CompiledJson -Description 'Bicep compiler output'
    if ($null -eq $CurrentBytes) {
        return 'missing'
    }

    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    try { $currentText = $encoding.GetString($CurrentBytes) }
    catch [System.Text.DecoderFallbackException] {
        throw [AvmConfigurationException]::new('Checked-in main.json must contain valid UTF-8.')
    }
    if ([string]::IsNullOrWhiteSpace($currentText)) {
        throw [AvmConfigurationException]::new('Checked-in main.json contains no JSON.')
    }
    $currentText = Get-AvmBicepCompiledJsonComparisonText -Json $currentText -Description 'Checked-in main.json'
    if (-not [System.Linq.Enumerable]::SequenceEqual(
            [byte[]]$encoding.GetBytes($currentText), [byte[]]$encoding.GetBytes($expectedText))) {
        return 'stale'
    }

    return $null
}
