#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot '..' 'config.json'),
    [string] $GitHubOutputPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ModuleCatalog.ps1')

$configuration = Read-AvmCatalogConfiguration -Path $ConfigurationPath
if ($env:GITHUB_ACTIONS -eq 'true' -and $env:GITHUB_REPOSITORY -cne $configuration.repositories.tools) {
    throw [System.InvalidOperationException]::new('The catalog manifest does not identify the trusted workflow repository.')
}
$outputs = [ordered]@{
    'documentation-repository' = $configuration.repositories.docs
    'bicep-repository' = $configuration.repositories.bicep
    'tools-repository' = $configuration.repositories.tools
    'owner' = $configuration.repositories.tools.Split('/')[0]
    'publication-repositories' = @(
        foreach ($destination in $configuration.destinations.Values) {
            $configuration.repositories[$destination.repository].Split('/')[1]
        }
    ) -join ','
}
if ($GitHubOutputPath -and $PSCmdlet.ShouldProcess($GitHubOutputPath, 'Write validated catalog workflow outputs')) {
    $lines = @($outputs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
    [System.IO.File]::AppendAllText($GitHubOutputPath, "$lines`n", [System.Text.UTF8Encoding]::new($false))
}
[pscustomobject]$outputs
