function Resolve-AvmMapotfConfigDir {
    <#
    .SYNOPSIS
        Resolve a scoped directory holding vendored mapotf configs.

    .DESCRIPTION
        Returns the absolute path to the '*.mptf.hcl' bundle passed to
        'mapotf transform --mptf-dir'. Resolution order:

          1. $env:AVM_MPTF_CONFIG_DIR/<profile>.
          2. <Root>/config/mapotf/<profile>.
          3. <ModuleRoot>/Resources/mapotf/<profile>.

        Each candidate must be a directory containing at least one
        '*.mptf.hcl' file. Throws AvmConfigurationException when none
        resolve, so the transform engine surfaces as 'skipped' (a deliberate
        placeholder) rather than running mapotf against an empty config set.

    .PARAMETER Root
        The consumer repository root, used to locate an optional
        'config/mapotf/<profile>' override. Pass $Context.Root.

    .PARAMETER Profile
        Config profile to resolve: common, module, root, module-call, example,
        or test.

    .PARAMETER Optional
        Return $null instead of throwing when the profile does not exist.

    .OUTPUTS
        [string] absolute path to the resolved config directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [ValidateSet('common', 'module', 'root', 'module-call', 'example', 'test')]
        [string] $ProfileName,

        [switch] $Optional
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:AVM_MPTF_CONFIG_DIR) {
        $candidates.Add((Join-Path $env:AVM_MPTF_CONFIG_DIR $ProfileName))
    }

    $candidates.Add((Join-Path $Root (Join-Path 'config' (Join-Path 'mapotf' $ProfileName))))

    $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $candidates.Add((Join-Path $moduleRoot (Join-Path 'Resources' (Join-Path 'mapotf' $ProfileName))))

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        $configs = @(Get-ChildItem -LiteralPath $candidate -Filter '*.mptf.hcl' -File -ErrorAction SilentlyContinue)
        if ($configs.Count -gt 0) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    if ($Optional) {
        return $null
    }

    throw [AvmConfigurationException]::new(
        ("Cannot resolve the mapotf '{0}' config profile (looked in: {1}). " -f $ProfileName, ($candidates -join '; ')) +
        ("The profile normally ships inside the module under Resources/mapotf/{0}; " -f $ProfileName) +
        ("set AVM_MPTF_CONFIG_DIR or add config/mapotf/{0}/*.mptf.hcl to override it." -f $ProfileName))
}

function Get-AvmTerraformFile {
    <#
    .SYNOPSIS
        Enumerate the '*.tf' files mapotf would touch under a module root.

    .DESCRIPTION
        Returns FileInfo records for every '*.tf' and '*.tftest.hcl' file beneath $Root,
        excluding any path segment that begins with '.' (e.g. '.terraform',
        '.git') or equals 'node_modules'. Used by Invoke-AvmTerraformTransform
        to snapshot file hashes before/after the transform so the engine can
        report which files mapotf changed. Always returns an array (empty
        when nothing matches) so callers can rely on '.Count'.

    .PARAMETER Root
        The module root to walk.

    .OUTPUTS
        [object[]] of System.IO.FileInfo.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $terraformFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.tf' -ErrorAction SilentlyContinue)
    $testFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.tftest.hcl' -ErrorAction SilentlyContinue)
    return @(
        @($terraformFiles + $testFiles) |
            Where-Object {
                $rel = [System.IO.Path]::GetRelativePath($Root, $_.FullName)
                $parts = $rel -split '[\\/]'
                -not ($parts | Where-Object { $_.StartsWith('.') -or $_ -eq 'node_modules' })
            }
    )
}

