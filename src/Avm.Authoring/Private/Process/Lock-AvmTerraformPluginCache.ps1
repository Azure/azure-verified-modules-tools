function Lock-AvmTerraformPluginCache {
    <#
    .SYNOPSIS
        Lock the effective Terraform provider plugin cache.

    .DESCRIPTION
        Returns an exclusive cache lock when TF_PLUGIN_CACHE_DIR is configured.
        Returns no value when Terraform is using per-working-directory providers.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [hashtable] $EnvVars,

        [int] $TimeoutSec = 600
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $pluginCache = if ($null -ne $EnvVars -and $EnvVars.ContainsKey('TF_PLUGIN_CACHE_DIR')) {
        [string] $EnvVars['TF_PLUGIN_CACHE_DIR']
    }
    else {
        [string] $env:TF_PLUGIN_CACHE_DIR
    }
    if ([string]::IsNullOrWhiteSpace($pluginCache)) {
        return
    }

    $cachePath = [System.IO.Path]::GetFullPath($pluginCache, $WorkingDirectory)
    Lock-AvmToolCache `
        -LockFile (Join-Path $cachePath '.avm-terraform.lock') `
        -TimeoutSec $TimeoutSec
}
