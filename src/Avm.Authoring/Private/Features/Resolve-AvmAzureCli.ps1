function Resolve-AvmAzureCli {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $command = Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command -or -not [System.IO.Path]::IsPathRooted([string]$command.Source)) {
        throw [AvmToolException]::new(
            "Azure CLI is required to register features. Install 'az' and authenticate to the selected test subscription.")
    }

    $path = $command.Source
    $arguments = [string[]]@()
    $environment = @{}
    if ($IsWindows -and [System.IO.Path]::GetExtension($path) -ieq '.cmd') {
        if ([System.IO.Path]::GetFileName($path) -cne 'az.cmd') {
            throw [AvmToolException]::new("Unsupported Azure CLI wrapper '$path'. Install Azure CLI for Windows.")
        }
        $python = Join-Path (Split-Path -Parent (Split-Path -Parent $path)) 'python.exe'
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
            throw [AvmToolException]::new(
                "Azure CLI's Windows MSI Python executable was not found next to '$path'. Repair the Azure CLI installation.")
        }
        $path = $python
        $arguments = [string[]]@('-IBm', 'azure.cli')
        $environment = @{ AZ_INSTALLER = 'MSI' }
    }

    return [pscustomobject]@{
        Path           = $path
        ArgumentPrefix = $arguments
        EnvVars        = $environment
    }
}
