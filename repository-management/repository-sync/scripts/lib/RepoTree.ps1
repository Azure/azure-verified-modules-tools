# Single fetch of the target repo's default-branch tree, returned in a shape
# the deprecated-files cleanup and the import bootstrap both consume.
#
# The previous implementation called `gh api repos/<>` plus
# `gh api repos/<>/git/trees/<branch>?recursive=1` twice per sync (once for
# cleanup, once for bootstrap). Consolidating to one call halves the GitHub
# REST traffic per repo and removes a class of race conditions where the
# default branch could change between the two reads.

function Get-RepositoryGitBlobSha {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes)

    $module = Get-Module Avm.Authoring | Select-Object -First 1
    if (-not $module) {
        throw [System.InvalidOperationException]::new('Import Avm.Authoring before comparing repository file blobs.')
    }
    return & $module {
        param([byte[]] $ContentBytes)
        Get-AvmGitBlobSha -Bytes $ContentBytes
    } $Bytes
}

function Get-RepositoryFileAtCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string] $Sha
    )

    Set-StrictMode -Version 3.0
    $file = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/contents/$($Path)?ref=$Sha"
    if ($file.type -cne 'file' -or $file.path -cne $Path -or $file.encoding -cne 'base64' -or
        $file.sha -cnotmatch '^[0-9a-f]{40}$' -or $file.size -lt 0) {
        throw [System.IO.InvalidDataException]::new("GitHub did not return a complete regular file for $Repository/$Path.")
    }
    $bytes = [System.Convert]::FromBase64String($file.content)
    if ($bytes.Length -ne $file.size -or (Get-RepositoryGitBlobSha -Bytes $bytes) -cne $file.sha) {
        throw [System.IO.InvalidDataException]::new("GitHub file size or blob SHA mismatch for $Repository/$Path.")
    }
    return [pscustomobject]@{
        Content = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        Sha = $file.sha
    }
}

function Get-RepositoryBranchHead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Branch
    )

    Set-StrictMode -Version 3.0
    $references = @(Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository/git/matching-refs/heads/$Branch")
    foreach ($reference in $references) {
        if (-not $reference.ref.StartsWith("refs/heads/$Branch", [System.StringComparison]::Ordinal) -or
            $reference.object.type -cne 'commit' -or $reference.object.sha -cnotmatch '^[0-9a-f]{40}$') {
            throw [System.IO.InvalidDataException]::new('GitHub returned invalid branch references.')
        }
    }
    $exact = @($references | Where-Object { $_.ref -ceq "refs/heads/$Branch" })
    if ($exact.Count -gt 1) {
        throw [System.IO.InvalidDataException]::new('GitHub returned ambiguous branch references.')
    }
    if ($exact.Count -eq 1) {
        return $exact[0].object.sha
    }
}

function Get-RepositoryDefaultBranchTree {
    param(
        [string]$orgAndRepoName
    )

    $repoInfo = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName")
                OutputLog = "repo-info.json"
            }

        ) `
        -returnOutputParsedFromJson

    if (!$repoInfo -or !$repoInfo.success -or !$repoInfo.output.default_branch) {
        Write-Warning "Failed to fetch repo info for $orgAndRepoName (success=$($repoInfo.success), default_branch='$($repoInfo.output.default_branch)')."
        return @{
            Success       = $false
            DefaultBranch = $null
            BlobPaths     = @()
            Blobs         = @{}
            Modes         = @{}
        }
    }

    $defaultBranch = $repoInfo.output.default_branch

    $treeResult = Invoke-GitHubCliWithRetry `
        -commands @(
            @{
                Arguments = @("api", "repos/$orgAndRepoName/git/trees/$($defaultBranch)?recursive=1")
                OutputLog = "repo-tree.json"
            }
        ) `
        -returnOutputParsedFromJson

    if (!$treeResult -or !$treeResult.success -or !$treeResult.output.tree) {
        Write-Warning "Failed to fetch git tree for $orgAndRepoName (success=$($treeResult.success), tree_count=$($treeResult.output.tree.Count))."
        return @{
            Success       = $false
            DefaultBranch = $defaultBranch
            BlobPaths     = @()
            Blobs         = @{}
            Modes         = @{}
        }
    }

    $blobEntries = @($treeResult.output.tree | Where-Object { $_.type -eq "blob" })
    $blobPaths = @($blobEntries | ForEach-Object { $_.path })
    # `Blobs` lets the managed-files sync detect updates by comparing each
    # source file's locally-computed git blob SHA to the SHA already on the
    # default branch, so we only open a PR for files that actually differ.
    # `Modes` carries the tree-entry mode ("100644" / "100755") so the sync
    # also catches executable-bit drift between this governance repo and
    # the target, even when the file contents are identical.
    $blobs = @{}
    $modes = @{}
    foreach ($entry in $blobEntries) {
        $blobs[$entry.path] = $entry.sha
        $modes[$entry.path] = $entry.mode
    }

    return @{
        Success       = $true
        DefaultBranch = $defaultBranch
        BlobPaths     = $blobPaths
        Blobs         = $blobs
        Modes         = $modes
    }
}
