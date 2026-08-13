function Sync-AvmManagedFile {
    <#
    .SYNOPSIS
        Synchronise a Terraform module repository's managed files against the
        AVM governance source-of-truth, applying additions, updates, and
        deprecated-file removals directly to the working tree.

    .DESCRIPTION
        Engine implementation behind Invoke-AvmSync, reduced to the *file-sync*
        concern only: it never opens or merges a pull request, it mutates the
        local working tree ($Context.Root) in place.

        Source of the managed files (highest precedence first):

          1. Explicit cmdlet parameters.
          2. Environment variables (AVM_MANAGED_FILES_*).
          3. A repo-committed '.avm/managed-files.json' under $Context.Root.
          4. For the ref only: the semver pin in
             '.avm/managed-files-version.json', fetched as tag 'v<version>'.
          5. Defaults: files from Azure/azure-verified-modules-managed-files
             ('main' ref, 'terraform' base folder) and config.json from
             Azure/azure-verified-modules-tools ('main' ref,
             'repository-management/repository-config' folder).

        Each file group is a folder directly under the managed-files base
        folder. A group may carry a '_config.json' beside its payload declaring
        'deletedFiles' and 'managedLines' for that group; the file is reserved
        and never synced into a target repository.

        Managed files are released with semver tags, and each repository pins
        the release it tracks. The engine syncs the pinned release, warns when a
        newer minor or patch exists, and refuses to run when a major release is
        available (a drift check reports that as an issue instead of throwing).
        -Upgrade moves to the newest release and stamps the pin; a repository
        with no pin adopts the newest release silently. Tag lookup failures are
        non-fatal: the engine warns and continues from the pin. An explicitly
        requested ref (tiers 1-3) opts the repository out of pin handling.

        A direct local path (-ManagedFilesLocalPath or
        AVM_MANAGED_FILES_LOCAL_PATH) short-circuits the git fetch entirely and
        is what the offline tests use. Otherwise the source repo is shallow
        cloned (or fetched, if already cached) into $env:AVM_HOME/cache.

        The managed-file map is built from '<base>/root' plus zero or more
        overlays ('<base>/<overlay>') stacked in declaration order, where later
        sources win, minus any excluded paths. A source subtree at
        '<parent>/_all/' is broadcast into every existing immediate child of
        the matching target parent; reserved '_all' segments are never copied
        literally. A root-level '_all/' remains a literal path. Overlays and
        exclusions are resolved from the config folder's 'config.json' by
        matching the repository id against 'repositoryGroups'.
        'deprecated-files.json' lists paths that must be removed from every
        target repo; deprecated removals win over managed adds when both name
        the same path.

        For each desired managed file the engine computes git's blob SHA-1 over
        the source bytes and compares it (plus the git index mode) with the
        on-disk state under $Context.Root:

          - Add    = desired path absent on disk.
          - Update = desired path present but blob SHA or mode differs.
          - Remove = deprecated path present on disk (file or directory).

        With -CheckDrift the engine writes nothing: any needed change makes the
        aggregate Status 'fail' and is recorded as an Issue (the pr-check hard
        gate). Otherwise it applies the changes (honouring -WhatIf /
        SupportsShouldProcess) and returns Status 'pass'.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'. Its Root is the working tree that is synced.

    .PARAMETER AllowPathFallback
        Accepted for signature parity with the other engines. The managed-files
        engine shells out to plain 'git' (not a pinned AVM tool), so this switch
        is currently a no-op.

    .PARAMETER CheckDrift
        Report-only mode. No files are written; any required change flips the
        Status to 'fail' and is emitted as an Issue.

    .PARAMETER ManagedFilesRepo
        owner/name of the git repo that holds the managed files. Defaults to
        'Azure/azure-verified-modules-tools'.

    .PARAMETER ManagedFilesRef
        Git ref (branch/tag/sha) to fetch. Defaults to 'main'.

    .PARAMETER ManagedFilesPath
        Path within the source repo to the managed-files base folder (the one
        that contains the file group folders). Defaults to 'terraform'.

    .PARAMETER ManagedFilesLocalPath
        Direct local path to the managed-files base folder. When supplied the
        git fetch is skipped entirely.

    .PARAMETER ConfigRepo
        owner/name of the git repo that holds the config folder. Defaults to
        'Azure/azure-verified-modules-tools'.

    .PARAMETER ConfigRef
        Git ref for the config repo. Defaults to 'main'.

    .PARAMETER ConfigPath
        Path within the config repo to the folder holding 'config.json'.
        Defaults to 'repository-management/repository-config'.

    .PARAMETER ConfigLocalPath
        Direct local path to the config folder. When supplied no config repo is
        fetched.

    .PARAMETER RepoId
        The repository id used to look up file groups in config.json. When
        omitted it is resolved by Resolve-AvmManagedFilesRepoId: an explicit
        AVM_MANAGED_FILES_REPO_ID environment value or '.avm/managed-files.json'
        repoId override is authoritative; otherwise a candidate is derived from
        the git origin remote, then the working-tree folder name, with a leading
        'terraform-azurerm-' / 'terraform-azapi-' prefix stripped. Matching a
        config.json repositoryGroups entry adds that group's file groups; every
        repository matches the 'default' group and so receives the shared root
        files. Resolution fails only when no repository id can be determined.

    .PARAMETER Upgrade
        Sync the newest managed-files release rather than the pinned one and
        rewrite '.avm/managed-files-version.json' to match. Has no effect when
        the ref is overridden explicitly or when the release lookup fails.

    .PARAMETER SkipManagedFilesVersionCheck
        Bypass pin resolution and release-drift enforcement entirely, leaving
        the ref exactly as the other precedence tiers resolved it.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Issues, Added, Updated, Removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', 'AllowPathFallback',
        Justification = 'Accepted for cross-verb parity and forwarded by Invoke-AvmSync; this engine shells out to plain git (Get-Command) rather than an AVM-pinned tool, so there is no resolved tool path to fall back on.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [switch] $CheckDrift,

        [string] $ManagedFilesRepo,
        [string] $ManagedFilesRef,
        [string] $ManagedFilesPath,
        [string] $ManagedFilesLocalPath,

        [string] $ConfigRepo,
        [string] $ConfigRef,
        [string] $ConfigPath,
        [string] $ConfigLocalPath,

        [string] $RepoId,

        [switch] $Upgrade,

        [switch] $SkipManagedFilesVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Sync-AvmManagedFile requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $root = $Context.Root

    $settings = Resolve-AvmManagedFilesSetting `
        -Root $root `
        -ManagedFilesRepo $ManagedFilesRepo `
        -ManagedFilesRef $ManagedFilesRef `
        -ManagedFilesPath $ManagedFilesPath `
        -ManagedFilesLocalPath $ManagedFilesLocalPath `
        -ConfigRepo $ConfigRepo `
        -ConfigRef $ConfigRef `
        -ConfigPath $ConfigPath `
        -ConfigLocalPath $ConfigLocalPath `
        -RepoId $RepoId

    $gitPath = (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1).Source

    $versionPlan = Resolve-AvmManagedFilesVersionPlan `
        -Settings $settings `
        -GitPath $gitPath `
        -Upgrade:$Upgrade `
        -SkipVersionCheck:$SkipManagedFilesVersionCheck
    $settings.ManagedFilesRef = $versionPlan.Ref
    Write-AvmLog ("sync: managed-files version status={0}; ref={1}" -f $versionPlan.Status, $versionPlan.Ref) -Level Verbose | Out-Null

    # A major release must be adopted deliberately. Outside drift checks that is
    # a hard stop so the author runs the upgrade; a drift check instead reports
    # it as an issue so the whole report is still produced.
    if ($versionPlan.Status -eq 'major' -and -not $Upgrade -and -not $CheckDrift) {
        throw [AvmManagedFilesVersionException]::new(
            [string]$versionPlan.PinnedVersion,
            [string]$versionPlan.LatestVersion,
            $versionPlan.Message)
    }
    if ($versionPlan.Message -and -not ($versionPlan.Status -eq 'major' -and $CheckDrift)) {
        Write-AvmLog $versionPlan.Message -Level Warning | Out-Null
    }

    $source = Resolve-AvmManagedFilesSource -Settings $settings -GitPath $gitPath
    Write-AvmLog ("sync: source kind={0}; managed-files={1}; config={2}" -f $source.SourceKind, $source.ManagedBaseDir, $source.ConfigDir) -Level Verbose | Out-Null

    $fileGroups = @()
    $deletedFilesByGroup = @{}
    $repositoryConfig = $null
    if ($source.ConfigDir -and (Test-Path -LiteralPath $source.ConfigDir -PathType Container)) {
        $configFile = Join-Path $source.ConfigDir 'config.json'
        if (Test-Path -LiteralPath $configFile -PathType Leaf) {
            $repositoryConfig = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
        }
    }

    $repoId = Resolve-AvmManagedFilesRepoId `
        -Root $root `
        -ExplicitRepoId $settings.RepoId `
        -KnownRepoIds (Get-AvmManagedFilesKnownRepoId -RepositoryConfig $repositoryConfig) `
        -GitPath $gitPath `
        -Interactive (Test-AvmManagedFilesInteractive)

    if ($repositoryConfig) {
        $fileGroups = (Resolve-AvmManagedFilesRepositorySetting -RepositoryConfig $repositoryConfig -RepoId $repoId).FileGroups
    }
    Write-AvmLog ("sync: repo-id={0}; file-groups={1}" -f $repoId, ($fileGroups -join ', ')) -Level Verbose | Out-Null

    $deletedFilesByGroup = Get-AvmManagedFilesDeletedFileMap -BaseDir $source.ManagedBaseDir -FileGroups $fileGroups

    $managed = Build-AvmManagedFilesMap `
        -BaseDir $source.ManagedBaseDir `
        -TargetRoot $root `
        -FileGroups $fileGroups `
        -DeletedFilesByGroup $deletedFilesByGroup `
        -RepoId $repoId `
        -GitPath $gitPath

    $desired = Get-AvmDesiredManagedFile -ManagedFiles $managed.Files

    # Deleted files win over managed adds if both name the same path.
    $matchedDeleted = @(Get-AvmMatchingDeprecatedPath -CandidatePaths $managed.Deleted -Root $root)
    $deletedLookup = @{}
    foreach ($p in $matchedDeleted) { $deletedLookup[$p] = $true }
    foreach ($p in @($desired.Keys)) {
        if ($deletedLookup.ContainsKey($p)) { $desired.Remove($p) | Out-Null }
    }
    Write-AvmLog ("sync: desired files={0}; matched deleted files={1}" -f $desired.Count, $matchedDeleted.Count) -Level Verbose | Out-Null

    # Line-managed files (e.g. .gitignore) are merged line-by-line rather than
    # overwritten wholesale, so the consumer keeps its own additions. The spec
    # lives in each group's '_config.json' alongside 'deletedFiles' and stacks
    # across file groups like the files themselves. A path owned by the line
    # spec must not also be whole-file managed (line-merge wins), and a
    # deletion still trumps a line merge.
    $lineSpec = Get-AvmManagedLineSpec -BaseDir $source.ManagedBaseDir -FileGroups $fileGroups
    foreach ($p in @($lineSpec.Keys)) {
        if ($deletedLookup.ContainsKey($p)) { $lineSpec.Remove($p) | Out-Null }
    }
    foreach ($p in @($lineSpec.Keys)) {
        if ($desired.ContainsKey($p)) { $desired.Remove($p) | Out-Null }
    }
    $linePlans = @(Get-AvmManagedLinePlan -Root $root -Spec $lineSpec)
    $changedLinePlans = @($linePlans | Where-Object { $_.Changed })

    $targetModes = Get-AvmGitIndexMode -Dir $root -GitPath $gitPath
    $existingBlobs = @{}
    $existingModes = @{}
    foreach ($targetPath in $desired.Keys) {
        $full = Join-Path $root ($targetPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $existingBlobs[$targetPath] = Get-AvmGitBlobSha -Bytes $bytes
            $mode = $targetModes[$targetPath]
            if (-not $mode) { $mode = '100644' }
            $existingModes[$targetPath] = $mode
        }
    }

    $toAdd = @()
    $toUpdate = @()
    $updateReasons = @{}
    foreach ($targetPath in ($desired.Keys | Sort-Object)) {
        $desiredSha = $desired[$targetPath].Sha
        $desiredMode = $desired[$targetPath].Mode
        if (-not $existingBlobs.ContainsKey($targetPath)) {
            $toAdd += $targetPath
        }
        else {
            $existingSha = $existingBlobs[$targetPath]
            $existingMode = $existingModes[$targetPath]
            if (-not $existingMode) { $existingMode = '100644' }
            $contentChanged = $existingSha -ne $desiredSha
            $modeChanged = $existingMode -ne $desiredMode
            if ($contentChanged -or $modeChanged) {
                $toUpdate += $targetPath
                $updateReasons[$targetPath] = if ($contentChanged -and $modeChanged) {
                    "content and mode $existingMode -> $desiredMode"
                }
                elseif ($contentChanged) {
                    'content'
                }
                else {
                    "mode $existingMode -> $desiredMode"
                }
            }
        }
    }
    $toRemove = @($matchedDeleted | Sort-Object)

    $lineAdded = @($changedLinePlans | Where-Object { -not $_.Existed } | ForEach-Object { $_.Path } | Sort-Object)
    $lineUpdated = @($changedLinePlans | Where-Object { $_.Existed } | ForEach-Object { $_.Path } | Sort-Object)
    Write-AvmLog ("sync: plan add={0}; update={1}; remove={2}; line-merge={3}" -f $toAdd.Count, $toUpdate.Count, $toRemove.Count, $changedLinePlans.Count) -Level Verbose | Out-Null
    foreach ($p in @(@($toAdd + $lineAdded) | Sort-Object)) {
        Write-AvmLog "sync: create $p" -Level Verbose | Out-Null
    }
    foreach ($p in $toUpdate) {
        Write-AvmLog ("sync: update {0} ({1})" -f $p, $updateReasons[$p]) -Level Verbose | Out-Null
    }
    foreach ($p in $lineUpdated) {
        Write-AvmLog "sync: update $p (managed lines)" -Level Verbose | Out-Null
    }
    foreach ($p in $toRemove) {
        Write-AvmLog "sync: delete $p" -Level Verbose | Out-Null
    }

    $issues = @()
    $pinAdded = @()
    $pinUpdated = @()
    if ($CheckDrift) {
        Write-AvmLog 'sync: check-drift mode; reporting planned changes without writing' -Level Verbose | Out-Null
        $issueList = New-Object System.Collections.Generic.List[object]
        if ($versionPlan.Status -eq 'major') {
            $issueList.Add((New-AvmSyncIssue -File '.avm/managed-files-version.json' -Message $versionPlan.Message))
        }
        foreach ($p in $toRemove) {
            $issueList.Add((New-AvmSyncIssue -File $p -Message 'deleted file present in the repository; it should be removed.'))
        }
        foreach ($p in $toAdd) {
            $issueList.Add((New-AvmSyncIssue -File $p -Message 'managed file missing from the repository; it should be added.'))
        }
        foreach ($p in $toUpdate) {
            $issueList.Add((New-AvmSyncIssue -File $p -Message 'managed file is out of date; it should be updated.'))
        }
        foreach ($plan in $changedLinePlans) {
            $detail = ('managed lines out of date; {0} to add, {1} to remove.' -f $plan.AddedLines.Count, $plan.RemovedLines.Count)
            $issueList.Add((New-AvmSyncIssue -File $plan.Path -Message $detail))
        }
        $issues = $issueList.ToArray()
        $status = if ($issueList.Count -gt 0) { 'fail' } else { 'pass' }
    }
    else {
        $hasChanges = ($toAdd.Count + $toUpdate.Count + $toRemove.Count + $changedLinePlans.Count) -gt 0
        if ($hasChanges) {
            $applyDesc = ('sync managed files (add {0}, update {1}, remove {2}, merge-lines {3})' -f $toAdd.Count, $toUpdate.Count, $toRemove.Count, $changedLinePlans.Count)
            if ($PSCmdlet.ShouldProcess($root, $applyDesc)) {
                Write-AvmLog ("sync: applying managed-file plan to {0}" -f $root) -Level Verbose | Out-Null
                foreach ($p in $toRemove) {
                    $full = Join-Path $root ($p.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                    if (Test-Path -LiteralPath $full) {
                        Remove-Item -LiteralPath $full -Recurse -Force
                    }
                    Write-AvmLog 'sync: managed-file plan applied' -Level Verbose | Out-Null
                }
                foreach ($p in @($toAdd + $toUpdate)) {
                    $full = Join-Path $root ($p.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                    $parent = Split-Path -Parent $full
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                        New-Item -ItemType Directory -Path $parent -Force | Out-Null
                    }
                    [System.IO.File]::WriteAllBytes($full, $desired[$p].Bytes)

                    if ($desired[$p].Mode -eq '100755') {
                        Set-AvmManagedFileExecutableBit -Path $full
                    }
                }
                $lineEncoding = [System.Text.UTF8Encoding]::new($false)
                foreach ($plan in $changedLinePlans) {
                    $parent = Split-Path -Parent $plan.Full
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                        New-Item -ItemType Directory -Path $parent -Force | Out-Null
                    }
                    [System.IO.File]::WriteAllText($plan.Full, $plan.NewText, $lineEncoding)
                }
            }
        }

        if ($versionPlan.ShouldStamp -and $versionPlan.TargetVersion) {
            $pinPath = Get-AvmManagedFilesVersionPinPath -Root $root
            $pinExisted = Test-Path -LiteralPath $pinPath -PathType Leaf
            $provenance = if ($source.CheckoutDir) {
                Get-AvmManagedFilesCheckoutProvenance -CheckoutDir $source.CheckoutDir -GitPath $gitPath
            }
            else {
                @{ Commit = ''; CommitDate = '' }
            }
            $stamped = Set-AvmManagedFilesVersionPin `
                -Root $root `
                -Version $versionPlan.TargetVersion `
                -Repo $settings.ManagedFilesRepo `
                -Commit $provenance.Commit `
                -CommitDate $provenance.CommitDate
            if ($stamped) {
                Write-AvmLog ("sync: managed-files version pinned to {0}" -f $versionPlan.TargetVersion) -Level Verbose | Out-Null
                if ($pinExisted) { $pinUpdated = @('.avm/managed-files-version.json') }
                else { $pinAdded = @('.avm/managed-files-version.json') }
            }
        }

        $status = 'pass'
    }

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = 'managed-files'
        ToolPath       = $source.ToolPath
        ToolSource     = $source.SourceKind
        Status         = $status
        FilesProcessed = $desired.Count + $linePlans.Count
        Issues         = $issues
        Added          = @($toAdd + $lineAdded + $pinAdded)
        Updated        = @($toUpdate + $lineUpdated + $pinUpdated)
        Removed        = $toRemove
    }
}

