#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $OutputPath,
    [ValidatePattern('^[0-9a-f]{40}$')] [string] $SourceSha
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
Import-Module (Join-Path $repositoryRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -ErrorAction Stop
$sharedLib = Join-Path $repositoryRoot 'repository-management' 'repository-sync' 'scripts' 'lib'
. (Join-Path $sharedLib 'RetryHelpers.ps1')
. (Join-Path $sharedLib 'RepoTree.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Codeowners.ps1')
. (Join-Path $PSScriptRoot 'lib' 'CodeownersSync.ps1')

$templatePath = Join-Path $PSScriptRoot '..' 'CODEOWNERS.template'
$template = Get-Content -LiteralPath $templatePath -Raw
$parameters = @{ Template = $template }
if ($SourceSha) {
    $parameters.SourceSha = $SourceSha
}
$snapshot = Get-AvmBicepCodeownersSnapshot @parameters
$destination = [System.IO.Path]::GetFullPath($OutputPath)
if ($PSCmdlet.ShouldProcess($destination, 'Write locally generated CODEOWNERS; no remote mutations')) {
    [System.IO.File]::WriteAllText($destination, $snapshot.Content, [System.Text.UTF8Encoding]::new($false))
}
[pscustomobject]@{
    Path = $destination
    SourceSha = $snapshot.SourceSha
    MetadataShas = $snapshot.MetadataShas
    BlobSha = $snapshot.BlobSha
    ModuleCount = $snapshot.ModuleCount
    TemplateSha256 = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
}
