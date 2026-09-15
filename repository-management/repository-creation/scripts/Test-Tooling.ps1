#Requires -Version 7.4

[CmdletBinding()]
param([System.Management.Automation.PSModuleInfo] $AuthoringModule)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'RepositoryCreation.ps1')
if ($null -eq $AuthoringModule) {
    $AuthoringModule = Import-AvmRepositoryCreationModule
}

foreach ($command in @("git", "gh")) {
    if (-not (Get-Command -Name $command -CommandType Application -ErrorAction SilentlyContinue)) {
        throw [System.InvalidOperationException]::new(
            "Required command '$command' was not found on PATH."
        )
    }
}

$null = Invoke-AvmRepositoryCreationProcess -AuthoringModule $AuthoringModule -Tool gh `
    -ArgumentList @('auth', 'status') -WorkingDirectory $PWD.Path

Write-Host "Repository creation prerequisites are available."