function Resolve-AvmManagedFilesSetting {
    <#
    .SYNOPSIS
        Resolve the effective managed-files settings by layering explicit
        parameters over environment variables, a repo-committed config file,
        and built-in defaults.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function; returns a settings hashtable and mutates no external state.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [string] $ManagedFilesRepo,
        [string] $ManagedFilesRef,
        [string] $ManagedFilesPath,
        [string] $ManagedFilesLocalPath,

        [string] $ConfigRepo,
        [string] $ConfigRef,
        [string] $ConfigPath,
        [string] $ConfigLocalPath,
        [string] $RepoId
    )

    $fileConfig = Get-AvmManagedFilesFileConfig -Root $Root

    $pick = {
        param([string]$Explicit, [string]$EnvName, [string]$FileKey, [string]$Default)
        if ($Explicit) { return $Explicit }
        $envValue = [System.Environment]::GetEnvironmentVariable($EnvName)
        if ($envValue) { return $envValue }
        if ($FileKey -and $fileConfig.ContainsKey($FileKey) -and $fileConfig[$FileKey]) { return [string]$fileConfig[$FileKey] }
        return $Default
    }

    # Managed file content lives in its own repository so that overlays can be
    # reviewed and released independently of the tooling. config.json stays in
    # the tools repository, so the config defaults are not derived from the
    # managed-files repo or ref.
    $repo = & $pick $ManagedFilesRepo 'AVM_MANAGED_FILES_REPO' 'repo' 'Azure/azure-verified-modules-managed-files'
    $path = & $pick $ManagedFilesPath 'AVM_MANAGED_FILES_PATH' 'path' 'terraform'
    $localPath = & $pick $ManagedFilesLocalPath 'AVM_MANAGED_FILES_LOCAL_PATH' 'localPath' ''

    # The ref is resolved separately from $pick because the version pin sits
    # between the repo-committed override and the 'main' default, and because
    # downstream version handling needs to know which tier won: an explicitly
    # requested ref opts the repository out of pin enforcement.
    $refSource = 'default'
    $ref = & $pick $ManagedFilesRef 'AVM_MANAGED_FILES_REF' 'ref' ''
    if ($ManagedFilesRef) { $refSource = 'explicit' }
    elseif ($ref -and [System.Environment]::GetEnvironmentVariable('AVM_MANAGED_FILES_REF')) { $refSource = 'environment' }
    elseif ($ref) { $refSource = 'file' }

    $versionPin = Get-AvmManagedFilesVersionPin -Root $Root
    if (-not $ref -and $versionPin) {
        $ref = 'v{0}' -f $versionPin.Version
        $refSource = 'pin'
    }
    if (-not $ref) { $ref = 'main' }

    $configRepoValue = & $pick $ConfigRepo 'AVM_MANAGED_FILES_CONFIG_REPO' 'configRepo' 'Azure/azure-verified-modules-tools'
    $configRefValue = & $pick $ConfigRef 'AVM_MANAGED_FILES_CONFIG_REF' 'configRef' 'main'
    $configPathValue = & $pick $ConfigPath 'AVM_MANAGED_FILES_CONFIG_PATH' 'configPath' 'repository-management/repository-config'
    $configLocalPath = & $pick $ConfigLocalPath 'AVM_MANAGED_FILES_CONFIG_LOCAL_PATH' 'configLocalPath' ''

    # RepoId is captured here only as its authoritative short-circuit value: an
    # explicit -RepoId parameter, the AVM_MANAGED_FILES_REPO_ID environment
    # variable, or a '.avm/managed-files.json' repoId override. Inference from the
    # git origin or the folder leaf happens later in
    # Resolve-AvmManagedFilesRepoId. Group membership prioritises a matching
    # candidate; the 'default' group's '*' wildcard covers every repository.
    $repoIdValue = & $pick $RepoId 'AVM_MANAGED_FILES_REPO_ID' 'repoId' ''

    return @{
        ManagedFilesRepo         = $repo
        ManagedFilesRef          = $ref
        ManagedFilesRefSource    = $refSource
        ManagedFilesVersionPin   = $versionPin
        ManagedFilesPath         = $path
        ManagedFilesLocalPath    = $localPath
        ConfigRepo               = $configRepoValue
        ConfigRef                = $configRefValue
        ConfigPath               = $configPathValue
        ConfigLocalPath          = $configLocalPath
        RepoId                   = $repoIdValue
    }
}

