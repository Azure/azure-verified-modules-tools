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

function Invoke-AvmPreCommitForRepository {
    param(
        [string]$orgAndRepoName,
        [string]$repoId,
        [string]$repositoryConfigDir,
        [string]$defaultBranch,
        [bool]$planOnly,
        [array]$issueLog
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog = $issueLog
        HasChanges = $false
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

        Push-Location $tempDir
        try {
            $upgradeDecision = Resolve-AvmManagedFilesUpgradeDecision `
                -orgAndRepoName $orgAndRepoName `
                -repoRoot $tempDir
            Write-Host "$modeTag $orgAndRepoName - managed files: $($upgradeDecision.Reason)." -ForegroundColor DarkGray

            $preCommitResult = Invoke-AvmPreCommitWithUpgradeRetry `
                -repoId $repoId `
                -repositoryConfigDir $repositoryConfigDir `
                -upgradeManagedFiles $upgradeDecision.Upgrade
            Assert-AvmPreCommitResult -preCommitResult $preCommitResult

            $status = git status --porcelain
            $result.HasChanges = -not [string]::IsNullOrWhiteSpace($status)
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
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
            $branchName = "avm-bot/pre-commit-$timestamp"
            $prTitle = "chore: run avm pre-commit [skip ci]"
            $prBody = @"
Automated ``avm pre-commit`` run from [azure-verified-modules-tools](https://github.com/Azure/azure-verified-modules-tools).

This PR is opened and merged by the AVM bot. ``[skip ci]`` is set on the commit so downstream workflows are not retriggered.
"@

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
