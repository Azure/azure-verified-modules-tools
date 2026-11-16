#Requires -Version 7.4

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-AvmBicepReleaseAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $TargetCommit
    )

    $module = Get-Module Avm.Authoring
    if ($null -eq $module) { throw [InvalidOperationException]::new('Import Avm.Authoring before auditing release readiness.') }
    $files = Invoke-AvmWorkflowPackagePrivate -Name Invoke-AvmBicepWorkflowGit -Parameters @{
        Root = $Root; Arguments = @('ls-tree', '-r', '--name-only', $TargetCommit, '--', 'avm')
    }
    $paths = @($files.StdOut -split '\r?\n' | Where-Object { $_ -cmatch '^avm/(res|ptn|utl)/.+/main\.json$' } |
            ForEach-Object { $_.Substring(0, $_.LastIndexOf('/')) } |
            Where-Object { Test-Path -LiteralPath (Join-Path $Root $_ 'version.json') -PathType Leaf } |
            Sort-Object)
    $tags = Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowRemoteTags -Parameters @{
        Root = $Root; Pattern = 'avm/*'
    }
    $pending = 0
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($path in $paths) {
        try {
            $plan = @(Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowPendingReleasePlanInternal -Parameters @{
                    Root = $Root; ModulePath = $path; TargetCommit = $TargetCommit; ExactModule = $true; RemoteTags = $tags
                })
            if ($plan.Count -eq 0) { continue }
            $pending++
            $proposals = @(Invoke-AvmWorkflowPackagePrivate -Name Get-AvmBicepWorkflowReleaseProposalsInternal -Parameters @{
                    Root = $Root; TargetCommit = $TargetCommit; Plan = $plan; RemoteTags = $tags
                })
            foreach ($proposal in $proposals) {
                Invoke-AvmWorkflowPackagePrivate -Name Assert-AvmBicepWorkflowReleaseChangelog -Parameters @{
                    Root = $Root; ModulePath = $proposal.Module
                    Version = $proposal.Tag.Substring($proposal.Module.Length + 1)
                }
                Write-Output "Ready: $($proposal.Tag)"
            }
        }
        catch {
            $message = "${path}: $($_.Exception.Message)"
            $failures.Add($message)
            Write-Output "Not ready: $message"
        }
    }
    Write-Output "Audited $($paths.Count) versioned modules; $pending pending; $($failures.Count) failed."
    if ($failures.Count -gt 0) {
        throw [InvalidOperationException]::new("Bicep release audit found $($failures.Count) module failure(s). See the per-module output above.")
    }
}
