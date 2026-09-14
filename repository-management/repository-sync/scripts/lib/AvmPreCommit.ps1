function Assert-AvmPreCommitResult {
    param(
        [AllowNull()]
        [object]$preCommitResult
    )

    $status = if ($preCommitResult -and $preCommitResult.PSObject.Properties.Name -contains "Status") {
        [string]$preCommitResult.Status
    } else {
        "missing"
    }

    if ($status -eq "pass") {
        return
    }

    $failedSteps = @(
        if ($preCommitResult -and $preCommitResult.PSObject.Properties.Name -contains "Steps") {
            $preCommitResult.Steps |
                Where-Object { $_.Status -in @("fail", "error") } |
                ForEach-Object {
                    $step = $_
                    $stepSummary = if ([string]::IsNullOrWhiteSpace($step.Error)) {
                        "$($step.Step): $($step.Status)"
                    } else {
                        "$($step.Step): $($step.Status) - $($step.Error)"
                    }

                    $issueMessages = @(
                        if (
                            $step.PSObject.Properties.Name -contains "Result" -and
                            $step.Result -and
                            $step.Result.PSObject.Properties.Name -contains "Issues"
                        ) {
                            @($step.Result.Issues) |
                                ForEach-Object {
                                    $issue = $_
                                    if ($issue -is [string]) {
                                        $issue
                                    } elseif ($issue -and $issue.PSObject.Properties.Name -contains "Message") {
                                        [string]$issue.Message
                                    }
                                } |
                                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                        }
                    )

                    if ($issueMessages.Count -gt 0) {
                        "$stepSummary - Issues: $($issueMessages -join ' | ')"
                    } else {
                        $stepSummary
                    }
                }
        }
    )

    $detail = if ($failedSteps.Count -gt 0) {
        " Failed steps: $($failedSteps -join '; ')."
    } else {
        ""
    }
    throw "avm pre-commit returned status '$status'.$detail"
}

function Remove-AvmMetadataFileConflict {
    param(
        [string]$repoRoot,
        [string]$orgAndRepoName,
        [string]$modeTag
    )

    $avmPath = Join-Path $repoRoot ".avm"
    if (-not (Test-Path -LiteralPath $avmPath -PathType Leaf)) {
        return $false
    }

    Write-Host "$modeTag $orgAndRepoName - removing the root .avm file so the managed-files metadata directory can be created." -ForegroundColor Yellow
    Remove-Item -LiteralPath $avmPath -Force
    return $true
}

function Invoke-AvmPreCommitWithUpgradeRetry {
    param(
        [string]$repoId,
        [string]$repositoryConfigDir,
        [bool]$upgradeManagedFiles = $false
    )

    $preCommitParameters = @{
        Ecosystem       = "terraform"
        RepoId          = $repoId
        ConfigLocalPath = $repositoryConfigDir
    }

    if ($upgradeManagedFiles) {
        $preCommitParameters.Upgrade = $true
    }

    Import-Module Avm.Authoring -Force -ErrorAction Stop
    try {
        return Invoke-AvmPreCommit @preCommitParameters
    } catch {
        $exception = $_.Exception
        $isModuleUpgradeRequired = (
            $exception.PSObject.Properties.Name -contains "Code" -and
            [string]$exception.Code -eq "AVM1050"
        )
        if (-not $isModuleUpgradeRequired) {
            throw
        }

        Write-Host "A newer Avm.Authoring release became available. Upgrading the module and retrying avm pre-commit once." -ForegroundColor Yellow
        Update-PSResource -Name Avm.Authoring -Scope CurrentUser -TrustRepository -ErrorAction Stop | Out-Null
        Import-Module Avm.Authoring -Force -ErrorAction Stop
        return Invoke-AvmPreCommit @preCommitParameters
    }
}