function ConvertTo-AvmManagedFilesRepoId {
    <#
    .SYNOPSIS
        Normalise a repository name into a managed-files repository id by
        stripping a leading 'terraform-azurerm-' / 'terraform-azapi-' prefix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    $value = $Name.Trim()
    foreach ($prefix in @('terraform-azurerm-', 'terraform-azapi-')) {
        if ($value.StartsWith($prefix)) {
            $value = $value.Substring($prefix.Length)
            break
        }
    }

    return $value
}

function Get-AvmRepoLeafFromUrl {
    <#
    .SYNOPSIS
        Extract the repository leaf name from a git remote URL, handling HTTPS
        (with or without a trailing '.git'), SCP-style SSH
        (git@host:owner/repo.git) and ssh:// URLs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }

    $value = $Url.Trim().TrimEnd('/')
    $leaf = @($value -split '[:/]' | Where-Object { $_ }) | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($leaf)) { return '' }

    if ($leaf.EndsWith('.git')) {
        $leaf = $leaf.Substring(0, $leaf.Length - 4)
    }

    return $leaf
}

function Get-AvmManagedFilesOriginRepoId {
    <#
    .SYNOPSIS
        Resolve a normalised repository id from the 'origin' git remote of a
        working tree, or an empty string when there is no origin/git available.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [string] $GitPath
    )

    if ([string]::IsNullOrWhiteSpace($GitPath) -or [string]::IsNullOrWhiteSpace($Root)) {
        return ''
    }

    try {
        $result = Invoke-AvmProcess -FilePath $GitPath -ArgumentList @('-C', $Root, 'remote', 'get-url', 'origin') -IgnoreExitCode
    }
    catch {
        return ''
    }

    if (-not $result -or $result.ExitCode -ne 0) { return '' }

    $line = @($result.StdOut -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) { return '' }

    return ConvertTo-AvmManagedFilesRepoId -Name (Get-AvmRepoLeafFromUrl -Url $line)
}

