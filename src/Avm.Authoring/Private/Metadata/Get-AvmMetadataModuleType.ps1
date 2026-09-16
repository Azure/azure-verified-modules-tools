function Get-AvmMetadataModuleType {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject] $Context,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Metadata
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $kinds = @{ res = 'resource'; ptn = 'pattern'; utl = 'utility' }
    if ($Context.PSObject.Properties['Scope'] -and $kinds.ContainsKey([string]$Context.Scope)) {
        return $kinds[[string]$Context.Scope]
    }
    $pattern = if ($Context.Ecosystem -eq 'bicep') {
        '(?:^|[\\/])avm[\\/](?<kind>res|ptn|utl)[\\/]'
    }
    else {
        '^(?:terraform-(?:azurerm|azapi|azure)-)?avm-(?<kind>res|ptn|utl)-'
    }
    $identityPath = if ($Context.Ecosystem -eq 'bicep') { $Path } else { Split-Path -Leaf $Context.Root }
    $identity = [regex]::Match($identityPath, $pattern)
    if ($identity.Success) {
        return $kinds[$identity.Groups['kind'].Value]
    }
    if ($Context.Ecosystem -eq 'terraform' -and (Test-Path -LiteralPath (Join-Path $Context.Root '.git'))) {
        $git = Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $remote = Invoke-AvmProcess -FilePath $git.Source -ArgumentList @('config', '--get', 'remote.origin.url') `
            -WorkingDirectory $Context.Root -IgnoreExitCode
        if ($remote.ExitCode -notin @(0, 1)) {
            throw [System.IO.IOException]::new("Cannot read the local repository identity: $($remote.StdErr)")
        }
        $identity = [regex]::Match($remote.StdOut.Trim(), '(?:/|:)terraform-(?:azurerm|azapi|azure)-avm-(?<kind>res|ptn|utl)-[a-z0-9-]+(?:\.git)?$')
        if ($identity.Success) {
            return $kinds[$identity.Groups['kind'].Value]
        }
    }
    $prefix = [regex]::Match([string]$Metadata['telemetryIdPrefix'], '^46d3x(?:bcp|trf)\.(?<kind>res|ptn|utl)\.')
    if ($prefix.Success) {
        return $kinds[$prefix.Groups['kind'].Value]
    }
    if ([string]$Metadata['canonicalType'] -cmatch '^Microsoft\.') {
        return 'resource'
    }
    throw [System.ArgumentException]::new(
        "Cannot determine whether '$Path' is a resource, pattern, or utility module. Use its AVM path/repository name or declare Scope in .avm/context.psd1.")
}
