function Publish-AvmTerraformRepositoryContent {
    <#
    .SYNOPSIS
        Publish the first commit of a Terraform module repository from a clean staging checkout.
    .DESCRIPTION
        Clones the repository's main branch into a temporary directory, adds
        metadata.json and the packaged minimal scaffold, and runs avm
        pre-commit to add the current managed files, telemetry, and README.
        Nothing else from the caller's directory is published, and main must
        hold only the files the open source portal seeds. Organization rulesets
        require pull requests on main, so the push runs with
        global-rulesets-opt-out temporarily set to true. The original value is
        recorded in the user's state folder first and restored afterwards; a
        failed restore is retried by the next avm init run. A value that is
        already true stops the publication because its original value is
        unknown, and a repository that repository sync manages is refused
        because its own ruleset requires a pull request. Returns Status
        'pass', 'planned', 'blocked' (main has other content), or 'fail'
        (avm pre-commit failed).
    .PARAMETER Repository
        Repository as owner/name.
    .PARAMETER RepositoryId
        The repository's GitHub ID, stored in the opt-out record.
    .PARAMETER MetadataPath
        Validated metadata.json to publish unchanged.
    .PARAMETER Metadata
        The validated metadata values, used to render the scaffold.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [long] $RepositoryId,

        [Parameter(Mandatory)]
        [string] $MetadataPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Metadata
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $result = { param($Status, $Commit, $PreCommit, $Files) [pscustomobject]@{ Status = $Status; Commit = $Commit; PreCommit = $PreCommit; Files = @($Files) } }
    if (-not $PSCmdlet.ShouldProcess($Repository, 'Publish the initial module commit to main')) {
        return (& $result 'planned' $null $null @())
    }
    # The steps below are parts of this confirmed operation and work in a temporary clone.
    $ConfirmPreference = 'None'
    $recordPath = Get-AvmRulesetOptOutRecordPath -Repository $Repository
    if (Test-Path -LiteralPath $recordPath) {
        throw [System.InvalidOperationException]::new(
            "An earlier global-rulesets-opt-out change on $Repository has not been restored. Run avm init again.")
    }
    if (Test-AvmRepositorySyncManaged -Repository $Repository) {
        throw [AvmConfigurationException]::new(
            "Repository sync already protects main on $Repository, so avm init cannot push the first commit. " +
            'Add metadata.json and the module files with a pull request, then run avm init again.')
    }

    $staging = Join-Path -Path (Get-AvmFolder -Kind Temp) -ChildPath ('avm-init-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $checkout = Join-Path -Path $staging -ChildPath ($Repository -split '/')[-1]
    $null = New-Item -ItemType Directory -Path $staging
    try {
        $null = Invoke-AvmGit -ArgumentList @('clone', '--quiet', "https://github.com/$Repository.git", $checkout) `
            -WorkingDirectory $staging -UseGitHubCredential -RetryNetworkFailure
        $git = @{ WorkingDirectory = $checkout }
        if ((Invoke-AvmGit @git -ArgumentList @('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main') -IgnoreExitCode).ExitCode -eq 0) {
            $null = Invoke-AvmGit @git -ArgumentList @('checkout', '--quiet', '-B', 'main', 'origin/main')
        }
        else {
            $null = Invoke-AvmGit @git -ArgumentList @('symbolic-ref', 'HEAD', 'refs/heads/main')
        }
        $seedFiles = @('README.md', 'LICENSE', 'SECURITY.md', 'SUPPORT.md', 'CODE_OF_CONDUCT.md', '.gitignore')
        $unexpected = @((Invoke-AvmGit @git -ArgumentList @('ls-files')).StdOut -split '\r?\n' |
                Where-Object { $_ -and $_ -cnotin $seedFiles })
        if ($unexpected.Count -gt 0) {
            return (& $result 'blocked' $null $null $unexpected)
        }

        Copy-Item -LiteralPath $MetadataPath -Destination (Join-Path -Path $checkout -ChildPath 'metadata.json')
        $plans = @(Get-AvmTerraformScaffoldPlan -Path $checkout -Metadata $Metadata)
        if ($plans.Count -gt 0) {
            $null = Write-AvmModuleInitializationPlan -Root $checkout -Plan $plans -Confirm:$false
        }
        $preCommit = Invoke-AvmPreCommit -Path $checkout -Ecosystem terraform
        if ([string]$preCommit.Status -in @('fail', 'error')) {
            return (& $result 'fail' $null $preCommit @())
        }

        $null = Invoke-AvmGit @git -ArgumentList @('add', '--all')
        $null = Invoke-AvmGit @git -ArgumentList @('add', '--force', '--', 'metadata.json')
        if ((Invoke-AvmGit @git -ArgumentList @('var', 'GIT_COMMITTER_IDENT') -IgnoreExitCode).ExitCode -ne 0) {
            throw [AvmConfigurationException]::new(
                'Configure a Git commit identity with git config --global user.name and user.email, then run avm init again.')
        }
        $null = Invoke-AvmGit @git -ArgumentList @('commit', '--quiet', '--message', 'chore: initialize module repository')

        $original = Get-AvmRepositoryRulesetOptOut -Repository $Repository
        if ($original -ceq 'true') {
            throw [AvmConfigurationException]::new(
                "global-rulesets-opt-out is already true on $Repository, so its original value is unknown. " +
                'Set the property back to its original value, normally false, then run avm init again.')
        }
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $recordPath -Parent) -Force
        $record = [ordered]@{
            repository   = $Repository
            repositoryId = $RepositoryId
            propertyName = 'global-rulesets-opt-out'
            value        = $original
        }
        [System.IO.File]::WriteAllText($recordPath, (ConvertTo-Json -InputObject $record).Replace("`r`n", "`n") + "`n",
            [System.Text.UTF8Encoding]::new($false))
        Set-AvmRepositoryRulesetOptOut -Repository $Repository -Value 'true' -Confirm:$false
        $pushError = $null
        try {
            $null = Invoke-AvmGit @git -ArgumentList @('push', '--quiet', 'origin', 'HEAD:refs/heads/main') -UseGitHubCredential
        }
        catch {
            $pushError = $_
        }
        finally {
            try {
                Set-AvmRepositoryRulesetOptOut -Repository $Repository -Value $original -Confirm:$false
                Remove-Item -LiteralPath $recordPath -Force
            }
            catch {
                $failures = @($_.Exception)
                if ($null -ne $pushError) {
                    $failures = @($pushError.Exception) + $failures
                }
                $restore = if ($null -eq $original) { 'unset' } else { $original }
                throw [System.AggregateException]::new(
                    "Could not restore global-rulesets-opt-out to $restore on $Repository. Run avm init again to restore it.",
                    [System.Exception[]]$failures)
            }
        }
        if ($null -ne $pushError) {
            throw $pushError
        }
        $commit = (Invoke-AvmGit @git -ArgumentList @('rev-parse', '--short', 'HEAD')).StdOut.Trim()
        return (& $result 'pass' $commit $preCommit @())
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ProgressAction SilentlyContinue -ErrorAction SilentlyContinue
    }
}