function Get-AvmManagedFilesKnownRepoId {
    <#
    .SYNOPSIS
        Return the de-duplicated set of repository ids declared across every
        'repositoryGroups' entry of a parsed config.json.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [object] $RepositoryConfig
    )

    [string[]] $none = @()
    if (-not $RepositoryConfig) { return $none }
    if (-not ($RepositoryConfig.PSObject.Properties.Name -contains 'repositoryGroups')) { return $none }

    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($group in @($RepositoryConfig.repositoryGroups)) {
        if (-not $group) { continue }
        if (-not ($group.PSObject.Properties.Name -contains 'repositories')) { continue }
        foreach ($repo in @($group.repositories)) {
            if (-not [string]::IsNullOrWhiteSpace($repo)) { $ids.Add([string]$repo) }
        }
    }

    [string[]] $unique = @($ids | Select-Object -Unique)
    return $unique
}

function Test-AvmManagedFilesInteractive {
    <#
    .SYNOPSIS
        Return whether the current host can prompt the user for a repository id.
        CI runs and redirected input are treated as non-interactive.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        if (-not [string]::IsNullOrEmpty($env:CI)) { return $false }
        if ([System.Console]::IsInputRedirected) { return $false }
    }
    catch {
        return $false
    }

    return $true
}

function Resolve-AvmManagedFilesRepoId {
    <#
    .SYNOPSIS
        Resolve the managed-files repository id using the F11/F100 resolution
        order: explicit value, matching git-origin candidate, matching folder-leaf
        candidate, unmatched git-origin fallback, unmatched folder-leaf fallback,
        interactive prompt, then a hard failure.

    .DESCRIPTION
        An explicit -RepoId (already carrying the -RepoId parameter, the
        AVM_MANAGED_FILES_REPO_ID environment value or a '.avm/managed-files.json'
        override) short-circuits the whole chain and is authoritative.

        Otherwise a candidate is derived from the git origin remote and from the
        working-tree folder leaf, each normalised by stripping a leading
        'terraform-azurerm-' / 'terraform-azapi-' prefix. A candidate matching
        config.json repositoryGroups membership is preferred so an overlay is not
        lost when only one candidate matches. If neither matches, the origin and
        folder candidates remain valid for root-only sync. An interactive host is
        prompted only when neither automatic candidate exists; resolution fails
        only when no repository id can be determined.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [AllowEmptyString()]
        [string] $ExplicitRepoId = '',

        [string[]] $KnownRepoIds = @(),

        [string] $GitPath,

        [bool] $Interactive = $false
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRepoId)) {
        return $ExplicitRepoId.Trim()
    }

    $known = @($KnownRepoIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $originCandidate = Get-AvmManagedFilesOriginRepoId -Root $Root -GitPath $GitPath
    $rootLeaf = [System.IO.Path]::GetFileName([System.IO.Path]::TrimEndingDirectorySeparator($Root))
    $folderCandidate = ConvertTo-AvmManagedFilesRepoId -Name $rootLeaf

    if (-not [string]::IsNullOrWhiteSpace($originCandidate) -and ($known -contains $originCandidate)) {
        return $originCandidate
    }

    if (-not [string]::IsNullOrWhiteSpace($folderCandidate) -and ($known -contains $folderCandidate)) {
        return $folderCandidate
    }

    if (-not [string]::IsNullOrWhiteSpace($originCandidate)) {
        return $originCandidate
    }

    if (-not [string]::IsNullOrWhiteSpace($folderCandidate)) {
        return $folderCandidate
    }

    if ($Interactive) {
        $answer = Read-Host -Prompt 'Repository id could not be inferred. Enter the managed-files repository id'
        if (-not [string]::IsNullOrWhiteSpace($answer)) {
            $normalised = ConvertTo-AvmManagedFilesRepoId -Name $answer
            if (-not [string]::IsNullOrWhiteSpace($normalised)) { return $normalised }
        }
    }

    throw [AvmConfigurationException]::new(
        ("Could not resolve a managed-files repository id for '{0}' from its git origin or working-tree folder. " -f $Root) +
        "Set it explicitly with -RepoId, the AVM_MANAGED_FILES_REPO_ID environment variable, or a repoId in '.avm/managed-files.json'.")
}

