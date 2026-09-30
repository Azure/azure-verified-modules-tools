#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Validate', 'Publish')] [string]$Mode,
    [Parameter(Mandatory)] [string]$Repository,
    [Parameter(Mandatory)] [string]$CandidateDirectory,
    [Parameter(Mandatory)] [string]$ReceiptDirectory
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'RepositoryCandidate.ps1')

$modulePath = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
if ($Mode -eq 'Validate') {
    $status = Invoke-RepositorySyncCandidateValidation -Repository $Repository `
        -CandidateDirectory $CandidateDirectory -ReceiptDirectory $ReceiptDirectory `
        -CheckoutModulePath $modulePath
    Write-Host "Repository candidate validation: $status."
}
else {
    Import-Module -Name $modulePath -ErrorAction Stop
    $result = Invoke-RepositorySyncCandidatePublication -Repository $Repository `
        -CandidateDirectory $CandidateDirectory -ReceiptDirectory $ReceiptDirectory
    Write-Host "Repository candidate publication: $($result.Status)."
}
