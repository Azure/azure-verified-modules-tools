function Get-AvmBicepDocsConfiguration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $directory = [System.IO.Path]::GetFullPath($ModulePath)
    $configPath = $null
    while ($directory) {
        $candidate = Join-Path -Path $directory -ChildPath 'bicepconfig.json'
        if (Test-Path -LiteralPath $candidate) {
            $file = Get-Item -LiteralPath $candidate -Force
            if ($file.PSIsContainer -or $file.Name -cne 'bicepconfig.json' -or
                ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                throw [AvmConfigurationException]::new(
                    "Bicep documentation needs a regular, exactly cased bicepconfig.json: $candidate")
            }
            $configPath = $file.FullName
            break
        }
        $parent = [System.IO.Directory]::GetParent($directory)
        $directory = if ($null -ne $parent) { $parent.FullName } else { $null }
    }
    if (-not $configPath) {
        throw [AvmConfigurationException]::new(
            "No bicepconfig.json was found for '$ModulePath'. Add a repository-owned bicepconfig.json with documentation.template.file and a tracked AVM template before running 'avm docs'.")
    }

    try {
        $config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new(
            "Cannot parse Bicep documentation config '$configPath': $($_.Exception.Message)")
    }
    if ($config -isnot [System.Collections.IDictionary] -or
        $config['documentation'] -isnot [System.Collections.IDictionary] -or
        $config['documentation']['template'] -isnot [System.Collections.IDictionary] -or
        $config['documentation']['template']['file'] -isnot [string] -or
        [string]::IsNullOrWhiteSpace($config['documentation']['template']['file'])) {
        throw [AvmConfigurationException]::new(
            "Bicep documentation config '$configPath' must set documentation.template.file to a tracked, versioned AVM Scriban template. Add the repository-owned template and config; 'avm docs' never edits them.")
    }

    $relative = [string]$config['documentation']['template']['file']
    if ([System.IO.Path]::IsPathRooted($relative) -or [uri]::IsWellFormedUriString($relative, [UriKind]::Absolute)) {
        throw [AvmConfigurationException]::new(
            "documentation.template.file in '$configPath' must be relative to that config, not an installed-module or remote path.")
    }

    $template = Get-AvmBicepDocsTemplate
    $path = [System.IO.Path]::GetFullPath((Join-Path -Path $directory -ChildPath $relative))
    if ([System.IO.Path]::GetFileName($path) -cne $template.Name -or
        -not [System.IO.File]::Exists($path)) {
        throw [AvmConfigurationException]::new(
            "Bicep documentation config '$configPath' must point to a tracked copy of '$($template.Name)' relative to the config; '$relative' is missing or has the wrong version.")
    }
    $file = Get-Item -LiteralPath $path -Force
    if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw [AvmConfigurationException]::new("Bicep documentation template must be a regular file: $path")
    }
    $digest = [System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($path))
    $hash = [Convert]::ToHexString($digest).ToLowerInvariant()
    if ($hash -cne $template.Hash) {
        throw [AvmConfigurationException]::new(
            "Bicep documentation template '$path' differs from the packaged $($template.Version) template. Review and copy the canonical '$($template.Path)' into the repository before rendering; 'avm docs' does not overwrite tracked templates.")
    }

    return [pscustomobject]@{
        ConfigPath   = $configPath
        TemplatePath = $path
        Version      = $template.Version
        Hash         = $hash
    }
}
