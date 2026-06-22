<#
.SYNOPSIS
    Run an Avm.Authoring Invoke-Build task from the repo root.

.DESCRIPTION
    Thin forwarder around `Invoke-Build` so contributors can use a stable
    command surface (`./build.ps1 <task>`) without remembering the path to the
    task graph at build/avm.build.ps1.

.EXAMPLE
    ./build.ps1 pre-commit
.EXAMPLE
    ./build.ps1 lint
.EXAMPLE
    ./build.ps1 ?      # list tasks
#>

#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]] $Tasks = @('.')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name 'InvokeBuild')) {
    throw @"
InvokeBuild is not installed.

Install it once (CurrentUser scope) and re-run:

    Install-PSResource -Name InvokeBuild -Scope CurrentUser

If you do not yet have PSResourceGet, see CONTRIBUTING.md section 1.
"@
}

$buildScript = Join-Path $PSScriptRoot 'build' 'avm.build.ps1'
if (-not (Test-Path -LiteralPath $buildScript)) {
    throw "Build script not found: $buildScript"
}

Invoke-Build -Task $Tasks -File $buildScript
