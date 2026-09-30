function Get-AvmBicepMonorepoRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $directory = Get-AvmExistingDirectory -Path $Path
    while ($directory) {
        $signature = Get-AvmContextRootSignature -Path $directory
        if ($signature.HasBicepMonorepo) {
            return $directory
        }
        $parent = Split-Path -Path $directory -Parent
        if (-not $parent -or $parent -ceq $directory) { break }
        $directory = $parent
    }
    return $null
}
