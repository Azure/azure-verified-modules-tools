function Invoke-AvmTerraformInit {
    <#
    .SYNOPSIS
        Initialize a Terraform working directory safely.

    .DESCRIPTION
        Runs terraform init -upgrade and serializes calls that share
        TF_PLUGIN_CACHE_DIR. When the caller and process environment do not
        configure a provider cache, uses the AVM cache so repeated lint,
        policy, and validation initializations reuse provider binaries.
        Terraform's provider plugin cache is not concurrency-safe, while working
        directories without a shared cache can initialize independently.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $TerraformPath,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [hashtable] $EnvVars,

        [string] $Label,

        [switch] $BackendFalse,

        [switch] $NoColor,

        [switch] $IgnoreExitCode,

        [switch] $SkipPluginCacheLock,

        [switch] $StreamOutput
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('init')
    $arguments.Add('-upgrade')
    $arguments.Add('-input=false')
    if ($BackendFalse) {
        $arguments.Add('-backend=false')
    }
    if ($NoColor) {
        $arguments.Add('-no-color')
    }

    $effectiveEnvironment = if ($null -eq $EnvVars) { @{} } else { $EnvVars.Clone() }
    if (-not $effectiveEnvironment.ContainsKey('TF_PLUGIN_CACHE_DIR')) {
        $effectiveEnvironment.TF_PLUGIN_CACHE_DIR = Get-AvmTerraformPluginCachePath
    }

    $processParameters = @{
        FilePath            = $TerraformPath
        ArgumentList        = $arguments.ToArray()
        WorkingDirectory    = $WorkingDirectory
        EnvVars             = $effectiveEnvironment
        Label               = $Label
        StreamOutput        = $StreamOutput
        RetryNetworkFailure = $true
        IgnoreExitCode      = $IgnoreExitCode
    }

    $lock = $null
    try {
        if (-not $SkipPluginCacheLock) {
            $lock = Lock-AvmTerraformPluginCache `
                -WorkingDirectory $WorkingDirectory `
                -EnvVars $effectiveEnvironment
        }

        Invoke-AvmProcess @processParameters
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}
