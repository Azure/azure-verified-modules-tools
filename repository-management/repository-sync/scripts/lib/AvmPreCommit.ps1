. (Join-Path $PSScriptRoot 'RepositoryFileSync.ps1')
. (Join-Path $PSScriptRoot 'TerraformCodeowners.ps1')

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

function Add-RepositorySyncManagedFiles {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [object]$PreCommitResult
    )

    $steps = $PreCommitResult.PSObject.Properties['Steps']
    if ($null -eq $steps) {
        return
    }
    $sync = @($steps.Value | Where-Object { $null -ne $_ -and $_.Step -ceq 'sync' })
    if ($sync.Count -eq 0) {
        return
    }
    if ($sync.Count -ne 1 -or $sync[0].Status -cne 'pass' -or
        $null -eq $sync[0].Result -or $null -eq $sync[0].Result.PSObject.Properties['Added']) {
        throw [System.IO.InvalidDataException]::new('The managed-file sync did not return its added-file list.')
    }

    $added = @($sync[0].Result.Added)
    foreach ($path in $added) {
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path) -or
            $path -cmatch '(^/|\\|(^|/)\.\.?(/|$)|(^|/)\.git(/|$)|[\r\n])' -or
            $path -cmatch '^[A-Za-z]:') {
            throw [System.IO.InvalidDataException]::new('The managed-file sync returned an unsafe added path.')
        }
        $fullPath = Join-Path $Root ($path.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw [System.IO.InvalidDataException]::new("The managed-file sync did not create '$path'.")
        }
    }
    if ($added.Count -gt 0) {
        $null = Invoke-RepositoryGit -WorkingDirectory $Root -Arguments (@('add', '--force', '--') + $added)
    }
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
        [bool]$upgradeManagedFiles = $false,
        [string]$modulePath
    )

    $preCommitParameters = @{
        Ecosystem       = "terraform"
        RepoId          = $repoId
        ConfigLocalPath = $repositoryConfigDir
    }

    if ($upgradeManagedFiles) {
        $preCommitParameters.Upgrade = $true
    }
    if ($modulePath) {
        $preCommitParameters.SkipModuleVersionCheck = $true
    }

    $moduleName = if ($modulePath) { $modulePath } else { 'Avm.Authoring' }
    Import-Module -Name $moduleName -Force -ErrorAction Stop
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
        if ($modulePath) {
            throw [System.InvalidOperationException]::new('The checked-out Avm.Authoring source cannot be replaced by a Gallery upgrade during a plan-only preview.')
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
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [ValidateNotNull()]
        [string[]]$codeOwnersDefaultTeams,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [ValidateNotNull()]
        [string[]]$codeOwnersFileProtectionTeams,
        [string]$defaultBranch,
        [bool]$planOnly,
        [bool]$forceFileUpdate = $false,
        [string]$candidateOutputDirectory,
        [string]$authoringModulePath,
        [array]$issueLog
    )

    $result = @{ IssueLog = $issueLog; HasChanges = $false }

    try {
        if ($authoringModulePath -and -not $planOnly) {
            throw [System.ArgumentException]::new('Checked-out Avm.Authoring source is only supported for plan-only repository sync.')
        }
        $moduleName = if ($authoringModulePath) { $authoringModulePath } else { 'Avm.Authoring' }
        Import-Module -Name $moduleName -ErrorAction Stop
        $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'CODEOWNERS.template') -Raw -ErrorAction Stop
        $codeowners = ConvertTo-TerraformCodeowners -Organization $orgAndRepoName.Split('/')[0] `
            -DefaultTeams $codeOwnersDefaultTeams -FileProtectionTeams $codeOwnersFileProtectionTeams -Template $template
        $prepareState = @{
            RepoId = $repoId
            RepositoryConfigDir = $repositoryConfigDir
            ForceFileUpdate = $forceFileUpdate
            CodeownersContent = $codeowners
            AuthoringModulePath = $authoringModulePath
            StageManagedFiles = (-not $planOnly -or -not [string]::IsNullOrWhiteSpace($candidateOutputDirectory))
        }
        $published = Invoke-RepositoryFileSync -Repository $orgAndRepoName -DefaultBranch $defaultBranch `
            -PlanOnly:$planOnly -CandidateOutputDirectory $candidateOutputDirectory -State $prepareState -Prepare {
                param($context)
                $mode = if ($context.PlanOnly) { '[PLAN]' } else { '[APPLY]' }
                $null = Remove-AvmMetadataFileConflict -repoRoot $context.Root -orgAndRepoName $context.Repository.full_name -modeTag $mode
                $upgrade = Resolve-AvmManagedFilesUpgradeDecision -orgAndRepoName $context.Repository.full_name `
                    -repoRoot $context.Root -forceFileUpdate $context.State.ForceFileUpdate
                Write-Host "$mode $($context.Repository.full_name) - managed files: $($upgrade.Reason)." -ForegroundColor DarkGray
                $prepared = Invoke-AvmPreCommitWithUpgradeRetry -repoId $context.State.RepoId `
                    -repositoryConfigDir $context.State.RepositoryConfigDir -upgradeManagedFiles $upgrade.Upgrade `
                    -modulePath $context.State.AuthoringModulePath
                Assert-AvmPreCommitResult -preCommitResult $prepared
                if ($context.State.StageManagedFiles) {
                    Add-RepositorySyncManagedFiles -Root $context.Root -PreCommitResult $prepared
                }
                Set-TerraformCodeowners -RepositoryRoot $context.Root -Content $context.State.CodeownersContent
            }
        if ($candidateOutputDirectory -and $published.HasChanges) {
            $manifestPath = Join-Path $candidateOutputDirectory 'candidate.json'
            $candidate = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
            $module = (Get-Command -Name Invoke-AvmPreCommit -CommandType Function -ErrorAction Stop).Module
            if (-not $module) {
                throw [System.InvalidOperationException]::new('The candidate has no loaded Avm.Authoring module version.')
            }
            $candidate.authoringSource = if ($authoringModulePath) { 'checkout' } else { 'gallery' }
            $candidate.authoringVersion = $module.Version.ToString()
            [System.IO.File]::WriteAllText(
                $manifestPath,
                (ConvertTo-Json -InputObject $candidate -Depth 8) + "`n",
                [System.Text.UTF8Encoding]::new($false))
        }
        $result.HasChanges = $published.HasChanges
        return $result
    } catch {
        Write-Error "avm pre-commit failed for $orgAndRepoName. Administrative corrective action is required. $($_.Exception.Message)"
        throw
    }
}
