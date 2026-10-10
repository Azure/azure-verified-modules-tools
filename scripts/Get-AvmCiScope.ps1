#Requires -Version 7.4

[CmdletBinding()]
param(
    [ValidateSet('pull_request', 'push', 'workflow_dispatch')]
    [string] $EventName = $env:GITHUB_EVENT_NAME,

    [string] $EventPath = $env:GITHUB_EVENT_PATH
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'build' 'AvmCi.ps1')
$payload = Get-Content -LiteralPath $EventPath -Raw | ConvertFrom-Json -AsHashtable

if ($EventName -eq 'workflow_dispatch') {
    $scope = 'all'
    if ($payload.Contains('inputs') -and $null -ne $payload.inputs -and $payload.inputs.Contains('scope')) {
        $scope = [string]$payload.inputs.scope
    }
    if ($scope -eq 'auto') {
        throw [System.ArgumentException]::new('Manual CI requires an explicit scope, not a fabricated file diff.')
    }
    return Get-AvmCiScope -Scope $scope
}

if ($EventName -eq 'push' -and $payload.before -cmatch '^0{40}$') {
    Write-Information 'The push has no previous commit; selecting every CI scope.' -InformationAction Continue
    return Get-AvmCiScope -Scope all
}

$base = if ($EventName -eq 'pull_request') { $payload.pull_request.base.sha } else { $payload.before }
$head = if ($EventName -eq 'pull_request') { $payload.pull_request.head.sha } else { $payload.after }
$paths = @(Get-AvmCiChangedPath -RepositoryRoot $repositoryRoot -Base $base -Head $head `
        -PullRequest:($EventName -eq 'pull_request'))
Get-AvmCiScope -ChangedPath $paths
