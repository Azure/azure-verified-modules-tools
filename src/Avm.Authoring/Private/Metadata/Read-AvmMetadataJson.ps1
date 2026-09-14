function Read-AvmMetadataJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    try {
        return [System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($Path))
    }
    catch [System.Text.DecoderFallbackException] {
        throw [System.ArgumentException]::new('Metadata must be valid UTF-8 without a byte-order mark.', $_.Exception)
    }
}
