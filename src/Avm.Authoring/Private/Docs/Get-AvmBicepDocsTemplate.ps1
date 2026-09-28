function Get-AvmBicepDocsTemplate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version 3.0
    $name = 'avm-readme-v1.scriban'
    $path = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath @('..', 'Resources', 'bicep', $name)))
    if (-not [System.IO.File]::Exists($path)) {
        throw [AvmConfigurationException]::new("The packaged Bicep documentation template is missing: $path")
    }

    $bytes = [System.IO.File]::ReadAllBytes($path)
    $digest = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [pscustomobject]@{
        Name    = $name
        Version = 'v1'
        Path    = $path
        Hash    = [Convert]::ToHexString($digest).ToLowerInvariant()
    }
}
