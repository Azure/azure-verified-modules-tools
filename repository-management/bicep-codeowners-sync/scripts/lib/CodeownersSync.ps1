function Get-AvmBicepCodeownersSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Template,
        [ValidatePattern('^[0-9a-f]{40}$')] [string] $SourceSha
    )

    Set-StrictMode -Version 3.0
    if (-not $SourceSha) {
        $source = Invoke-RepositoryGitHubApi -Endpoint 'repos/Azure/Azure-Verified-Modules/commits/main'
        $SourceSha = $source.sha
    }
    if ($SourceSha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.IO.InvalidDataException]::new('The official index commit is missing or invalid.')
    }
    $names = @{ res = 'BicepResourceModules.csv'; ptn = 'BicepPatternModules.csv'; utl = 'BicepUtilityModules.csv' }
    $indexes = @{}
    $indexShas = @{}
    foreach ($kind in @('res', 'ptn', 'utl')) {
        $file = Get-RepositoryFileAtCommit -Repository 'Azure/Azure-Verified-Modules' `
            -Path "docs/static/module-indexes/$($names[$kind])" -Sha $SourceSha
        $indexes[$kind] = $file.Content
        $indexShas[$kind] = $file.Sha
    }
    $content = ConvertTo-AvmBicepCodeowners -Indexes $indexes -Template $Template
    return [pscustomobject]@{
        Content = $content
        SourceSha = $SourceSha
        IndexShas = $indexShas
        BlobSha = Get-RepositoryGitBlobSha -Bytes ([System.Text.Encoding]::UTF8.GetBytes($content))
        ModuleCount = @($content.Split("`n") | Where-Object { $_ -cmatch '^/avm/(res|ptn|utl)/' }).Count
    }
}

function Test-BicepCodeownersSyncChange {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Context)

    Set-StrictMode -Version 3.0
    $sha = if ($Context.Phase -eq 'Base') { $Context.BaseSha } else { $Context.HeadSha }
    $file = Get-RepositoryFileAtCommit -Repository 'Azure/bicep-registry-modules' -Path '.github/CODEOWNERS' -Sha $sha
    $existing = $Context.Phase -in @('Base', 'Existing')
    Assert-AvmCodeownersContent -Content $file.Content -Template $Context.State.Template -AllowLegacyDefault:$existing
    if ($existing) { return }
    if ($file.Content -cne $Context.State.Snapshot.Content -or $file.Sha -cne $Context.State.Snapshot.BlobSha) {
        throw [System.InvalidOperationException]::new('The synchronized CODEOWNERS does not exactly match the generated content.')
    }
    if ($Context.Phase -eq 'Candidate') {
        $diagnostics = Invoke-RepositoryGitHubApi -Endpoint "repos/Azure/bicep-registry-modules/codeowners/errors?ref=$sha"
        if (@($diagnostics.errors).Count -gt 0) {
            throw [System.InvalidOperationException]::new("GitHub rejected CODEOWNERS owners or syntax in $($Context.PullRequest.html_url); the candidate remains open: $($diagnostics.errors | ConvertTo-Json -Compress)")
        }
        if (-not $Context.PlanOnly) {
            $prerequisite = Invoke-RepositoryGitHubApi -Endpoint 'repos/Azure/bicep-registry-modules/pulls/7343'
            if (-not $prerequisite.merged -or $prerequisite.base.ref -cne 'main' -or
                $prerequisite.base.repo.id -ne $Context.Repository.id -or
                $prerequisite.base.repo.full_name -cne 'Azure/bicep-registry-modules') {
                throw [System.InvalidOperationException]::new('Merge https://github.com/Azure/bicep-registry-modules/pull/7343 before enabling CODEOWNERS merging.')
            }
        }
    }
}

function Invoke-AvmBicepCodeownersSync {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Template,
        [switch] $PlanOnly
    )

    $snapshot = Get-AvmBicepCodeownersSnapshot -Template $Template
    $result = Invoke-RepositoryFileSync -Repository 'Azure/bicep-registry-modules' -DefaultBranch main `
        -GeneratedFiles @{ '.github/CODEOWNERS' = $snapshot.Content } -AllowedPaths @('.github/CODEOWNERS') `
        -StableBranch 'avm-bot/bicep-codeowners-sync' -OpenPlanPullRequest -KeepBranch -VerifyCandidate -PlanOnly:$PlanOnly `
        -ExpectedActor ([pscustomobject]@{ login = 'azure-verified-modules[bot]'; id = 187664033; type = 'Bot' }) `
        -State @{ Template = $Template; Snapshot = $snapshot } -ValidateChange ${function:Test-BicepCodeownersSyncChange} `
        -Title 'chore: sync Bicep module CODEOWNERS' `
        -CommitMessage "chore: sync Bicep module CODEOWNERS`n`nOfficial AVM index snapshot: $($snapshot.SourceSha)" `
        -Body 'Generated from the official AVM Bicep indexes and the tools repository CODEOWNERS.template. The commit records the source snapshot. Only .github/CODEOWNERS changes; plan-only runs never merge.'
    $result['SourceSha'] = $snapshot.SourceSha
    $result['ModuleCount'] = $snapshot.ModuleCount
    return [pscustomobject]$result
}