function Get-AvmTerraformTransformTarget {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $targets = New-Object System.Collections.Generic.List[object]
    $scopes = @(Get-AvmMetadataScope -Context ([pscustomobject]@{
                Root      = $Root
                Ecosystem = 'terraform'
            }))
    foreach ($scope in $scopes) {
        if ($scope.ChildModule -and
            @(Get-ChildItem -LiteralPath $scope.Path -File -Filter '*.tf').Count -eq 0) {
            continue
        }

        $metadataPath = Join-Path $scope.Path 'metadata.json'
        $metadataFile = @(Get-ChildItem -LiteralPath $scope.Path -File |
                Where-Object { $_.Name -ceq 'metadata.json' })
        if ($metadataFile.Count -eq 0) {
            throw [AvmConfigurationException]::new(
                "Terraform module '$($scope.Path)' requires metadata.json before telemetry transformation.")
        }
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop |
                ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new(
                "Cannot read Terraform module metadata '$metadataPath': $($_.Exception.Message)")
        }
        if ($metadata -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Terraform module metadata '$metadataPath' must contain a JSON object.")
        }

        $prefix = [string]$metadata['telemetryIdPrefix']
        if ($metadata.Contains('telemetryIdPrefix') -and [string]::IsNullOrWhiteSpace($prefix)) {
            throw [AvmConfigurationException]::new(
                "Terraform module metadata '$metadataPath' has an empty telemetryIdPrefix.")
        }
        $profiles = if ($prefix) {
            @('root', 'module', 'common')
        }
        else {
            @('module', 'common')
        }
        $targets.Add([pscustomobject]@{
                Path     = $scope.Path
                Scope    = if ($scope.ChildModule) { 'module' } else { 'root' }
                Profiles = $profiles
            })
    }

    $examplesDir = Join-Path $Root 'examples'
    if (Test-Path -LiteralPath $examplesDir -PathType Container) {
        foreach ($example in Get-ChildItem -LiteralPath $examplesDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name) {
            $terraformFiles = @(Get-ChildItem -LiteralPath $example.FullName -File -Filter '*.tf' -ErrorAction SilentlyContinue)
            if ($terraformFiles.Count -eq 0) {
                continue
            }
            $targets.Add([pscustomobject]@{
                    Path     = $example.FullName
                    Scope    = 'example'
                    Profiles = @('example', 'common')
                })
        }
    }

    foreach ($moduleTarget in @($targets | Where-Object { $_.Profiles -contains 'root' })) {
        $testsDir = Join-Path $moduleTarget.Path 'tests'
        if (Test-Path -LiteralPath $testsDir -PathType Container) {
            $testRoots = Get-ChildItem -LiteralPath $testsDir -Recurse -File -Filter '*.tf' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Directory.FullName } |
                Sort-Object -Unique
            foreach ($testRoot in $testRoots) {
                $rel = [System.IO.Path]::GetRelativePath($testsDir, $testRoot)
                if (@($rel -split '[\\/]' | Where-Object { $_.StartsWith('.') -or $_ -eq 'node_modules' }).Count -gt 0) {
                    continue
                }
                $targets.Add([pscustomobject]@{
                        Path     = $testRoot
                        Scope    = 'test'
                        Profiles = @('test')
                    })
            }
        }
    }

    return $targets.ToArray()
}

