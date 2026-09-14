. (Join-Path $PSScriptRoot 'RepositoryFileSync.ps1')

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

function Invoke-AvmPreCommitForRepository {
    param(
        [string]$orgAndRepoName,
        [string]$repoId,
        [string]$repositoryConfigDir,
        [string]$defaultBranch,
        [bool]$planOnly,
        [bool]$forceFileUpdate = $false,
        [array]$issueLog
    )

    try {
        Import-Module Avm.Authoring -ErrorAction Stop
        $prepareState = @{
            RepoId = $repoId
            RepositoryConfigDir = $repositoryConfigDir
            ForceFileUpdate = $forceFileUpdate
        }
        $result = Invoke-RepositoryFileSync -Repository $orgAndRepoName -DefaultBranch $defaultBranch `
            -PlanOnly:$planOnly -State $prepareState -Prepare {
                param($context)
                $mode = if ($context.PlanOnly) { '[PLAN]' } else { '[APPLY]' }
                $null = Remove-AvmMetadataFileConflict -repoRoot $context.Root -orgAndRepoName $context.Repository.full_name -modeTag $mode
                $upgrade = Resolve-AvmManagedFilesUpgradeDecision -orgAndRepoName $context.Repository.full_name `
                    -repoRoot $context.Root -forceFileUpdate $context.State.ForceFileUpdate
                Write-Host "$mode $($context.Repository.full_name) - managed files: $($upgrade.Reason)." -ForegroundColor DarkGray
                $prepared = Invoke-AvmPreCommitWithUpgradeRetry -repoId $context.State.RepoId `
                    -repositoryConfigDir $context.State.RepositoryConfigDir -upgradeManagedFiles $upgrade.Upgrade
                Assert-AvmPreCommitResult -preCommitResult $prepared
            }
        return @{ IssueLog = $issueLog; HasChanges = $result.HasChanges }
    } catch {
        Write-Error "avm pre-commit failed for $orgAndRepoName. Administrative corrective action is required. $($_.Exception.Message)"
        throw
    }
}
