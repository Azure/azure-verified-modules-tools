function Get-AvmTerraformPluginCachePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $pluginCache = [string]$env:TF_PLUGIN_CACHE_DIR
    if ([string]::IsNullOrWhiteSpace($pluginCache)) {
        $pluginCache = Join-Path (Get-AvmFolder -Kind Cache) 'terraform-plugin-cache'
    }
    $pluginCache = [System.IO.Path]::GetFullPath($pluginCache)
    $null = New-Item -ItemType Directory -Path $pluginCache -Force -ErrorAction Stop
    return $pluginCache
}
