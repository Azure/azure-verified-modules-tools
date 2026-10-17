function Assert-AvmPowerShellModuleArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Version
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $stream = $entry.Open()
            try { $stream.CopyTo([System.IO.Stream]::Null) }
            finally { $stream.Dispose() }
        }
        $manifests = @($archive.Entries | Where-Object { $_.FullName -ceq "$Name.psd1" })
        $metadata = @($archive.Entries | Where-Object { $_.FullName -notmatch '[/\\]' -and $_.FullName.EndsWith('.nuspec') })
        if ($manifests.Count -ne 1 -or $metadata.Count -ne 1) {
            throw [AvmToolException]::new(
                "Downloaded module '$Name' requires exactly one root manifest and NuGet metadata file.", 'AVM1013')
        }
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $stream = $metadata[0].Open()
        try {
            $reader = [System.Xml.XmlReader]::Create($stream, $settings)
            try {
                $document = [System.Xml.XmlDocument]::new()
                $document.XmlResolver = $null
                $document.Load($reader)
            }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
        $root = "/*[local-name()='package']/*[local-name()='metadata']"
        $identities = $document.SelectNodes("$root/*[local-name()='id']")
        $versions = $document.SelectNodes("$root/*[local-name()='version']")
        if ($identities.Count -ne 1 -or $versions.Count -ne 1 -or
            $identities[0].InnerText -ine $Name -or $versions[0].InnerText -cne $Version) {
            throw [AvmToolException]::new(
                "Downloaded package does not identify '$Name' $Version.", 'AVM1013')
        }
    }
    finally { $archive.Dispose() }
}