function Get-AvmRepositoryMetadataBackfillContext {
    param([string]$orgAndRepoName)

    $toolsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' '..'))
    $adapterRoot = Join-Path $toolsRoot 'repository-management' 'module-metadata'
    . (Join-Path $adapterRoot 'MetadataBackfill.ps1')
    Import-Module Avm.Authoring -ErrorAction Stop
    Assert-AvmMetadataBackfillCapability
    $seedPath = Resolve-AvmMetadataBackfillSeedManifest -ToolsRoot $toolsRoot -Repository $orgAndRepoName
    $manifest = Read-AvmMetadataBackfillJson -Path $seedPath
    if ($manifest.repository -cne $orgAndRepoName -or $manifest.ecosystem -cne 'terraform' -or
        $manifest.reviewed -isnot [bool] -or -not $manifest.reviewed) {
        throw [System.ArgumentException]::new('Repository sync requires a reviewed Terraform seed manifest for the selected repository.')
    }
    return @{
        SeedPath = $seedPath
        ScriptPath = Join-Path $adapterRoot 'Invoke-ModuleMetadataBackfill.ps1'
    }
}

function Get-AvmMetadataBackfillReview {
    param(
        [string]$orgAndRepoName,
        [string]$branchName
    )

    $existing = Invoke-GitHubCliWithRetry `
        -commands @(@{
            Arguments = @('pr', 'list', "--repo=$orgAndRepoName", '--state=open', "--head=$branchName", '--json=number,url')
            OutputLog = 'gh-metadata-backfill-pr.output.log'
        }) `
        -errorLog 'gh-metadata-backfill-pr.error.log' -returnOutput
    if (-not $existing.success) {
        throw [System.InvalidOperationException]::new("Cannot check existing metadata backfill reviews: $($existing.error)")
    }
    $reviews = @(($existing.output -join "`n") | ConvertFrom-Json -ErrorAction Stop)
    if ($reviews.Count -gt 0) {
        return @{ Exists = $true; Reason = "An open metadata backfill review already exists: $($reviews[0].url)" }
    }
    $branches = Invoke-GitHubCliWithRetry `
        -commands @(@{
            Arguments = @('api', "repos/$orgAndRepoName/git/matching-refs/heads/$branchName")
            OutputLog = 'gh-metadata-backfill-branch.output.log'
        }) `
        -errorLog 'gh-metadata-backfill-branch.error.log' -returnOutput
    if (-not $branches.success) {
        throw [System.InvalidOperationException]::new("Cannot check existing metadata backfill branches: $($branches.error)")
    }
    $refs = @(($branches.output -join "`n") | ConvertFrom-Json -ErrorAction Stop)
    if (@($refs | Where-Object { $_.ref -ceq "refs/heads/$branchName" }).Count -gt 0) {
        return @{ Exists = $true; Reason = "Backfill branch '$branchName' already exists; review or clean it up manually. It will not be updated." }
    }
    return @{ Exists = $false; Reason = '' }
}

