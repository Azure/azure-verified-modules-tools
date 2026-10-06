function Get-AvmToolCacheEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [hashtable] $Tool,
        [Parameter(Mandatory)] [string] $Platform
    )

    $directory = Join-Path -Path (Get-AvmFolder -Kind Tools) -ChildPath $Tool.name
    $overridden = $Tool.ContainsKey('versionOverride')
    if ($overridden) { $directory = Join-Path $directory '.overrides' }
    $directory = Join-Path $directory $Tool.version
    $marker = Join-Path $directory $(if ($overridden) { '.unverified' } else { '.verified' })
    $isModule = $Tool.ContainsKey('kind') -and $Tool.kind -ceq 'powershell-module'
    $name = if ($IsWindows -and -not $isModule) { "$($Tool.entrypoint).exe" } else { $Tool.entrypoint }
    $path = Join-Path $directory $name
    $cached = (Test-Path -LiteralPath $marker -PathType Leaf) -and
    (Test-Path -LiteralPath $path -PathType Leaf)
    if ($cached -and ($overridden -or $isModule)) {
        $metadataPath = Join-Path $directory '.meta.json'
        $cached = Test-Path -LiteralPath $metadataPath -PathType Leaf
        if ($cached) {
            try {
                $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            }
            catch [System.ArgumentException] {
                Write-AvmLog "Invalid cache metadata for '$($Tool.name)' at '$metadataPath'; reinstall the tool." -Level Warning | Out-Null
                $metadata = $null
            }
            $cached = $metadata -is [hashtable] -and
            $metadata['name'] -ceq $Tool.name -and $metadata['version'] -ceq $Tool.version
            if ($cached) {
                $cached = if ($overridden) {
                    $metadata['checksumVerified'] -is [bool] -and -not $metadata.checksumVerified -and
                    $metadata['urlTemplate'] -ceq $Tool.urlTemplate -and $null -eq $metadata['sha256']
                }
                else {
                    $metadata['sha256'] -ceq $Tool.sha256[$Platform] -and $metadata['checksumVerified'] -eq $true
                }
            }
        }
    }
    return [pscustomobject]@{ Directory = $directory; Path = $path; Marker = $marker; Cached = $cached }
}
