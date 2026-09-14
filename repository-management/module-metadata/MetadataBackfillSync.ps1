. (Join-Path $PSScriptRoot 'MetadataBackfill.ps1')

function Assert-AvmMetadataBackfillTrigger {
    if ($env:GITHUB_EVENT_NAME -and $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch') {
        throw [System.InvalidOperationException]::new('Metadata backfill is manual-only; scheduled and repository_dispatch runs cannot enable it.')
    }
}

function Get-AvmMetadataBackfillActor {
    return [pscustomobject]@{ login = 'azure-verified-modules[bot]'; id = 187664033; type = 'Bot' }
}

function Get-AvmRepositoryMetadataBackfillContext {
    param(
        [Parameter(Mandatory)][string] $orgAndRepoName,
        [ValidateSet('bicep', 'terraform')][string] $Ecosystem = 'terraform'
    )

    $toolsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module Avm.Authoring -ErrorAction Stop
    Assert-AvmMetadataBackfillCapability
    $seedPath = Resolve-AvmMetadataBackfillSeedManifest -ToolsRoot $toolsRoot -Repository $orgAndRepoName
    $manifest = Read-AvmMetadataBackfillJson -Path $seedPath
    if ($manifest.repository -cne $orgAndRepoName -or $manifest.ecosystem -cne $Ecosystem -or
        $manifest.reviewed -isnot [bool] -or -not $manifest.reviewed) {
        throw [System.ArgumentException]::new("Repository sync requires a reviewed $Ecosystem seed manifest for the selected repository.")
    }
    return @{
        SeedPath = $seedPath
        Manifest = $manifest
        ScriptPath = Join-Path $PSScriptRoot 'Invoke-ModuleMetadataBackfill.ps1'
    }
}

function Get-AvmMetadataBackfillReview {
    param([string] $orgAndRepoName, [string] $branchName)

    $reviews = @(Invoke-RepositoryGitHub -AsJson -Arguments @(
            'pr', 'list', "--repo=$orgAndRepoName", '--state=open', "--head=$branchName", '--json=number,url'
        ))
    if ($reviews.Count -gt 0) {
        return @{ Exists = $true; Reason = "An open metadata backfill review already exists: $($reviews[0].url)" }
    }
    $head = Get-RepositoryBranchHead -Repository $orgAndRepoName -Branch $branchName
    if ($head) {
        return @{ Exists = $true; Reason = "Backfill branch '$branchName' already exists; review or clean it up manually. It will not be updated." }
    }
    return @{ Exists = $false; Reason = '' }
}

function Invoke-AvmMetadataBackfillPreparation {
    param([Parameter(Mandatory)][hashtable] $Context)

    $backfill = $Context.State.BackfillContext
    $result = & $backfill.ScriptPath -RepositoryRoot $Context.Root `
        -Repository $Context.Repository.full_name -SeedManifestPath $backfill.SeedPath `
        -UpdateSource:$Context.State.UpdateSource -Confirm:$false
    if ($result.Status -cne 'pass') {
        throw [System.InvalidOperationException]::new("Metadata backfill preparation returned '$($result.Status)'.")
    }
    return $result
}

function Invoke-AvmBicepMetadataBackfillSync {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch] $PlanOnly, [switch] $UpdateSource)

    Assert-AvmMetadataBackfillTrigger
    $repository = 'Azure/bicep-registry-modules'
    $backfill = Get-AvmRepositoryMetadataBackfillContext -orgAndRepoName $repository -Ecosystem bicep
    $branch = 'avm-bot/bicep-metadata-backfill'
    if (-not $PSCmdlet.ShouldProcess($repository, 'Prepare reviewed Bicep metadata backfill')) {
        return [pscustomobject]@{ Status = 'Preview'; HasChanges = $false; PullRequestUrl = $null; HeadSha = $null }
    }
    $review = Get-AvmMetadataBackfillReview -orgAndRepoName $repository -branchName $branch
    if ($review.Exists) {
        Write-Warning $review.Reason
        return [pscustomobject]@{ Status = 'Deferred'; HasChanges = $false; PullRequestUrl = $null; HeadSha = $null }
    }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $backfill.Manifest.modules) {
        $paths.Add("$($entry.path)/metadata.json")
        if ($UpdateSource -and $entry.updateSource) {
            $paths.Add("$($entry.path)/main.bicep")
        }
    }
    if ($paths.Count -eq 0) {
        throw [System.ArgumentException]::new('Bicep metadata backfill requires a nonempty reviewed seed manifest.')
    }
    $state = @{ BackfillContext = $backfill; UpdateSource = $UpdateSource.IsPresent }
    $result = Invoke-RepositoryFileSync -Repository $repository -DefaultBranch main `
        -PlanOnly:$PlanOnly -ReviewOnly -StableBranch $branch -VerifyCandidate -FullCheckout `
        -ExpectedActor (Get-AvmMetadataBackfillActor) -AllowedPaths $paths.ToArray() -State $state `
        -Prepare {
            param($context)
            $context.State.BackfillResult = Invoke-AvmMetadataBackfillPreparation -Context $context
        } `
        -Title 'chore: backfill Bicep module metadata' `
        -Body 'One-off Bicep metadata backfill from reviewed tools-repository seeds. All snapshot owner handles are retained and children inherit root ownership. Existing metadata is preserved. Review every changed module before merging. CI remains enabled and this change is never automatically merged.'
    if ($state.ContainsKey('BackfillResult')) {
        $result['ModuleCount'] = @($state.BackfillResult.Modules).Count
    }
    return [pscustomobject]$result
}