function Set-AvmManagedFileExecutableBit {
    <#
    .SYNOPSIS
        Set the owner/group/other execute bits on a synced file's working-tree
        entry without ever touching the git index (F13). No-op on Windows.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Working-tree file-mode repair; the caller already gates writes via ShouldProcess.')]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($IsWindows) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    try {
        $item = Get-Item -LiteralPath $Path -Force
        $execute = [System.IO.UnixFileMode]::UserExecute -bor [System.IO.UnixFileMode]::GroupExecute -bor [System.IO.UnixFileMode]::OtherExecute
        $item.UnixFileMode = $item.UnixFileMode -bor $execute
    }
    catch {
        Write-AvmLog "Failed to set executable bit on '$Path': $($_.Exception.Message)" -Level Verbose
    }
}

function Get-AvmManagedFilesFileConfig {
    <#
    .SYNOPSIS
        Read the optional '.avm/managed-files.json' override file from a repo
        working tree, returning an empty hashtable when it is absent or invalid.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    $result = @{}
    $configPath = Join-Path (Join-Path $Root '.avm') 'managed-files.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $result }

    try {
        $json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-AvmLog "Failed to parse '$configPath': $($_.Exception.Message)" -Level Warning
        return $result
    }

    foreach ($property in $json.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Resolve-AvmManagedFilesSource {
    <#
    .SYNOPSIS
        Resolve the managed-files base directory (and optional config folder),
        fetching the source git repo into the AVM cache unless a local path
        override is supplied.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Prepares a local checkout for read-only consumption; performs no destructive state change.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Settings,

        [string] $GitPath
    )

    if ($Settings.ManagedFilesLocalPath) {
        if (-not (Test-Path -LiteralPath $Settings.ManagedFilesLocalPath -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]::new(
                "Managed-files local path not found: $($Settings.ManagedFilesLocalPath)")
        }
        $baseDir = (Resolve-Path -LiteralPath $Settings.ManagedFilesLocalPath).Path

        $configDir = $null
        if ($Settings.ConfigLocalPath -and (Test-Path -LiteralPath $Settings.ConfigLocalPath -PathType Container)) {
            $configDir = (Resolve-Path -LiteralPath $Settings.ConfigLocalPath).Path
        }

        return @{
            ManagedBaseDir = $baseDir
            ConfigDir      = $configDir
            SourceKind     = 'local'
            CheckoutDir    = $null
            ToolPath       = $baseDir
        }
    }

    if (-not $GitPath) {
        throw [System.InvalidOperationException]::new(
            "git is required to fetch managed files from '$($Settings.ManagedFilesRepo)' but was not found on PATH. Provide -ManagedFilesLocalPath to use a local source instead.")
    }

    $checkout = Get-AvmManagedFilesCheckout -Repo $Settings.ManagedFilesRepo -Ref $Settings.ManagedFilesRef -GitPath $GitPath
    $baseDir = Join-Path $checkout $Settings.ManagedFilesPath

    $configDir = $null
    if ($Settings.ConfigLocalPath -and (Test-Path -LiteralPath $Settings.ConfigLocalPath -PathType Container)) {
        $configDir = (Resolve-Path -LiteralPath $Settings.ConfigLocalPath).Path
    }
    elseif ($Settings.ConfigRepo -eq $Settings.ManagedFilesRepo -and $Settings.ConfigRef -eq $Settings.ManagedFilesRef) {
        $configDir = Join-Path $checkout $Settings.ConfigPath
    }
    else {
        $configCheckout = Get-AvmManagedFilesCheckout -Repo $Settings.ConfigRepo -Ref $Settings.ConfigRef -GitPath $GitPath
        $configDir = Join-Path $configCheckout $Settings.ConfigPath
    }

    return @{
        ManagedBaseDir = $baseDir
        ConfigDir      = $configDir
        SourceKind     = 'governance'
        CheckoutDir    = $checkout
        ToolPath       = $baseDir
    }
}

function Get-AvmManagedFilesCheckout {
    <#
    .SYNOPSIS
        Shallow clone (or fetch, when already cached) a git repo at a ref into
        the AVM cache and return the checkout root.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Populates a private cache directory used read-only by the caller; not a user-facing state change.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Repo,

        [Parameter(Mandatory)]
        [string] $Ref,

        [Parameter(Mandatory)]
        [string] $GitPath
    )

    $homeDir = if ($env:AVM_HOME) { $env:AVM_HOME } else { Join-Path ([System.IO.Path]::GetTempPath()) 'avm' }
    $slug = $Repo -replace '[\\/]', '_'
    $cacheRoot = Join-Path (Join-Path (Join-Path (Join-Path $homeDir 'cache') 'managed-files') $slug) $Ref

    if (Test-Path -LiteralPath (Join-Path $cacheRoot '.git') -PathType Container) {
        Invoke-AvmProcess -FilePath $GitPath -ArgumentList @('-C', $cacheRoot, 'fetch', '--depth', '1', 'origin', $Ref) | Out-Null
        Invoke-AvmProcess -FilePath $GitPath -ArgumentList @('-C', $cacheRoot, 'checkout', '-q', 'FETCH_HEAD') | Out-Null
    }
    else {
        $parent = Split-Path -Parent $cacheRoot
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if (Test-Path -LiteralPath $cacheRoot) {
            Remove-Item -LiteralPath $cacheRoot -Recurse -Force
        }
        Invoke-AvmProcess -FilePath $GitPath -ArgumentList @('clone', '--depth', '1', '--branch', $Ref, "https://github.com/$Repo.git", $cacheRoot) | Out-Null
    }

    return $cacheRoot
}

