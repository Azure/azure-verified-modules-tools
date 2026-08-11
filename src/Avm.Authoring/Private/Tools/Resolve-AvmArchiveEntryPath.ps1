function Resolve-AvmArchiveEntryPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TargetDir,

        [Parameter(Mandatory)]
        [string] $EntryName
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($EntryName)) {
        throw [System.IO.InvalidDataException]::new('Archive entries must have a non-empty name.')
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $normalisedName = $EntryName.Replace('\', '/').Replace('/', $separator)
    if ([System.IO.Path]::IsPathRooted($normalisedName)) {
        throw [System.IO.InvalidDataException]::new(
            "Archive entry '$EntryName' uses an absolute path.")
    }

    $root = [System.IO.Path]::GetFullPath($TargetDir)
    $candidate = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($root, $normalisedName))
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $rootPrefix = $root.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) + $separator

    if (
        -not [string]::Equals($candidate, $root, $comparison) -and
        -not $candidate.StartsWith($rootPrefix, $comparison)
    ) {
        throw [System.IO.InvalidDataException]::new(
            "Archive entry '$EntryName' escapes the extraction root.")
    }

    return $candidate
}
