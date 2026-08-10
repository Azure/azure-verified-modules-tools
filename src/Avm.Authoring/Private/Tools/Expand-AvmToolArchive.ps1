function Expand-AvmToolArchive {
    <#
    .SYNOPSIS
        Unpack a downloaded tool archive into a target directory.

    .DESCRIPTION
        Handles the three archive kinds supported by avm.pins.jsonc:
            - 'zip'     -> Expand-Archive
            - 'tar.gz'  -> tar -xzf (requires GNU/BSD tar on PATH)
            - 'raw'     -> Copy-Item (single-binary archives)

        The target directory must already exist. On 'raw' the file is copied
        to '<TargetDir>/<EntrypointBasename>' so callers can stat predictable
        paths without round-tripping the archive's own filename.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)] [string] $ArchivePath,
        [Parameter(Mandatory)] [ValidateSet('zip', 'tar.gz', 'raw')] [string] $Archive,
        [Parameter(Mandatory)] [string] $TargetDir,
        [Parameter(Mandatory)] [string] $EntrypointBasename
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        throw [System.IO.DirectoryNotFoundException]::new(
            "Expand-AvmToolArchive: TargetDir does not exist: $TargetDir")
    }

    Write-AvmLog ("archive: expanding {0} from {1} to {2}" -f $Archive, $ArchivePath, $TargetDir) -Level Verbose | Out-Null
    switch ($Archive) {
        'zip' {
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $TargetDir -Force
        }
        'tar.gz' {
            $tar = Get-Command -Name 'tar' -ErrorAction SilentlyContinue
            if (-not $tar) {
                throw [System.IO.FileNotFoundException]::new(
                    "Expand-AvmToolArchive: 'tar' is not on PATH; required for tar.gz archives.")
            }
            & $tar.Source -xzf $ArchivePath -C $TargetDir
            if ($LASTEXITCODE -ne 0) {
                Write-AvmLog ("archive: tar failed with exit code {0}" -f $LASTEXITCODE) -Level Verbose | Out-Null
                throw [System.IO.IOException]::new(
                    "tar -xzf failed with exit code $LASTEXITCODE for $ArchivePath.")
            }
        }
        'raw' {
            $finalName = if ($IsWindows) { "$EntrypointBasename.exe" } else { $EntrypointBasename }
            $dest = Join-Path $TargetDir $finalName
            Copy-Item -LiteralPath $ArchivePath -Destination $dest -Force
            if (-not $IsWindows) {
                & chmod 755 $dest 2>$null
                Write-AvmLog ("archive: set executable mode on {0}" -f $dest) -Level Verbose | Out-Null
            }
        }
    }
    Write-AvmLog ("archive: expansion completed for {0}" -f $ArchivePath) -Level Verbose | Out-Null
}
