function Expand-AvmWindowsTarArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ArchivePath,

        [Parameter(Mandatory)]
        [string] $TargetDir
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    $pendingLinks = [System.Collections.Generic.List[object]]::new()
    $archiveStream = [System.IO.File]::OpenRead($ArchivePath)
    try {
        $gzipStream = [System.IO.Compression.GZipStream]::new(
            $archiveStream,
            [System.IO.Compression.CompressionMode]::Decompress,
            $true)
        try {
            $reader = [System.Formats.Tar.TarReader]::new($gzipStream, $true)
            try {
                while ($null -ne ($entry = $reader.GetNextEntry())) {
                    $destination = Resolve-AvmArchiveEntryPath `
                        -TargetDir $TargetDir `
                        -EntryName $entry.Name

                    if ($entry.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory) {
                        New-Item -ItemType Directory -Path $destination -Force | Out-Null
                        continue
                    }

                    if (
                        $entry.EntryType -eq [System.Formats.Tar.TarEntryType]::RegularFile -or
                        $entry.EntryType -eq [System.Formats.Tar.TarEntryType]::V7RegularFile -or
                        $entry.EntryType -eq [System.Formats.Tar.TarEntryType]::ContiguousFile
                    ) {
                        if ([string]::Equals(
                                $destination,
                                [System.IO.Path]::GetFullPath($TargetDir),
                                [System.StringComparison]::OrdinalIgnoreCase)) {
                            throw [System.IO.InvalidDataException]::new(
                                "Archive file entry '$($entry.Name)' resolves to the extraction root.")
                        }

                        $parent = [System.IO.Path]::GetDirectoryName($destination)
                        if (-not (Test-Path -LiteralPath $parent)) {
                            New-Item -ItemType Directory -Path $parent -Force | Out-Null
                        }
                        $outputStream = [System.IO.File]::Open(
                            $destination,
                            [System.IO.FileMode]::Create,
                            [System.IO.FileAccess]::Write,
                            [System.IO.FileShare]::None)
                        try {
                            if ($null -ne $entry.DataStream) {
                                $entry.DataStream.CopyTo($outputStream)
                            }
                        }
                        finally {
                            $outputStream.Dispose()
                        }
                        continue
                    }

                    if (
                        $entry.EntryType -eq [System.Formats.Tar.TarEntryType]::SymbolicLink -or
                        $entry.EntryType -eq [System.Formats.Tar.TarEntryType]::HardLink
                    ) {
                        $pendingLinks.Add([pscustomobject]@{
                                Destination = $destination
                                EntryName   = $entry.Name
                                EntryType   = $entry.EntryType
                                LinkName    = $entry.LinkName
                            })
                        continue
                    }

                    if (
                        $entry.EntryType -eq [System.Formats.Tar.TarEntryType]::GlobalExtendedAttributes -or
                        $entry.EntryType -eq [System.Formats.Tar.TarEntryType]::ExtendedAttributes
                    ) {
                        continue
                    }

                    throw [System.IO.InvalidDataException]::new(
                        "Archive entry '$($entry.Name)' has unsupported type '$($entry.EntryType)'.")
                }
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $gzipStream.Dispose()
        }
    }
    finally {
        $archiveStream.Dispose()
    }

    while ($pendingLinks.Count -gt 0) {
        $resolvedCount = 0
        for ($index = $pendingLinks.Count - 1; $index -ge 0; $index--) {
            $link = $pendingLinks[$index]
            $targetEntryName = if (
                $link.EntryType -eq [System.Formats.Tar.TarEntryType]::SymbolicLink
            ) {
                $parentName = [System.IO.Path]::GetDirectoryName(
                    $link.EntryName.Replace('\', '/').Replace(
                        '/',
                        [System.IO.Path]::DirectorySeparatorChar))
                [System.IO.Path]::Combine($parentName, $link.LinkName)
            }
            else {
                $link.LinkName
            }

            $source = Resolve-AvmArchiveEntryPath `
                -TargetDir $TargetDir `
                -EntryName $targetEntryName
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                continue
            }

            $parent = [System.IO.Path]::GetDirectoryName($link.Destination)
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [System.IO.File]::Copy($source, $link.Destination, $true)
            $pendingLinks.RemoveAt($index)
            $resolvedCount++
        }

        if ($resolvedCount -eq 0) {
            $unresolved = $pendingLinks |
                ForEach-Object { "'$($_.EntryName)' -> '$($_.LinkName)'" }
            throw [System.IO.InvalidDataException]::new(
                "Archive contains unresolved file links: $($unresolved -join ', ').")
        }
    }
}