function Invoke-AvmPreCommitForRepository {
    param(
        [string]$orgAndRepoName,
        [string]$repoId,
        [string]$repositoryConfigDir,
        [string]$defaultBranch,
        [bool]$planOnly,
        [bool]$forceFileUpdate = $false,
        [bool]$metadataBackfill = $false,
        [bool]$metadataUpdateSource = $false,
        [array]$issueLog
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog = $issueLog
        HasChanges = $false
    }

    if ($metadataUpdateSource -and -not $metadataBackfill) {
        throw [System.ArgumentException]::new('metadataUpdateSource requires explicit metadataBackfill opt-in.')
    }
    $backfillContext = $null
    $backfillBranch = 'avm-bot/module-metadata-backfill'
    if ($metadataBackfill) {
        if ($env:GITHUB_EVENT_NAME -and $env:GITHUB_EVENT_NAME -ne 'workflow_dispatch') {
            throw [System.InvalidOperationException]::new('Metadata backfill is manual-only; scheduled and repository_dispatch runs cannot enable it.')
        }
        $backfillContext = Get-AvmRepositoryMetadataBackfillContext -orgAndRepoName $orgAndRepoName
        $review = Get-AvmMetadataBackfillReview -orgAndRepoName $orgAndRepoName -branchName $backfillBranch
        if ($review.Exists) {
            Write-Warning "$modeTag $orgAndRepoName - $($review.Reason)"
            $result.BackfillDeferred = $true
            return $result
        }
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-pre-commit-" + [System.Guid]::NewGuid().ToString())
    try {
        gh auth setup-git
        if ($LASTEXITCODE -ne 0) { throw "gh auth setup-git exited $LASTEXITCODE" }

        Write-Host "$modeTag Cloning $orgAndRepoName into $tempDir..." -ForegroundColor DarkGray
        $cloneResult = Invoke-GitHubCliWithRetry `
            -commands @(
                @{
                    Arguments = @("repo", "clone", $orgAndRepoName, "`"$tempDir`"", "--", "--quiet", "--depth", "1", "--branch", $defaultBranch)
                    OutputLog = "gh-clone.output.log"
                }
            ) `
            -errorLog "gh-clone.error.log" `
            -maxRetries 5 `
            -retryDelayIncremental 5 `
            -printOutputOnError
        if (!$cloneResult.success) {
            throw "gh repo clone exited $($cloneResult.exitCode): $($cloneResult.error)"
        }

        $null = Remove-AvmMetadataFileConflict `
            -repoRoot $tempDir `
            -orgAndRepoName $orgAndRepoName `
            -modeTag $modeTag

        Push-Location $tempDir
        try {
            $backfillHasPlannedChanges = $false
            if ($metadataBackfill) {
                $backfillResult = & $backfillContext.ScriptPath `
                    -RepositoryRoot $tempDir -Repository $orgAndRepoName `
                    -SeedManifestPath $backfillContext.SeedPath `
                    -UpdateSource:$metadataUpdateSource -WhatIf:$planOnly
                if ($backfillResult.Status -notin @('pass', 'planned')) {
                    throw [System.InvalidOperationException]::new("Metadata backfill returned '$($backfillResult.Status)'.")
                }
                $backfillHasPlannedChanges = @($backfillResult.Modules | Where-Object { $_.PlannedFiles.Count -gt 0 }).Count -gt 0
                $result.MetadataBackfill = $backfillResult
            }

            $upgradeDecision = Resolve-AvmManagedFilesUpgradeDecision `
                -orgAndRepoName $orgAndRepoName `
                -repoRoot $tempDir `
                -forceFileUpdate $forceFileUpdate
            Write-Host "$modeTag $orgAndRepoName - managed files: $($upgradeDecision.Reason)." -ForegroundColor DarkGray

            $preCommitResult = Invoke-AvmPreCommitWithUpgradeRetry `
                -repoId $repoId `
                -repositoryConfigDir $repositoryConfigDir `
                -upgradeManagedFiles $upgradeDecision.Upgrade
            Assert-AvmPreCommitResult -preCommitResult $preCommitResult

            $status = git status --porcelain
            $result.HasChanges = -not [string]::IsNullOrWhiteSpace($status) -or $backfillHasPlannedChanges
            if (-not $result.HasChanges) {
                Write-Host "$modeTag $orgAndRepoName - avm pre-commit produced no changes."
                return $result
            }

            Write-Host "$modeTag $orgAndRepoName - avm pre-commit produced changes:" -ForegroundColor Cyan
            git status --short

            if ($planOnly) {
                Write-Host "$modeTag Plan mode is enabled; not opening a pre-commit PR."
                return $result
            }

            $commitAuthorName = "azure-verified-modules[bot]"
            $commitAuthorEmail = "1049636+azure-verified-modules[bot]@users.noreply.github.com"
            if ($metadataBackfill) {
                $branchName = $backfillBranch
                $prTitle = 'chore: backfill module metadata'
                $prBody = @"
One-off metadata backfill from the reviewed seed manifest in [azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools), followed by the ordinary authoring pre-commit checks.

Existing metadata is preserved. Source reader changes require both the reviewed seed flag and explicit source-wiring opt-in. Review every root and child identity, description, owner handle, and telemetry prefix before merging.

CI remains enabled. This change is never automatically merged. Legacy metadata sources remain in place for the 60-day dual-source migration.
"@
            } else {
                $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
                $branchName = "avm-bot/pre-commit-$timestamp"
                $prTitle = "chore: run avm pre-commit [skip ci]"
                $prBody = @"
Automated ``avm pre-commit`` run from [azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools).

This PR is opened and merged by the AVM bot. ``[skip ci]`` is set on the commit so downstream workflows are not retriggered.
"@
            }

            git checkout -q -b $branchName
            if ($LASTEXITCODE -ne 0) { throw "git checkout -b $branchName exited $LASTEXITCODE" }

            git add --all
            if ($LASTEXITCODE -ne 0) { throw "git add --all exited $LASTEXITCODE" }

            git -c "user.name=$commitAuthorName" -c "user.email=$commitAuthorEmail" commit -q -m $prTitle
            if ($LASTEXITCODE -ne 0) { throw "git commit exited $LASTEXITCODE" }

            git push --quiet --set-upstream origin $branchName
            if ($LASTEXITCODE -ne 0) { throw "git push exited $LASTEXITCODE" }

            $prBodyFile = Join-Path $tempDir "pr-body.md"
            Set-Content -LiteralPath $prBodyFile -Value $prBody -Encoding utf8
            $prCreateResult = Invoke-GitHubCliWithRetry `
                -commands @(
                    @{
                        Arguments = @(
                            "pr", "create",
                            "--repo=$orgAndRepoName",
                            "--base=$defaultBranch",
                            "--head=$branchName",
                            "--title=`"$prTitle`"",
                            "--body-file=`"$prBodyFile`""
                        )
                        OutputLog = "gh-pr-create.output.log"
                    }
                ) `
                -errorLog "gh-pr-create.error.log" `
                -maxRetries 5 `
                -retryDelayIncremental 5 `
                -printOutputOnError `
                -returnOutput
            if (!$prCreateResult.success) {
                throw "gh pr create exited $($prCreateResult.exitCode): $($prCreateResult.error)"
            }

            $prUrl = (@($prCreateResult.output) | Where-Object { $_ -and $_.ToString().Trim() -ne "" } | Select-Object -Last 1).ToString().Trim()
            if ([string]::IsNullOrWhiteSpace($prUrl)) { throw "gh pr create returned no URL on stdout" }
            Write-Host "Opened PR: $prUrl" -ForegroundColor DarkGray

            if ($metadataBackfill) {
                $result.BackfillReviewUrl = $prUrl
                Write-Host "Metadata backfill awaits human review and CI: $prUrl" -ForegroundColor Yellow
                return $result
            }

            $prMergeResult = Invoke-GitHubCliWithRetry `
                -commands @(
                    @{
                        Arguments = @(
                            "pr", "merge", $prUrl,
                            "--repo=$orgAndRepoName",
                            "--squash",
                            "--admin",
                            "--delete-branch",
                            "--subject=`"$prTitle`"",
                            "--body="
                        )
                        OutputLog = "gh-pr-merge.output.log"
                    }
                ) `
                -errorLog "gh-pr-merge.error.log" `
                -maxRetries 5 `
                -retryDelayIncremental 5 `
                -printOutputOnError
            if (!$prMergeResult.success) {
                throw "gh pr merge exited $($prMergeResult.exitCode): $($prMergeResult.error)"
            }
            Write-Host "Merged PR: $prUrl" -ForegroundColor Green
        } finally {
            Pop-Location
        }
    } catch {
        Write-Error "avm pre-commit failed for $orgAndRepoName. Administrative corrective action is required. $($_.Exception.Message)"
        throw
    } finally {
        if (Test-Path $tempDir) {
            try {
                Get-ChildItem -Path $tempDir -Recurse -Force | ForEach-Object {
                    try { $_.Attributes = "Normal" } catch { }
                }
                Remove-Item -Recurse -Force $tempDir
            } catch {
                Write-Warning "Failed to clean up $tempDir : $_"
            }
        }
    }

    return $result
}
