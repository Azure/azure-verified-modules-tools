function Read-AvmBicepCleanupState {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw [AvmConfigurationException]::new('Cleanup state must be a regular, unlinked file.')
    }
    $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false, $true))
    try {
        $state = ConvertFrom-AvmMetadataJson -Json $content
    }
    catch [System.ArgumentException] {
        throw [AvmConfigurationException]::new('Cleanup state must be a strict JSON object without duplicate properties.')
    }
    return ConvertTo-AvmBicepCleanupState -State $state
}
