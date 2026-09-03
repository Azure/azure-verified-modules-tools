function Invoke-AvmTerraformInit {
    <#
    .SYNOPSIS
        Initialize a Terraform working directory safely.

    .DESCRIPTION
        Runs terraform init -upgrade and serializes calls that share
        TF_PLUGIN_CACHE_DIR.
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

        [switch] $NoColor,

        [string] $TestDirectory,

        [switch] $SkipPluginCacheLock,

        [switch] $StreamOutput
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('init')
    $arguments.Add('-upgrade')
    $arguments.Add('-input=false')
    if ($NoColor) {
        $arguments.Add('-no-color')
    }
    if (-not [string]::IsNullOrWhiteSpace($TestDirectory)) {
        $arguments.Add(('-test-directory={0}' -f $TestDirectory))
    }

    $processParameters = @{
        FilePath         = $TerraformPath
        ArgumentList     = $arguments.ToArray()
        WorkingDirectory = $WorkingDirectory
        EnvVars          = $EnvVars
        Label            = $Label
        StreamOutput     = $StreamOutput
    }

    $lock = $null
    try {
        if (-not $SkipPluginCacheLock) {
            $lock = Lock-AvmTerraformPluginCache `
                -WorkingDirectory $WorkingDirectory `
                -EnvVars $EnvVars
        }

        Invoke-AvmProcess @processParameters
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}
