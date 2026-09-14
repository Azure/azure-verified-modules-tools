#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param([switch] $PlanOnly)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..'))
Import-Module (Join-Path $repositoryRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'lib' 'Codeowners.ps1')
. (Join-Path $PSScriptRoot 'lib' 'GitHubSync.ps1')

$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'CODEOWNERS.template') -Raw
$action = if ($PlanOnly) { 'Open or update the CODEOWNERS plan pull request without merging' } else { 'Synchronize and app-bypass merge only .github/CODEOWNERS' }
if ($PSCmdlet.ShouldProcess('Azure/bicep-registry-modules', $action)) {
    $result = Invoke-AvmBicepCodeownersSync -Template $template -PlanOnly:$PlanOnly
    $result | ConvertTo-Json -Depth 5
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = @(
            "CODEOWNERS sync: **$($result.Status)**"
            ''
            "Source index commit: ``$($result.SourceSha)``"
            "Module rows: $($result.ModuleCount)"
        )
        if ($result.PullRequestUrl) {
            $summary += "Pull request: $($result.PullRequestUrl)"
        }
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($summary -join "`n") -Encoding utf8NoBOM
    }
}