function Get-AvmManagedFilesCheckoutProvenance {
    <#
    .SYNOPSIS
        Read the commit sha and committer date from a managed-files checkout,
        returning empty strings when git cannot answer.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $CheckoutDir,

        [AllowEmptyString()]
        [string] $GitPath = ''
    )

    $result = @{ Commit = ''; CommitDate = '' }
    if (-not $GitPath -or -not (Test-Path -LiteralPath $CheckoutDir -PathType Container)) { return $result }

    try {
        $sha = Invoke-AvmProcess -FilePath $GitPath -ArgumentList @('-C', $CheckoutDir, 'rev-parse', 'HEAD') -TimeoutSec 30 -IgnoreExitCode
        if ($sha.ExitCode -eq 0) { $result.Commit = ([string]$sha.StdOut).Trim() }

        $date = Invoke-AvmProcess -FilePath $GitPath -ArgumentList @('-C', $CheckoutDir, 'show', '-s', '--format=%cI', 'HEAD') -TimeoutSec 30 -IgnoreExitCode
        if ($date.ExitCode -eq 0) {
            $raw = ([string]$date.StdOut).Trim()
            $parsed = [datetimeoffset]::MinValue
            if ($raw -and [datetimeoffset]::TryParse($raw, [ref]$parsed)) {
                $result.CommitDate = $parsed.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
        }
    }
    catch {
        Write-AvmLog ("sync: could not read managed-files provenance: {0}" -f $_.Exception.Message) -Level Verbose | Out-Null
    }

    return $result
}

function Get-AvmGitIndexMode {
    <#
    .SYNOPSIS
        Read git tree-entry modes ('100644' / '100755') from a directory's git
        index, keyed by forward-slash relative path. Returns an empty map when
        git is unavailable or the directory is not a working tree.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Dir,

        [string] $GitPath
    )

    $modeMap = @{}
    if (-not $GitPath) { return $modeMap }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $modeMap }

    $result = $null
    try {
        $result = Invoke-AvmProcess -FilePath $GitPath -ArgumentList @('-C', $Dir, 'ls-files', '--stage', '--', '.') -IgnoreExitCode
    }
    catch {
        return $modeMap
    }

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrEmpty($result.StdOut)) { return $modeMap }

    foreach ($line in ($result.StdOut -split "`n")) {
        if ($line -match '^(\d{6})\s+[0-9a-f]+\s+\d+\t(.+)$') {
            $modeMap[($matches[2] -replace '\\', '/')] = $matches[1]
        }
    }
    return $modeMap
}

function Resolve-AvmManagedFileTargetPath {
    <#
    .SYNOPSIS
        Resolve a managed source path to its concrete repository target paths.

    .DESCRIPTION
        Paths below a reserved '<parent>/_all/' source subtree are broadcast
        into each existing immediate child directory of the corresponding
        target parent. Multiple reserved segments are expanded from left to
        right. A root-level '_all/' and all other paths are returned unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath,

        [Parameter(Mandatory)]
        [string] $TargetRoot
    )

    $broadcast = [System.Text.RegularExpressions.Regex]::Match(
        $RelativePath,
        '^(.+?)/_all/(.+)$',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $broadcast.Success) {
        return $RelativePath
    }

    $parentPath = $broadcast.Groups[1].Value
    $suffix = $broadcast.Groups[2].Value
    $parentRoot = Join-Path $TargetRoot ($parentPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $parentRoot -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $parentRoot -Directory -Force |
        Where-Object { $_.Name -ne '_all' } |
        Sort-Object -Property Name |
        ForEach-Object {
            $expandedPath = "$parentPath/$($_.Name)/$suffix"
            Resolve-AvmManagedFileTargetPath -RelativePath $expandedPath -TargetRoot $TargetRoot
        }
}