function Remove-AvmLegacyTelemetryTestMock {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [object[]] $ModuleTargets
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $changes = [System.Collections.Generic.List[object]]::new()
    $emptyMock = '(?m)^[ \t]*mock_provider[ \t]+"modtm"[ \t]*\{[ \t\r\n]*\}[ \t]*(?:\r?\n)?'
    $customMock = '(?m)^[ \t]*mock_provider[ \t]+"modtm"[ \t]*\{'
    $legacyReference = '(?<![A-Za-z0-9_])modtm_telemetry\.telemetry(?![A-Za-z0-9_])'

    foreach ($file in Get-AvmTerraformFile -Root $Root |
            Where-Object { $_.Name.EndsWith('.tftest.hcl', [System.StringComparison]::OrdinalIgnoreCase) }) {
        $owner = $ModuleTargets |
            Where-Object {
                $file.FullName.StartsWith(
                    ($_.Path + [System.IO.Path]::DirectorySeparatorChar),
                    [System.StringComparison]::Ordinal)
            } |
            Sort-Object { $_.Path.Length } -Descending |
            Select-Object -First 1
        if ($null -eq $owner) {
            throw [AvmConfigurationException]::new(
                "Cannot determine the Terraform module that owns test file '$($file.FullName)'.")
        }
        if ($owner.Profiles -notcontains 'root') {
            continue
        }

        $original = [System.IO.File]::ReadAllText($file.FullName)
        $updated = [regex]::Replace($original, $emptyMock, '')
        if ([regex]::IsMatch($updated, $customMock)) {
            throw [AvmConfigurationException]::new(
                "Test file '$($file.FullName)' contains a non-empty modtm mock; remove or rewrite it manually before telemetry migration.")
        }
        $updated = [regex]::Replace($updated, $legacyReference, 'azapi_resource.telemetry')
        if ($updated -cne $original) {
            $changes.Add([pscustomobject]@{ Path = $file.FullName; Content = $updated })
        }
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($change in $changes) {
        if ($PSCmdlet.ShouldProcess($change.Path, 'remove legacy modtm test mocks and references')) {
            [System.IO.File]::WriteAllText($change.Path, $change.Content, $encoding)
        }
    }
}

function Get-AvmRemainingModtmIssue {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [object[]] $Targets
    )

    Set-StrictMode -Version 3.0
    $issues = [System.Collections.Generic.List[object]]::new()
    foreach ($target in $Targets | Where-Object { $_.Profiles -contains 'root' -or $_.Scope -eq 'test' }) {
        foreach ($file in Get-ChildItem -LiteralPath $target.Path -Filter '*.tf' -File) {
            $lineNumber = 0
            foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                $lineNumber++
                if ($line -cmatch '^\s*(resource|data)\s+"modtm_[^"]+"\s+"[^"]+"') {
                    $issues.Add([pscustomobject][ordered]@{
                            File     = [System.IO.Path]::GetRelativePath($Root, $file.FullName)
                            Line     = $lineNumber
                            Column   = 1
                            Severity = 'error'
                            Code     = 'avm.tf.modtm-remains'
                            Message  = 'An author-owned modtm block remains after telemetry migration; migrate it before removing the modtm provider.'
                        })
                }
            }
        }
    }
    return $issues.ToArray()
}

