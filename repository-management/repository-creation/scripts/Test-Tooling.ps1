#Requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

foreach ($command in @("git", "gh")) {
    if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
        throw [System.InvalidOperationException]::new(
            "Required command '$command' was not found on PATH."
        )
    }
}

& gh auth status
if ($LASTEXITCODE -ne 0) {
    throw [System.InvalidOperationException]::new(
        "GitHub CLI is not authenticated. Run 'gh auth login'."
    )
}

Write-Host "Repository creation prerequisites are available."
