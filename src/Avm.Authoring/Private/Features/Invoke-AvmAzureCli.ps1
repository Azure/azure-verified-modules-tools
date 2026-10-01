function Invoke-AvmAzureCli {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Cli,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $Operation,

        [string] $PermissionHint = ''
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $arguments = [string[]]@($Cli.ArgumentPrefix) + $ArgumentList
    try {
        return Invoke-AvmProcess -FilePath $Cli.Path -ArgumentList $arguments `
            -WorkingDirectory $Root -EnvVars $Cli.EnvVars -TimeoutSec 60 -Label $Operation
    }
    catch [AvmProcessException] {
        throw [AvmException]::new(
            "Azure CLI could not $Operation. $PermissionHint$($_.Exception.Message)",
            'AVM1070',
            $_.Exception)
    }
}
