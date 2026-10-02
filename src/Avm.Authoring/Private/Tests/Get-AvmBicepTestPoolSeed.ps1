function Get-AvmBicepTestPoolSeed {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    return [Convert]::ToHexString($bytes).ToLowerInvariant()
}
