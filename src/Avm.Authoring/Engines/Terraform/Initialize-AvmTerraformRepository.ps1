function Initialize-AvmTerraformRepository {
    <#
    .SYNOPSIS
        Create and set up an AVM Terraform module repository, resuming any incomplete stage.
    .DESCRIPTION
        Each stage checks GitHub and the local directory first, so running the
        command again continues from wherever an earlier run stopped:

        1. Write metadata.json to the local directory.
        2. Create the public repository in the Azure organization.
        3. Wait for open source portal setup and JIT elevation.
        4. Restore a ruleset opt-out that an interrupted run left changed.
        5. Grant the module contributors and readers teams access.
        6. Publish metadata.json, the packaged minimal scaffold, and the avm
           pre-commit output as the first commit on main.
        7. Request the AVM app installations in microsoft/github-operations.
        8. Clone the repository into the local directory.

        A failed stage is reported in the result and stops the run.
    .PARAMETER Path
        Local repository directory. Its name is the repository name.
    .PARAMETER ModuleType
        Resource, pattern, or utility.
    .PARAMETER InputObject
        Metadata values; missing required values are prompted for.
    .PARAMETER SkipModuleVersionCheck
        Skip the installed-module version check.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [System.Collections.IDictionary] $InputObject = @{},

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    # Nested verbs such as avm pre-commit must not repeat the version check, as in the dispatcher.
    $PSDefaultParameterValues = if ($PSDefaultParameterValues) { $PSDefaultParameterValues.Clone() } else { @{} }
    $PSDefaultParameterValues['*:SkipModuleVersionCheck'] = $true
    $PSDefaultParameterValues['Test-AvmModuleVersion:SuppressSkipWarning'] = $true

    $organization = 'Azure'
    $teams = @(
        [pscustomobject]@{ Slug = 'azure-verified-modules-module-contributors'; Permission = 'push' }
        [pscustomobject]@{ Slug = 'azure-verified-modules-module-readers'; Permission = 'triage' }
    )
    $target = Resolve-AvmTerraformRepositoryTarget -Path $Path -ModuleType $ModuleType
    $repository = "$organization/$($target.Name)"
    $repositoryUrl = "https://github.com/$repository"
    $metadataPath = Join-Path -Path $target.Root -ChildPath 'metadata.json'
    $metadataEndpoint = "repos/$repository/contents/metadata.json?ref=main"
    $steps = [System.Collections.Generic.List[object]]::new()
    $state = @{ Changed = $false; Metadata = $null; PullRequest = $null; Stage = 'metadata' }
    $addStep = {
        param([string] $Name, [string] $Status, [string] $Detail, [string] $ErrorText, [object] $Result)
        $step = [ordered]@{ Step = if ($Detail) { "$Name`: $Detail" } else { $Name }; Status = $Status }
        if ($ErrorText) {
            $step.Error = $ErrorText
        }
        if ($null -ne $Result) {
            $step.Result = $Result
        }
        $steps.Add([pscustomobject]$step)
    }
    $finish = {
        [pscustomobject][ordered]@{
            Engine                     = 'terraform'
            Tool                       = 'module-initialize/1'
            ToolPath                   = $null
            ToolSource                 = 'builtin'
            Status                     = if (@($steps | Where-Object { $_.Status -eq 'fail' }).Count -gt 0) { 'fail' } else { 'pass' }
            Issues                     = @()
            Repository                 = $repository
            RepositoryUrl              = $repositoryUrl
            Path                       = $target.Root
            Changed                    = $state.Changed
            Steps                      = $steps.ToArray()
            Metadata                   = $state.Metadata
            AppInstallationPullRequest = $state.PullRequest
        }
    }
    $isAdministrator = {
        param($value)
        $null -ne $value -and $value['permissions'] -is [System.Collections.IDictionary] -and
        $value['permissions']['admin'] -eq $true
    }

    $gh = Get-AvmApplicationPath -Name gh
    $null = Get-AvmApplicationPath -Name git
    $authentication = Invoke-AvmProcess -FilePath $gh -ArgumentList @('auth', 'status', '--hostname', 'github.com', '--active') `
        -IgnoreExitCode -Label 'gh auth status' -EnvVars @{ GH_PROMPT_DISABLED = '1'; NO_COLOR = '1' }
    if ($authentication.ExitCode -ne 0) {
        throw [AvmConfigurationException]::new(
            'The GitHub CLI is not signed in to github.com. Run gh auth login, then run avm init again.')
    }
    # Fine-grained tokens list no scopes, so only OAuth and classic tokens are checked.
    $scopeLine = [regex]::Match("$($authentication.StdOut)`n$($authentication.StdErr)", 'Token scopes:(?<scopes>[^\r\n]*)')
    $scopes = @(if ($scopeLine.Success) {
            [regex]::Matches($scopeLine.Groups['scopes'].Value, "'(?<scope>[^']+)'") | ForEach-Object { $_.Groups['scope'].Value }
        })
    if ($scopes.Count -gt 0) {
        $missingScopes = @(
            if ($scopes -notcontains 'repo') { 'repo' }
            if (@($scopes | Where-Object { $_ -in @('read:org', 'write:org', 'admin:org') }).Count -eq 0) { 'read:org' }
            if ($scopes -notcontains 'workflow') { 'workflow' }
        )
        if ($missingScopes.Count -gt 0) {
            throw [AvmConfigurationException]::new(
                "The GitHub CLI token is missing the $($missingScopes -join ', ') scope(s). Run gh auth refresh " +
                "--hostname github.com --scopes $($missingScopes -join ','), or use a GH_TOKEN with those scopes, then run avm init again.")
        }
    }

    try {
        $remote = Invoke-AvmGitHubApi -Endpoint "repos/$repository" -AllowNotFound
        $published = $null -ne $remote -and $null -ne (Invoke-AvmGitHubApi -Endpoint $metadataEndpoint -AllowNotFound)
        if (-not $published) {
            $values = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                $values[$key] = $InputObject[$key]
            }
            if (-not (Test-Path -LiteralPath $metadataPath) -and -not $values.Contains('telemetryIdPrefix') -and $ModuleType -ne 'utility') {
                $kind = @{ resource = 'res'; pattern = 'ptn' }[$ModuleType]
                $values['telemetryIdPrefix'] = New-AvmTelemetryIdPrefix -Ecosystem terraform -Kind $kind `
                    -KnownPrefix @(Get-AvmCatalogTelemetryPrefix -SkipModuleVersionCheck) -SkipModuleVersionCheck
            }
            $metadataPlan = Get-AvmModuleMetadataInitializationPlan -Path $target.Root -InputObject $values `
                -Ecosystem terraform -ModuleType $ModuleType -CreateDirectory -SkipModuleVersionCheck
            $state.Metadata = $metadataPlan.Metadata
            if ($metadataPlan.Plans.Count -eq 0) {
                & $addStep 'metadata' 'pass' $metadataPath
            }
            elseif ($PSCmdlet.ShouldProcess($metadataPath, 'Write module metadata')) {
                Test-AvmModuleInitializationPlan -Root $target.Root -Plan $metadataPlan.Plans
                $null = Write-AvmModuleInitializationPlan -Root $target.Root -Plan $metadataPlan.Plans -Confirm:$false
                $state.Changed = $true
                & $addStep 'metadata' 'pass' "wrote $metadataPath"
            }
            else {
                & $addStep 'metadata' 'planned' "write $metadataPath"
                if (-not $WhatIfPreference) {
                    return (& $finish)
                }
            }
        }

        $state.Stage = 'repository'
        $createdNow = $false
        if ($null -eq $remote) {
            if (-not $PSCmdlet.ShouldProcess($repository, 'Create the public GitHub repository')) {
                & $addStep 'repository' 'planned' "create $repositoryUrl"
                return (& $finish)
            }
            try {
                $null = Invoke-AvmGitHubApi -Method POST -Endpoint "orgs/$organization/repos" `
                    -Body @{ name = $target.Name; visibility = 'public' }
                $createdNow = $true
                $state.Changed = $true
                & $addStep 'repository' 'pass' "created $repositoryUrl"
            }
            catch [AvmGitHubException] {
                if ($_.Exception.StatusCode -ne 422 -or $_.Exception.Message -notmatch 'already exists') {
                    throw
                }
                & $addStep 'repository' 'pass' "$repositoryUrl exists but is not accessible yet"
            }
        }
        else {
            & $addStep 'repository' 'pass' "$repositoryUrl exists"
        }

        $state.Stage = 'open source portal setup'
        if ($WhatIfPreference -and ($null -eq $remote -or [string]$remote['visibility'] -ne 'public')) {
            & $addStep 'open source portal setup' 'planned' 'complete the portal setup and elevate with JIT'
            return (& $finish)
        }
        $remote = Wait-AvmTerraformRepositoryAccess -Repository $repository -ModuleName $target.ModuleName `
            -Requirement PortalSetup -AlwaysPrompt:$createdNow
        if ($null -eq $remote) {
            & $addStep 'open source portal setup' 'fail' '' `
                "Complete the open source portal setup for $repository and elevate with JIT, then run avm init again."
            return (& $finish)
        }
        & $addStep 'open source portal setup' 'pass' 'complete'

        $state.Stage = 'team access'
        $published = $null -ne (Invoke-AvmGitHubApi -Endpoint $metadataEndpoint -AllowNotFound)
        $recordExists = Test-Path -LiteralPath (Get-AvmRulesetOptOutRecordPath -Repository $repository) -PathType Leaf
        $teamPlan = @(Sync-AvmRepositoryTeamAccess -Organization $organization -Repository $target.Name -Team $teams -PlanOnly)
        $teamsNeeded = @($teamPlan | Where-Object { $_.Status -eq 'planned' }).Count -gt 0
        if (($teamsNeeded -or -not $published -or $recordExists) -and -not (& $isAdministrator $remote)) {
            $state.Stage = 'administrator access'
            if ($WhatIfPreference) {
                & $addStep 'administrator access' 'planned' 'elevate with JIT'
                return (& $finish)
            }
            $remote = Wait-AvmTerraformRepositoryAccess -Repository $repository -ModuleName $target.ModuleName `
                -Requirement Elevation
            if ($null -eq $remote) {
                & $addStep 'administrator access' 'fail' '' "Elevate your access to $repository with JIT, then run avm init again."
                return (& $finish)
            }
            & $addStep 'administrator access' 'pass' 'elevated'
        }

        $state.Stage = 'organization rulesets'
        if ($recordExists) {
            $restore = Restore-AvmRulesetOptOut -Repository $repository -RepositoryId ([long]$remote['id'])
            $restored = if ($null -eq $restore.Value) { 'unset' } else { $restore.Value }
            switch ($restore.Status) {
                'restored' {
                    $state.Changed = $true
                    & $addStep 'organization rulesets' 'pass' "restored global-rulesets-opt-out to $restored"
                }
                'planned' {
                    & $addStep 'organization rulesets' 'planned' 'restore global-rulesets-opt-out if an earlier run left it changed'
                    if (-not $WhatIfPreference) {
                        return (& $finish)
                    }
                }
                'stale' {
                    & $addStep 'organization rulesets' 'pass' 'removed a record for an earlier repository with this name'
                }
                default {
                    & $addStep 'organization rulesets' 'pass' 'no earlier change to restore'
                }
            }
        }
        elseif ((Get-AvmRepositoryRulesetOptOut -Repository $repository) -ceq 'true' -and
            -not (Test-AvmRepositorySyncManaged -Repository $repository)) {
            & $addStep 'organization rulesets' 'fail' '' (
                'global-rulesets-opt-out is true, but repository sync does not manage the repository and this machine has ' +
                'no record of avm init changing it. If avm init was interrupted on another machine, run it there to ' +
                'restore the original value. Otherwise set the property back to false, then run avm init again.')
            return (& $finish)
        }

        $state.Stage = 'team access'
        $teamDetail = ($teams | ForEach-Object { "$($_.Slug) ($($_.Permission))" }) -join ', '
        if ($teamsNeeded) {
            $granted = @(Sync-AvmRepositoryTeamAccess -Organization $organization -Repository $target.Name -Team $teams)
            if (@($granted | Where-Object { $_.Status -eq 'granted' }).Count -gt 0) {
                $state.Changed = $true
            }
            if (@($granted | Where-Object { $_.Status -eq 'planned' }).Count -gt 0) {
                & $addStep 'team access' 'planned' $teamDetail
                if (-not $WhatIfPreference) {
                    return (& $finish)
                }
            }
            else {
                & $addStep 'team access' 'pass' $teamDetail
            }
        }
        else {
            & $addStep 'team access' 'pass' "$teamDetail already granted"
        }

        $state.Stage = 'initial content'
        $contentReady = $published
        if ($published) {
            $file = Invoke-AvmGitHubApi -Endpoint $metadataEndpoint
            $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(([string]$file['content'] -replace '\s', '')))
            $validation = Test-AvmMetadataContent -Json $json -Ecosystem terraform -ModuleType $ModuleType
            if ($validation.Issues.Count -gt 0) {
                $invalid = [pscustomobject]@{ Issues = $validation.Issues }
                & $addStep 'initial content' 'fail' '' 'metadata.json on main is invalid. Correct it with a pull request, then run avm init again.' $invalid
                return (& $finish)
            }
            $root = @((Invoke-AvmGitHubApi -Endpoint "repos/$repository/git/trees/main")['tree'])
            $examplesTree = @($root | Where-Object {
                    $_ -is [System.Collections.IDictionary] -and $_['path'] -ceq 'examples' -and $_['type'] -ceq 'tree'
                })
            $examples = @(if ($examplesTree.Count -gt 0) {
                    (Invoke-AvmGitHubApi -Endpoint "repos/$repository/git/trees/$($examplesTree[0]['sha'])")['tree']
                })
            $missingFiles = @(Get-AvmTerraformMissingModuleFile -Root $root -Examples $examples)
            if ($missingFiles.Count -gt 0) {
                & $addStep 'initial content' 'fail' '' (
                    "main has metadata.json but is missing $($missingFiles -join ', '). " +
                    'Add the module files with a pull request, then run avm init again.')
                return (& $finish)
            }
            $state.Metadata = $validation.Metadata
            & $addStep 'initial content' 'pass' 'metadata.json and module files are on main'
        }
        else {
            $publication = Publish-AvmTerraformRepositoryContent -Repository $repository -RepositoryId ([long]$remote['id']) `
                -MetadataPath $metadataPath -Metadata $state.Metadata
            switch ($publication.Status) {
                'pass' {
                    $state.Changed = $true
                    $contentReady = $true
                    & $addStep 'initial content' 'pass' "pushed $($publication.Commit) to main"
                }
                'planned' {
                    & $addStep 'initial content' 'planned' 'run avm pre-commit and push the first commit to main'
                    if (-not $WhatIfPreference) {
                        return (& $finish)
                    }
                }
                'blocked' {
                    & $addStep 'initial content' 'fail' '' (
                        "main already contains files without metadata.json ($((@($publication.Files) | Select-Object -First 5) -join ', ')). " +
                        'Add metadata.json with a pull request instead.')
                    return (& $finish)
                }
                default {
                    & $addStep 'initial content' 'fail' '' 'avm pre-commit failed. Fix the reported issues, then run avm init again.' `
                        $publication.PreCommit
                    return (& $finish)
                }
            }
        }

        $state.Stage = 'app installation'
        $request = Request-AvmAppInstallation -Repository $target.Name -ModuleName $target.ModuleName
        $state.PullRequest = $request.PullRequest
        switch ($request.Status) {
            'installed' {
                & $addStep 'app installation' 'pass' 'approved'
            }
            'pending' {
                & $addStep 'app installation' 'pending' "awaiting approval in $($request.PullRequest)"
            }
            'requested' {
                $state.Changed = $true
                & $addStep 'app installation' 'pending' "requested in $($request.PullRequest)"
            }
            default {
                & $addStep 'app installation' 'planned' 'open a pull request in microsoft/github-operations'
                if (-not $WhatIfPreference) {
                    return (& $finish)
                }
            }
        }

        $state.Stage = 'local clone'
        if ($contentReady) {
            $clone = New-AvmTerraformRepositoryClone -Path $target.Root -Repository $repository
            & $addStep 'local clone' $clone.Status $clone.Detail
        }
    }
    catch {
        & $addStep $state.Stage 'fail' '' $_.Exception.Message
    }
    return (& $finish)
}
