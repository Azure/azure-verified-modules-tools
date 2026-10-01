function Get-AvmBicepTestPoolIndex {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Count
    )

    return [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($Count)
}
