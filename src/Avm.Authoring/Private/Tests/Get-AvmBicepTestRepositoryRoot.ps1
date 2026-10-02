function Get-AvmBicepTestRepositoryRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [string] $RepositoryRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
            throw [AvmConfigurationException]::new("Bicep test repository root must be a directory: $RepositoryRoot")
        }
        $item = Get-Item -LiteralPath $RepositoryRoot -ErrorAction Stop
        return $item.FullName
    }

    if ($Context.Kind -eq 'bicep-monorepo') {
        return $Context.Root
    }

    $directory = [System.IO.DirectoryInfo]::new($Context.Root)
    while ($null -ne $directory) {
        if ($directory.Name -ceq 'avm' -and $null -ne $directory.Parent -and
            (Test-Path -LiteralPath (Join-Path $directory.Parent.FullName 'bicepconfig.json') -PathType Leaf)) {
            return $directory.Parent.FullName
        }
        $directory = $directory.Parent
    }

    return $Context.Root
}