function Add-AvmManagedFilesFromDir {
    <#
    .SYNOPSIS
        Add every file under a base directory to a managed-files map keyed by
        forward-slash relative path, capturing the source path and git index
        mode. Dotfiles are included; '.gitkeep' placeholders and the group's
        reserved '_config.json' are not.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Populates a caller-owned hashtable; performs no external state change.')]
    param(
        [string] $BaseDir,

        [Parameter(Mandatory)]
        [hashtable] $Map,

        [Parameter(Mandatory)]
        [string] $TargetRoot,

        [string] $GitPath
    )

    if ([string]::IsNullOrEmpty($BaseDir)) { return }
    if (-not (Test-Path -LiteralPath $BaseDir -PathType Container)) {
        Write-AvmLog "Managed files directory does not exist: $BaseDir" -Level Warning
        return
    }

    # Get-Item (not Resolve-Path) so the prefix matches Get-ChildItem FullName:
    # Resolve-Path preserves 8.3 short components, Get-ChildItem expands them.
    $baseDirAbsolute = (Get-Item -LiteralPath $BaseDir -Force).FullName
    $modeMap = Get-AvmGitIndexMode -Dir $baseDirAbsolute -GitPath $GitPath

    # -Force: dotfiles are hidden on Linux/macOS and would be skipped silently.
    $reservedConfigName = Get-AvmManagedFileGroupConfigFileName
    $sourceFiles = @(
        Get-ChildItem -LiteralPath $baseDirAbsolute -Recurse -File -Force | Where-Object {
            # '.gitkeep' placeholders keep otherwise-empty directories tracked in
            # git and are never real managed content. Managed-files no longer
            # ships any, but the guard stays: one that slipped through would land
            # in every target repo and need a 'deletedFiles' entry to unwind.
            $_.Name -ne '.gitkeep'
        } | ForEach-Object {
            $relativePath = [System.IO.Path]::GetRelativePath($baseDirAbsolute, $_.FullName) -replace '\\', '/'
            $mode = $modeMap[$relativePath]
            if (-not $mode) { $mode = '100644' }
            [pscustomobject]@{
                RelativePath = $relativePath
                Source       = $_.FullName -replace '\\', '/'
                Mode         = $mode
                IsBroadcast  = $relativePath -cmatch '^.+?/_all/.+'
            }
        } | Where-Object {
            # A group's '_config.json' declares that group's 'deletedFiles' and
            # 'managedLines'. It is instruction, not payload, so it is reserved
            # at the group root only; a nested '_config.json' deeper in the tree
            # is ordinary content and still syncs.
            $_.RelativePath -cne $reservedConfigName
        }
    )

    # Broadcast templates are applied before literal paths from the same source,
    # so a concrete path remains the more-specific override. Build calls this
    # helper once per source in precedence order, preserving overlay wins.
    $broadcastFiles = @($sourceFiles | Where-Object { $_.IsBroadcast } | Sort-Object -Property RelativePath)
    $literalFiles = @($sourceFiles | Where-Object { -not $_.IsBroadcast } | Sort-Object -Property RelativePath)
    foreach ($sourceFile in @($broadcastFiles + $literalFiles)) {
        foreach ($targetPath in @(Resolve-AvmManagedFileTargetPath -RelativePath $sourceFile.RelativePath -TargetRoot $TargetRoot)) {
            $Map[$targetPath] = @{
                Source = $sourceFile.Source
                Mode   = $sourceFile.Mode
            }
        }
    }
}

function Build-AvmManagedFilesMap {
    <#
    .SYNOPSIS
        Build the managed-files map and the deleted-file list by walking the
        ordered file groups that apply to a repository.

    .DESCRIPTION
        File groups are applied in the order supplied. A file present in more
        than one group is taken from the last group that declares it, so later
        groups win over earlier ones.

        Each group may also declare deleted files. A deletion removes the path
        from the map at the point the group is applied, so a later group can
        re-add a file that an earlier group deleted, and a later group can
        delete a file that an earlier group added. Any path still present in
        the map at the end is not reported as deleted.

        Returns a hashtable with 'Files' (target path -> source descriptor) and
        'Deleted' (sorted target paths that should not exist in the repository).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function; returns a new hashtable and mutates no external state.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $BaseDir,

        [Parameter(Mandatory)]
        [string] $TargetRoot,

        [string[]] $FileGroups = @(),

        [hashtable] $DeletedFilesByGroup = @{},

        [string] $RepoId,

        [string] $GitPath
    )

    $map = @{}
    $deleted = @{}

    foreach ($fileGroup in $FileGroups) {
        if ([string]::IsNullOrWhiteSpace($fileGroup)) { continue }

        Add-AvmManagedFilesFromDir -BaseDir (Join-Path $BaseDir $fileGroup) -Map $map -TargetRoot $TargetRoot -GitPath $GitPath

        if (-not $DeletedFilesByGroup.ContainsKey($fileGroup)) { continue }
        foreach ($deletedPath in @($DeletedFilesByGroup[$fileGroup])) {
            if ([string]::IsNullOrWhiteSpace($deletedPath)) { continue }
            foreach ($resolvedPath in @(Resolve-AvmManagedFileTargetPath -RelativePath $deletedPath -TargetRoot $TargetRoot)) {
                if ($map.ContainsKey($resolvedPath)) {
                    $map.Remove($resolvedPath) | Out-Null
                    Write-AvmLog "File group '$fileGroup' deletes managed file: $resolvedPath" -Level Verbose
                }
                $deleted[$resolvedPath] = $true
            }
        }
    }

    # A later group re-adding a path un-deletes it.
    foreach ($presentPath in @($map.Keys)) { $deleted.Remove($presentPath) | Out-Null }

    Write-AvmLog "Resolved $($map.Count) managed file(s) and $($deleted.Count) deleted file(s) for repository '$RepoId' (fileGroups='$($FileGroups -join ', ')')." -Level Verbose

    return @{
        Files   = $map
        Deleted = @($deleted.Keys | Sort-Object)
    }
}

function Get-AvmManagedFileGroupConfigFileName {
    <#
    .SYNOPSIS
        The reserved file name that carries a managed-file group's config.

    .DESCRIPTION
        The leading underscore keeps the file visually distinct from the payload
        it sits beside, which is dotfile-heavy, and matches the existing '_all'
        broadcast convention where an underscore prefix marks a name the sync
        interprets rather than copies.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return '_config.json'
}

