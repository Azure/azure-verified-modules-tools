function Get-AvmBicepCodeownersSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Template,
        [ValidatePattern('^[0-9a-f]{40}$')] [string] $SourceSha
    )

    Set-StrictMode -Version 3.0
    if (-not $SourceSha) {
        $source = Invoke-RepositoryGitHubApi -Endpoint 'repos/Azure/bicep-registry-modules/commits/main'
        $SourceSha = $source.sha
    }
    if ($SourceSha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.IO.InvalidDataException]::new('The Bicep source commit is missing or invalid.')
    }
    $tree = Invoke-RepositoryGitHubApi -Endpoint "repos/Azure/bicep-registry-modules/git/trees/${SourceSha}?recursive=1"
    if ($tree.sha -cne $SourceSha) {
        throw [System.IO.InvalidDataException]::new('GitHub did not return the requested Bicep source tree.')
    }
    if ($tree.truncated) {
        throw [System.IO.InvalidDataException]::new('The Bicep source tree was truncated; cannot enumerate every module metadata.json.')
    }
    $metadataEntries = @(
        $tree.tree | Where-Object { $_.type -ceq 'blob' -and $_.path -cmatch '^avm/(res|ptn|utl)/[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*/metadata\.json$' }
    )
    if ($metadataEntries.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new('No top-level Bicep module metadata.json files were discovered.')
    }
    $moduleTypes = @{ res = 'resource'; ptn = 'pattern'; utl = 'utility' }
    $modules = [System.Collections.Generic.List[object]]::new()
    $metadataShas = @{}
    $sortedEntries = @($metadataEntries | Sort-Object -Property path)
    $files = Get-RepositoryFilesAtCommit -Repository 'Azure/bicep-registry-modules' -Sha $SourceSha -Paths @($sortedEntries | ForEach-Object { $_.path })
    foreach ($entry in $sortedEntries) {
        $segments = $entry.path.Split('/')
        $kind = $segments[1]
        $name = "avm/$kind/$($segments[2])/$($segments[3])"
        $file = $files[$entry.path]
        if (-not $file -or $file.Sha -cne $entry.sha) {
            throw [System.IO.InvalidDataException]::new("The checked-out blob SHA for '$name' metadata.json does not match the resolved tree.")
        }
        $metadataShas[$name] = $file.Sha
        try {
            $metadata = ConvertFrom-Json -InputObject $file.Content -AsHashtable -Depth 30
        }
        catch {
            throw [System.IO.InvalidDataException]::new("The metadata.json for '$name' is not valid JSON.", $_.Exception)
        }
        $validation = Test-AvmModuleMetadata -InputObject $metadata -Ecosystem bicep -ModuleType $moduleTypes[$kind]
        if ($validation.Status -cne 'pass') {
            $detail = ($validation.Issues | ForEach-Object { $_.Message }) -join ' '
            throw [System.IO.InvalidDataException]::new("The metadata.json for '$name' is invalid: $detail")
        }
        $modules.Add([pscustomobject]@{ Name = $name; Owners = @($validation.Metadata.owners) })
    }
    $content = ConvertTo-AvmBicepCodeowners -Modules $modules.ToArray() -Template $Template
    return [pscustomobject]@{
        Content = $content
        SourceSha = $SourceSha
        MetadataShas = $metadataShas
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
        -VerifyCandidate -PlanOnly:$PlanOnly `
        -ExpectedActor ([pscustomobject]@{ login = 'azure-verified-modules[bot]'; id = 187664033; type = 'Bot' }) `
        -State @{ Template = $Template; Snapshot = $snapshot } -ValidateChange ${function:Test-BicepCodeownersSyncChange} `
        -Title 'chore: sync Bicep module CODEOWNERS' `
        -CommitMessage "chore: sync Bicep module CODEOWNERS`n`nModule metadata.json snapshot: $($snapshot.SourceSha)" `
        -Body 'Generated from each root module''s metadata.json owners and the tools repository CODEOWNERS.template. The commit records the source snapshot. Only .github/CODEOWNERS changes; plan-only runs never publish.'
    $result['SourceSha'] = $snapshot.SourceSha
    $result['ModuleCount'] = $snapshot.ModuleCount
    return [pscustomobject]$result
}
