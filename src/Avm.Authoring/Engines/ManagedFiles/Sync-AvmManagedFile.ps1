function Sync-AvmManagedFile {
    <#
    .SYNOPSIS
        Synchronise a Terraform module repository's managed files against the
        AVM governance source-of-truth, applying additions, updates, and
        deprecated-file removals directly to the working tree.

    .DESCRIPTION
        Engine implementation behind Invoke-AvmSync. Ported from the
        Azure/avm-terraform-governance repo-sync tooling, reduced to the
        *file-sync* concern only: it never opens or merges a pull request, it
        mutates the local working tree ($Context.Root) in place.

        Source of the managed files (highest precedence first):

          1. Explicit cmdlet parameters.
          2. Environment variables (AVM_MANAGED_FILES_*).
          3. A repo-committed '.avm/managed-files.json' under $Context.Root.
          4. Defaults: the public Azure/avm-terraform-governance repo, 'main'
             ref, 'managed-files' base folder, and 'tf-repo-mgmt/repository-config'
             config folder.

        A direct local path (-ManagedFilesLocalPath or
        AVM_MANAGED_FILES_LOCAL_PATH) short-circuits the git fetch entirely and
        is what the offline tests use. Otherwise the source repo is shallow
        cloned (or fetched, if already cached) into $env:AVM_HOME/cache.

        The managed-file map is built from '<base>/root' plus zero or more
        overlays ('<base>/<overlay>') stacked in declaration order, where later
        sources win, minus any excluded paths. Overlays and exclusions are
        resolved from the config
        folder's 'config.json' by matching the repository id against
        'repositoryGroups'. 'deprecated-files.json' lists paths that must be
        removed from every target repo; deprecated removals win over managed
        adds when both name the same path.

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
        'Azure/avm-terraform-governance'.

    .PARAMETER ManagedFilesRef
        Git ref (branch/tag/sha) to fetch. Defaults to 'main'.

    .PARAMETER ManagedFilesPath
        Path within the source repo to the managed-files base folder (the one
        that contains 'root/' and the overlays). Defaults to 'managed-files'.

    .PARAMETER ManagedFilesLocalPath
        Direct local path to the managed-files base folder. When supplied the
        git fetch is skipped entirely.

    .PARAMETER ConfigRepo
        owner/name of the git repo that holds the config folder. Defaults to
        the same repo as ManagedFilesRepo.

    .PARAMETER ConfigRef
        Git ref for the config repo. Defaults to the same ref as
        ManagedFilesRef.

    .PARAMETER ConfigPath
        Path within the config repo to the folder holding 'config.json' and
        'deprecated-files.json'. Defaults to 'tf-repo-mgmt/repository-config'.

    .PARAMETER ConfigLocalPath
        Direct local path to the config folder. When supplied no config repo is
        fetched.

    .PARAMETER RepoId
        The repository id used to look up overlays/exclusions in config.json.
        Defaults to the leaf of $Context.Root with a leading
        'terraform-azurerm-' / 'terraform-azapi-' prefix stripped.

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

        [string] $RepoId
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

    $source = Resolve-AvmManagedFilesSource -Settings $settings -GitPath $gitPath

    $overlays = @()
    $excluded = @()
    $deprecated = @()
    if ($source.ConfigDir -and (Test-Path -LiteralPath $source.ConfigDir -PathType Container)) {
        $configFile = Join-Path $source.ConfigDir 'config.json'
        if (Test-Path -LiteralPath $configFile -PathType Leaf) {
            $repositoryConfig = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
            $resolved = Resolve-AvmManagedFilesRepositorySetting -RepositoryConfig $repositoryConfig -RepoId $settings.RepoId
            $overlays = $resolved.ManagedFilesAdditional
            $excluded = $resolved.ExcludedManagedFiles
        }
        $deprecatedFile = Join-Path $source.ConfigDir 'deprecated-files.json'
        if (Test-Path -LiteralPath $deprecatedFile -PathType Leaf) {
            $deprecated = @(Get-Content -LiteralPath $deprecatedFile -Raw | ConvertFrom-Json)
        }
    }

    $map = Build-AvmManagedFilesMap `
        -BaseDir $source.ManagedBaseDir `
        -Overlays $overlays `
        -Excluded $excluded `
        -RepoId $settings.RepoId `
        -GitPath $gitPath

    $desired = Get-AvmDesiredManagedFile -ManagedFiles $map

    # Deprecated removals win over managed adds if both name the same path.
    $matchedDeprecated = @(Get-AvmMatchingDeprecatedPath -CandidatePaths $deprecated -Root $root)
    $deprecatedLookup = @{}
    foreach ($p in $matchedDeprecated) { $deprecatedLookup[$p] = $true }
    foreach ($p in @($desired.Keys)) {
        if ($deprecatedLookup.ContainsKey($p)) { $desired.Remove($p) | Out-Null }
    }

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
            if ($existingSha -ne $desiredSha -or $existingMode -ne $desiredMode) {
                $toUpdate += $targetPath
            }
        }
    }
    $toRemove = @($matchedDeprecated | Sort-Object)

    $issues = @()
    if ($CheckDrift) {
        $issueList = New-Object System.Collections.Generic.List[object]
        foreach ($p in $toRemove) {
            $issueList.Add((New-AvmSyncIssue -File $p -Message 'deprecated file present in the repository; it should be removed.'))
        }
        foreach ($p in $toAdd) {
            $issueList.Add((New-AvmSyncIssue -File $p -Message 'managed file missing from the repository; it should be added.'))
        }
        foreach ($p in $toUpdate) {
            $issueList.Add((New-AvmSyncIssue -File $p -Message 'managed file is out of date; it should be updated.'))
        }
        $issues = $issueList.ToArray()
        $status = if ($issueList.Count -gt 0) { 'fail' } else { 'pass' }
    }
    else {
        $hasChanges = ($toAdd.Count + $toUpdate.Count + $toRemove.Count) -gt 0
        if ($hasChanges) {
            $applyDesc = ('sync managed files (add {0}, update {1}, remove {2})' -f $toAdd.Count, $toUpdate.Count, $toRemove.Count)
            if ($PSCmdlet.ShouldProcess($root, $applyDesc)) {
                foreach ($p in $toRemove) {
                    $full = Join-Path $root ($p.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                    if (Test-Path -LiteralPath $full) {
                        Remove-Item -LiteralPath $full -Recurse -Force
                    }
                }
                foreach ($p in @($toAdd + $toUpdate)) {
                    $full = Join-Path $root ($p.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                    $parent = Split-Path -Parent $full
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                        New-Item -ItemType Directory -Path $parent -Force | Out-Null
                    }
                    [System.IO.File]::WriteAllBytes($full, $desired[$p].Bytes)

                    if ($desired[$p].Mode -eq '100755' -and $gitPath) {
                        try {
                            Invoke-AvmProcess -FilePath $gitPath -ArgumentList @('-C', $root, 'add', '--', $p) -IgnoreExitCode | Out-Null
                            Invoke-AvmProcess -FilePath $gitPath -ArgumentList @('-C', $root, 'update-index', '--chmod=+x', '--', $p) -IgnoreExitCode | Out-Null
                        }
                        catch {
                            Write-Verbose "Failed to set executable bit on '$p': $($_.Exception.Message)"
                        }
                    }
                }
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
        FilesProcessed = $desired.Count
        Issues         = $issues
        Added          = $toAdd
        Updated        = $toUpdate
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

    $repo = & $pick $ManagedFilesRepo 'AVM_MANAGED_FILES_REPO' 'repo' 'Azure/avm-terraform-governance'
    $ref = & $pick $ManagedFilesRef 'AVM_MANAGED_FILES_REF' 'ref' 'main'
    $path = & $pick $ManagedFilesPath 'AVM_MANAGED_FILES_PATH' 'path' 'managed-files'
    $localPath = & $pick $ManagedFilesLocalPath 'AVM_MANAGED_FILES_LOCAL_PATH' 'localPath' ''

    $configRepoValue = & $pick $ConfigRepo 'AVM_MANAGED_FILES_CONFIG_REPO' 'configRepo' $repo
    $configRefValue = & $pick $ConfigRef 'AVM_MANAGED_FILES_CONFIG_REF' 'configRef' $ref
    $configPathValue = & $pick $ConfigPath 'AVM_MANAGED_FILES_CONFIG_PATH' 'configPath' 'tf-repo-mgmt/repository-config'
    $configLocalPath = & $pick $ConfigLocalPath 'AVM_MANAGED_FILES_CONFIG_LOCAL_PATH' 'configLocalPath' ''

    $repoIdDefault = Split-Path -Leaf $Root
    foreach ($prefix in @('terraform-azurerm-', 'terraform-azapi-')) {
        if ($repoIdDefault.StartsWith($prefix)) {
            $repoIdDefault = $repoIdDefault.Substring($prefix.Length)
            break
        }
    }
    $repoIdValue = & $pick $RepoId 'AVM_MANAGED_FILES_REPO_ID' 'repoId' $repoIdDefault

    return @{
        ManagedFilesRepo      = $repo
        ManagedFilesRef       = $ref
        ManagedFilesPath      = $path
        ManagedFilesLocalPath = $localPath
        ConfigRepo            = $configRepoValue
        ConfigRef             = $configRefValue
        ConfigPath            = $configPathValue
        ConfigLocalPath       = $configLocalPath
        RepoId                = $repoIdValue
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
        Write-Warning "Failed to parse '$configPath': $($_.Exception.Message)"
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

function Add-AvmManagedFilesFromDir {
    <#
    .SYNOPSIS
        Add every file under a base directory to a managed-files map keyed by
        forward-slash relative path, capturing the source path and git index
        mode. Dotfiles are included; '.gitkeep' placeholders are not.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Populates a caller-owned hashtable; performs no external state change.')]
    param(
        [string] $BaseDir,

        [Parameter(Mandatory)]
        [hashtable] $Map,

        [string] $GitPath
    )

    if ([string]::IsNullOrEmpty($BaseDir)) { return }
    if (-not (Test-Path -LiteralPath $BaseDir -PathType Container)) {
        Write-Warning "Managed files directory does not exist: $BaseDir"
        return
    }

    # Get-Item (not Resolve-Path) so the prefix matches Get-ChildItem FullName:
    # Resolve-Path preserves 8.3 short components, Get-ChildItem expands them.
    $baseDirAbsolute = (Get-Item -LiteralPath $BaseDir -Force).FullName
    $modeMap = Get-AvmGitIndexMode -Dir $baseDirAbsolute -GitPath $GitPath

    # -Force: dotfiles are hidden on Linux/macOS and would be skipped silently.
    Get-ChildItem -LiteralPath $baseDirAbsolute -Recurse -File -Force | Where-Object {
        # '.gitkeep' files exist only to keep otherwise-empty overlay
        # directories tracked in git. They are placeholders, never real managed
        # content, so they must not be synced into target repos. The upstream
        # avm-terraform-governance sync applies the same filter; omitting it
        # here would make every drift check demand a file the sync never writes.
        $_.Name -ne '.gitkeep'
    } | ForEach-Object {
        $relativePath = [System.IO.Path]::GetRelativePath($baseDirAbsolute, $_.FullName) -replace '\\', '/'
        $absoluteSource = $_.FullName -replace '\\', '/'
        $mode = $modeMap[$relativePath]
        if (-not $mode) { $mode = '100644' }
        $Map[$relativePath] = @{
            Source = $absoluteSource
            Mode   = $mode
        }
    }
}

function Build-AvmManagedFilesMap {
    <#
    .SYNOPSIS
        Build the managed-files map from '<base>/root' plus zero or more
        overlays, minus any excluded paths.

    .DESCRIPTION
        Overlays are applied in the order supplied, after 'root'. A file
        present in more than one source is taken from the last source that
        declares it, so later overlays win over earlier ones and every overlay
        wins over 'root'.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function; returns a new hashtable and mutates no external state.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $BaseDir,

        [string[]] $Overlays = @(),

        [string[]] $Excluded = @(),

        [string] $RepoId,

        [string] $GitPath
    )

    $rootDir = Join-Path $BaseDir 'root'

    $map = @{}
    Add-AvmManagedFilesFromDir -BaseDir $rootDir -Map $map -GitPath $GitPath
    foreach ($overlay in $Overlays) {
        if ([string]::IsNullOrWhiteSpace($overlay)) { continue }
        Add-AvmManagedFilesFromDir -BaseDir (Join-Path $BaseDir $overlay) -Map $map -GitPath $GitPath
    }

    foreach ($excludedPath in $Excluded) {
        if ($map.ContainsKey($excludedPath)) {
            $map.Remove($excludedPath) | Out-Null
            Write-Verbose "Excluded managed file from sync: $excludedPath"
        }
    }

    Write-Verbose "Resolved $($map.Count) managed file(s) for repository '$RepoId' (overlays='$($Overlays -join ', ')', exclusions=$($Excluded.Count))."
    return $map
}

function Resolve-AvmManagedFilesRepositorySetting {
    <#
    .SYNOPSIS
        Resolve the per-repository managed-files overlays and exclusions from a
        parsed config.json by matching the repository id against
        'repositoryGroups'.

    .DESCRIPTION
        A repository may belong to several groups that each declare a
        'managedFilesAdditional' overlay. All of them apply, stacked in the
        order the groups are declared in config.json, so a later group's files
        win over an earlier one's.
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
        $repositoryGroups = @($RepositoryConfig.repositoryGroups | Where-Object { $_.repositories -contains $RepoId })
    }

    $managedFilesAdditional = @()
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains 'managedFilesAdditional' -and $repositoryGroup.managedFilesAdditional) {
            $managedFilesAdditional += $repositoryGroup.managedFilesAdditional
        }
    }
    $managedFilesAdditional = @($managedFilesAdditional | Select-Object -Unique)

    $excludedManagedFiles = @()
    foreach ($repositoryGroup in $repositoryGroups) {
        if ($repositoryGroup.PSObject.Properties.Name -contains 'excludedManagedFiles' -and $repositoryGroup.excludedManagedFiles) {
            $excludedManagedFiles += @($repositoryGroup.excludedManagedFiles)
        }
    }
    $excludedManagedFiles = @($excludedManagedFiles | Select-Object -Unique)

    return @{
        ManagedFilesAdditional = $managedFilesAdditional
        ExcludedManagedFiles   = $excludedManagedFiles
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
            Write-Warning "Managed file source missing on disk: $sourcePath (target=$targetPath)"
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