function Get-AvmManagedFileGroupConfig {
    <#
    .SYNOPSIS
        Read a managed-file group's '_config.json', or return $null when the
        group does not declare one.

    .DESCRIPTION
        The config is optional to the engine: a group that only ships payload
        needs no instructions. The managed-files repository requires one on
        every group so each carries a human-readable 'description', but that is
        a repository policy enforced there, not a contract the engine relies on.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string] $BaseDir,

        [Parameter(Mandatory)]
        [string] $FileGroup
    )

    Set-StrictMode -Version 3.0

    $path = Join-Path (Join-Path $BaseDir $FileGroup) (Get-AvmManagedFileGroupConfigFileName)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    $raw = Get-Content -LiteralPath $path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    try {
        return ($raw | ConvertFrom-Json)
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "Managed-file group config is not valid JSON: $path ($($_.Exception.Message))")
    }
}

function Get-AvmManagedFilesDeletedFileMap {
    <#
    .SYNOPSIS
        Read each file group's '_config.json' and return a map of group name to
        the paths that group deletes.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $BaseDir,

        [string[]] $FileGroups = @()
    )

    Set-StrictMode -Version 3.0

    $map = @{}

    foreach ($fileGroup in $FileGroups) {
        if ([string]::IsNullOrWhiteSpace($fileGroup)) { continue }

        $config = Get-AvmManagedFileGroupConfig -BaseDir $BaseDir -FileGroup $fileGroup
        if ($null -eq $config) { continue }
        if (-not ($config.PSObject.Properties.Name -contains 'deletedFiles')) { continue }
        if (-not $config.deletedFiles) { continue }

        $map[[string]$fileGroup] = @($config.deletedFiles)
    }

    return $map
}

function Resolve-AvmManagedFilesRepositorySetting {
    <#
    .SYNOPSIS
        Resolve the ordered managed-file groups that apply to a repository from a
        parsed config.json by matching the repository id against
        'repositoryGroups'.

    .DESCRIPTION
        A repository may belong to several groups that each declare a
        'managedFiles' list. All of them apply, stacked so that a later group's
        files win over an earlier one's.

        Stacking order is explicit: each group may carry an integer 'order'
        (default 0). Groups sort by that value ascending, with ties broken by
        declaration order in config.json. A lower order is applied earlier and
        therefore *loses* to a higher order. Relying on declaration order alone
        was fragile - reordering config.json for tidiness silently changed
        precedence.

        The 'default' group matches every repository via the '*' wildcard and
        carries a negative order so that its files always apply first.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function; returns a settings hashtable and mutates no external state.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object] $RepositoryConfig,

        [Parameter(Mandatory)]
        [string] $RepoId
    )

    $repositoryGroups = @()
    if ($RepositoryConfig.PSObject.Properties.Name -contains 'repositoryGroups' -and $RepositoryConfig.repositoryGroups) {
        $repositoryGroups = @(
            $RepositoryConfig.repositoryGroups |
                Where-Object { $_.repositories -contains '*' -or $_.repositories -contains $RepoId }
        )
    }

    $groupEntries = @()
    $declarationIndex = 0
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains 'managedFiles' -and $repositoryGroup.managedFiles) {
            $order = 0
            if ($repositoryGroup.PSObject.Properties.Name -contains 'order' -and $null -ne $repositoryGroup.order) {
                $order = [int] $repositoryGroup.order
            }
            foreach ($fileGroup in @($repositoryGroup.managedFiles)) {
                $groupEntries += [pscustomobject]@{
                    FileGroup = $fileGroup
                    Order     = $order
                    Index     = $declarationIndex
                }
            }
        }
        $declarationIndex++
    }

    $fileGroups = @(
        $groupEntries |
            Sort-Object -Property Order, Index |
            Select-Object -ExpandProperty FileGroup |
            Select-Object -Unique
    )

    return @{
        FileGroups = $fileGroups
    }
}

function Get-AvmMatchingDeprecatedPath {
    <#
    .SYNOPSIS
        Return the subset of deprecated candidate paths that are present on
        disk under a repository root, matching either an exact file or a
        directory.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]] $CandidatePaths = @(),

        [Parameter(Mandatory)]
        [string] $Root
    )

    $matched = @()
    foreach ($candidate in $CandidatePaths) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        $full = Join-Path $Root ($candidate.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (Test-Path -LiteralPath $full) {
            $matched += $candidate
        }
    }
    return $matched
}

function Get-AvmGitBlobSha {
    <#
    .SYNOPSIS
        Compute git's blob SHA-1 for the given content bytes in-process:
        sha1("blob " + length + "\0" + content).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [byte[]] $Bytes
    )

    if ($null -eq $Bytes) { $Bytes = New-Object byte[] 0 }

    $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $combined = New-Object byte[] ($header.Length + $Bytes.Length)
    [System.Array]::Copy($header, 0, $combined, 0, $header.Length)
    [System.Array]::Copy($Bytes, 0, $combined, $header.Length, $Bytes.Length)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hashBytes = $sha1.ComputeHash($combined)
        return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha1.Dispose()
    }
}

function Get-AvmDesiredManagedFile {
    <#
    .SYNOPSIS
        Build the desired managed-file set as { path -> @{ Bytes; Sha; Mode } }
        by reading each source file's bytes and computing its git blob SHA.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function; returns a new hashtable and mutates no external state.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ManagedFiles
    )

    $desired = @{}
    foreach ($targetPath in $ManagedFiles.Keys) {
        $entry = $ManagedFiles[$targetPath]
        $sourcePath = $entry.Source
        $mode = $entry.Mode
        if (-not $mode) { $mode = '100644' }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            Write-AvmLog "Managed file source missing on disk: $sourcePath (target=$targetPath)" -Level Warning
            continue
        }
        $bytes = [System.IO.File]::ReadAllBytes($sourcePath)
        $desired[$targetPath] = @{
            Bytes = $bytes
            Sha   = Get-AvmGitBlobSha -Bytes $bytes
            Mode  = $mode
        }
    }
    return $desired
}

function New-AvmSyncIssue {
    <#
    .SYNOPSIS
        Build a shared-shape Issue object for the managed-files sync engine.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function; returns a new pscustomobject and mutates no external state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $File,

        [Parameter(Mandatory)]
        [string] $Message
    )

    [pscustomobject][ordered]@{
        File     = $File
        Line     = 0
        Column   = 0
        Severity = 'error'
        Code     = ''
        Message  = $Message
    }
}