function Test-AvmMapotfTransientProviderError {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Output
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }

    $normalized = $Output `
        -replace '\x1B\[[0-?]*[ -/]*[@-~]', '' `
        -replace '[\r\n\u2502]+', ' ' `
        -replace '\s+', ' '

    $patterns = @(
        'context deadline exceeded'
        'Client\.Timeout exceeded while awaiting headers'
        'failed to retrieve cryptographic signature for provider'
        '(?:provider|registry).*(?:500 Internal Server Error|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout)'
    )

    foreach ($pattern in $patterns) {
        if ($normalized -match $pattern) {
            return $true
        }
    }

    return $false
}

function Invoke-AvmMapotfTransformTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Target,

        [Parameter(Mandatory)]
        [object] $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $transformArguments = New-Object System.Collections.Generic.List[string]
    $transformArguments.Add('transform')
    foreach ($profileName in $Target.Profiles) {
        $profileDir = $Options.ProfileDirs[$profileName]
        if (-not $profileDir) {
            continue
        }
        $transformArguments.Add('--mptf-dir')
        $transformArguments.Add($profileDir)
    }
    $transformArguments.Add('--tf-dir')
    $transformArguments.Add($Target.Path)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $maxRetries = 2
    $attempt = 0
    do {
        $transform = Invoke-AvmProcess `
            -FilePath $Options.ToolPath `
            -ArgumentList $transformArguments.ToArray() `
            -WorkingDirectory $Target.Path `
            -EnvVars $Options.EnvVars `
            -IgnoreExitCode
        if ($transform.ExitCode -eq 0) {
            break
        }

        $combinedOutput = @($transform.StdOut, $transform.StdErr) -join [System.Environment]::NewLine
        if (
            $attempt -ge $maxRetries -or
            -not (Test-AvmMapotfTransientProviderError -Output $combinedOutput)
        ) {
            $message = Add-AvmProcessFailureDetail `
                -Message ('mapotf transform exited with code {0} for {1} target {2}.' -f $transform.ExitCode, $Target.Scope, $Target.Path) `
                -StdOut $transform.StdOut `
                -StdErr $transform.StdErr
            throw [AvmProcessException]::new($message)
        }

        $attempt++
        $delaySeconds = $attempt * 5
        Write-AvmLog (
            'transform: transient provider download failure; retrying {0} target in {1}s ({2} of {3})' -f
            $Target.Scope, $delaySeconds, $attempt, $maxRetries
        ) -Level Warning | Out-Null
        Start-Sleep -Seconds $delaySeconds
    } while ($attempt -le $maxRetries)
    $stopwatch.Stop()

    Write-AvmLog (
        'transform: {0} target completed in {1}: {2}' -f
        $Target.Scope, (Format-AvmDuration -Duration $stopwatch.Elapsed), $Target.Path
    ) -Level Verbose | Out-Null
}

function Invoke-AvmTerraformTransform {
    <#
    .SYNOPSIS
        Apply the AVM mapotf HCL transforms to a Terraform module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmTransform when the module
        context is Ecosystem='terraform'. Resolves the 'mapotf' binary via
        Resolve-AvmTool and the vendored config bundle via
        Resolve-AvmMapotfConfigDir, then runs, against $Context.Root:

            mapotf transform --mptf-dir <profile> [...] --tf-dir <target>
            mapotf clean-backup --tf-dir <root>

        Metadata-backed roots and child modules with a telemetryIdPrefix run
        root, module, common. Children without a prefix run module, common.
        Module calls then run module-call, common after every child has its
        telemetry inputs, forwarding enable_telemetry and telemetry_location.
        Examples run example, common after the module calls have settled.
        Standalone test-module directories run the test profile, and empty
        modtm test mocks and telemetry resource references are migrated.
        Non-empty modtm mocks fail with an actionable error. The final call
        removes '*.tf.mptfbackup' files.

        Several of the vendored configs (e.g. order_resource_attrs) read
        provider schemas, so mapotf shells out to 'terraform init' +
        'terraform providers schema'. mapotf locates 'terraform' by name on
        PATH, but GitHub-hosted runners no longer ship terraform on PATH (it
        was removed from the images). The engine therefore resolves the pinned
        terraform via Resolve-AvmTool and prepends its directory to PATH for
        the mapotf subprocess; environment variables propagate to mapotf's own
        terraform grandchild, so the schema reads succeed against the managed
        binary. A terraform that cannot be resolved (AvmToolException)
        propagates so the chain reports 'skipped', matching missing-mapotf.

        File-hash snapshots taken before and after the transform populate the
        'Changed' field (relative paths of every '*.tf' or '*.tftest.hcl'
        file added, removed or modified).

        Drift mode (-CheckDrift, used by pr-check): mapotf has no dry-run, so
        the transform still runs and any 'Changed' file becomes a Status='fail'
        Issue. The transformed content is then rolled back, so drift mode leaves
        the working copy byte-identical. The contract is "a module that already
        ran pre-commit has nothing for mapotf to change"; a non-empty change set
        in CI therefore means the author did not run pre-commit, and pr-check
        flags it.

        Root and local-module targets finish before module calls and examples
        inspect their inputs. Each group runs through the bounded Invoke-AvmParallel
        scheduler. A configured TF_PLUGIN_CACHE_DIR forces serial target
        execution because Terraform's shared provider plugin cache is not
        concurrency-safe.

        mapotf exit codes: 0 = success. A transform failure caused by a
        recognized transient Terraform provider network error is retried twice
        with incremental delay; other failures and retry exhaustion surface as
        AvmProcessException. A missing mapotf binary (AvmToolException) or a
        missing config bundle (AvmConfigurationException) propagates so the
        composition chain reports the step as 'skipped' on an unconfigured
        workstation.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER CheckDrift
        When set, treat any file mapotf changed as a failure (Status='fail'
        with one Issue per changed file) instead of a silent fix. Used by the
        pr-check chain.

    .PARAMETER ThrottleLimit
        Maximum number of independent root, module, or example targets to
        transform at once. Defaults to one for direct engine calls.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Changed, Issues.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [switch] $CheckDrift,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = 1
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformTransform requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'mapotf' -AllowPathFallback:$AllowPathFallback
    $profileDirs = @{
        common        = Resolve-AvmMapotfConfigDir -Root $Context.Root -ProfileName 'common'
        module        = Resolve-AvmMapotfConfigDir -Root $Context.Root -ProfileName 'module'
        root          = Resolve-AvmMapotfConfigDir -Root $Context.Root -ProfileName 'root'
        'module-call' = Resolve-AvmMapotfConfigDir -Root $Context.Root -ProfileName 'module-call'
        example       = Resolve-AvmMapotfConfigDir -Root $Context.Root -ProfileName 'example'
        test          = Resolve-AvmMapotfConfigDir -Root $Context.Root -ProfileName 'test'
    }
    $targets = @(Get-AvmTerraformTransformTarget -Root $Context.Root)
    Write-AvmLog ("transform: discovered {0} target(s)" -f $targets.Count) -Level Verbose | Out-Null

    $beforeFiles = Get-AvmTerraformFile -Root $Context.Root
    Write-AvmLog ("transform: discovered {0} terraform file(s)" -f $beforeFiles.Count) -Level Verbose | Out-Null

    if (-not $PSCmdlet.ShouldProcess($Context.Root, ("mapotf transform across {0} scoped target(s)" -f $targets.Count))) {
        return [pscustomobject][ordered]@{
            Engine         = 'terraform'
            Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
            ToolPath       = $tool.Path
            ToolSource     = $tool.Source
            Status         = 'skipped'
            FilesProcessed = $beforeFiles.Count
            Changed        = @()
            Issues         = @()
        }
    }

    $before = @{}
    foreach ($f in $beforeFiles) {
        $before[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    }

    # Drift mode must not mutate the caller's working copy. mapotf has no
    # dry-run, so snapshot Terraform and test files up front and roll back in the finally -
    # drift is still computed from the post-transform tree, but the tree is left
    # byte-identical even if mapotf throws part-way through.
    $snapshot = $null
    $legacyIssues = @()
    if ($CheckDrift) {
        Write-AvmLog ("transform: check-drift mode; snapshotting {0} file(s)" -f $beforeFiles.Count) -Level Verbose | Out-Null
        $snapshot = Get-AvmFileSnapshot -Path @($beforeFiles | ForEach-Object { $_.FullName })
    }

    try {
        # mapotf reads provider schemas (order_resource_attrs et al.) by shelling
        # out to terraform, which it finds by name on PATH. GitHub-hosted runners
        # no longer ship terraform on PATH, so resolve the pinned terraform the
        # same way as mapotf (managed cache, not a stray PATH binary) and prepend
        # its directory to PATH for the mapotf subprocess. The override propagates
        # to mapotf's terraform grandchild. A missing terraform throws
        # AvmToolException, which the chain surfaces as 'skipped' just like a
        # missing mapotf binary.
        $terraform = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback
        Write-AvmLog ("transform: resolved terraform dependency at {0}" -f $terraform.Path) -Level Verbose | Out-Null
        $mapotfEnv = New-AvmToolPathEnvironment `
            -ToolPath $terraform.Path `
            -ToolName 'terraform'

        $effectiveThrottle = $ThrottleLimit
        $pluginCache = [string]$env:TF_PLUGIN_CACHE_DIR
        if ($effectiveThrottle -gt 1 -and -not [string]::IsNullOrWhiteSpace($pluginCache)) {
            $effectiveThrottle = 1
            Write-AvmLog (
                'transform: TF_PLUGIN_CACHE_DIR is configured; running Mapotf targets serially because the shared Terraform provider cache is not concurrency-safe'
            ) -Level Verbose | Out-Null
        }

        $transformOptions = [pscustomobject]@{
            ToolPath    = $tool.Path
            ProfileDirs = $profileDirs
            EnvVars     = $mapotfEnv
        }
        $moduleTargets = @($targets | Where-Object { $_.Scope -in @('root', 'module') })

        $exampleTargets = @($targets | Where-Object { $_.Scope -eq 'example' })

        $testTargets = @($targets | Where-Object { $_.Scope -eq 'test' })
        Invoke-AvmParallel `
            -InputObject $moduleTargets `
            -FunctionName 'Invoke-AvmMapotfTransformTarget' `
            -Argument $transformOptions `
            -ThrottleLimit $effectiveThrottle
        $moduleCallTargets = @($moduleTargets |
                Where-Object { $_.Profiles -contains 'root' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Path     = $_.Path
                        Scope    = $_.Scope
                        Profiles = @('module-call', 'common')
                    }
                })
        if ($moduleCallTargets.Count -gt 0) {
            Invoke-AvmParallel `
                -InputObject $moduleCallTargets `
                -FunctionName 'Invoke-AvmMapotfTransformTarget' `
                -Argument $transformOptions `
                -ThrottleLimit $effectiveThrottle
        }
        if ($exampleTargets.Count -gt 0) {
            Invoke-AvmParallel `
                -InputObject $exampleTargets `
                -FunctionName 'Invoke-AvmMapotfTransformTarget' `
                -Argument $transformOptions `
                -ThrottleLimit $effectiveThrottle
        }
        if ($testTargets.Count -gt 0) {
            Invoke-AvmParallel `
                -InputObject $testTargets `
                -FunctionName 'Invoke-AvmMapotfTransformTarget' `
                -Argument $transformOptions `
                -ThrottleLimit $effectiveThrottle
        }
        Remove-AvmLegacyTelemetryTestMock -Root $Context.Root -ModuleTargets $moduleTargets
        Write-AvmLog 'transform: mapotf scoped transforms completed' -Level Verbose | Out-Null

        foreach ($target in $targets) {
            $clean = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('clean-backup', '--tf-dir', $target.Path) `
                -WorkingDirectory $target.Path `
                -EnvVars $mapotfEnv `
                -IgnoreExitCode
            if ($clean.ExitCode -ne 0) {
                $message = Add-AvmProcessFailureDetail `
                    -Message ('mapotf clean-backup exited with code {0} for {1} target {2}.' -f $clean.ExitCode, $target.Scope, $target.Path) `
                    -StdOut $clean.StdOut `
                    -StdErr $clean.StdErr
                throw [AvmProcessException]::new(
                    $message)
            }
        }
        Write-AvmLog 'transform: mapotf clean-backup completed' -Level Verbose | Out-Null

        $afterFiles = Get-AvmTerraformFile -Root $Context.Root
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        $changed = New-Object System.Collections.Generic.List[string]
        foreach ($f in $afterFiles) {
            $null = $seen.Add($f.FullName)
            $rel = [System.IO.Path]::GetRelativePath($Context.Root, $f.FullName)
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            if (-not $before.ContainsKey($f.FullName)) {
                $changed.Add($rel)
            }
            elseif ($before[$f.FullName] -ne $hash) {
                $changed.Add($rel)
            }
        }
        foreach ($key in $before.Keys) {
            if (-not $seen.Contains($key)) {
                $changed.Add([System.IO.Path]::GetRelativePath($Context.Root, $key))
            }
        }
        $legacyIssues = @(Get-AvmRemainingModtmIssue -Root $Context.Root -Targets @($moduleTargets + $testTargets))
    }
    finally {
        if ($null -ne $snapshot) {
            Write-AvmLog 'transform: restoring terraform snapshot after drift check' -Level Verbose | Out-Null
            $current = @(Get-AvmTerraformFile -Root $Context.Root | ForEach-Object { $_.FullName })
            Restore-AvmFileSnapshot -Snapshot $snapshot -CurrentPath $current
        }
    }

    $status = 'pass'
    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($legacyIssue in $legacyIssues) {
        $status = 'fail'
        $issues.Add($legacyIssue)
    }
    if ($CheckDrift -and $changed.Count -gt 0) {
        $status = 'fail'
        foreach ($rel in $changed) {
            $issues.Add([pscustomobject][ordered]@{
                    File     = $rel
                    Line     = 0
                    Column   = 0
                    Severity = 'error'
                    Code     = 'avm.tf.mapotf-drift'
                    Message  = ("mapotf transform modified '{0}'; run 'avm pre-commit -Ecosystem terraform' and commit the result." -f $rel)
                })
        }
        Write-AvmLog ("transform: completed; processed={0}; changed={1}; status={2}" -f $beforeFiles.Count, $changed.Count, $status) -Level Verbose | Out-Null
    }

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = $status
        FilesProcessed = $beforeFiles.Count
        Changed        = $changed.ToArray()
        Issues         = $issues.ToArray()
    }
}
