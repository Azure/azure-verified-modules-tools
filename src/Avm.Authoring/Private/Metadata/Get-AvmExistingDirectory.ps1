function Get-AvmExistingDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    while (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        if (Test-Path -LiteralPath $directory -PathType Leaf) {
            throw [System.ArgumentException]::new("Module path contains a file instead of a directory: $directory")
        }
        $parent = Split-Path -Path $directory -Parent
        if (-not $parent -or $parent -ceq $directory) {
            throw [System.ArgumentException]::new("Cannot resolve an existing parent directory for: $Path")
        }
        $directory = $parent
    }
    return (Get-Item -LiteralPath $directory).FullName
}
