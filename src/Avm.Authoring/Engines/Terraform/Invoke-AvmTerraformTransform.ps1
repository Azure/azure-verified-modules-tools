function Resolve-AvmMapotfConfigDir {
    <#
    .SYNOPSIS
        Resolve the directory holding the vendored mapotf pre-commit configs.

    .DESCRIPTION
        Returns the absolute path to the '*.mptf.hcl' bundle passed to
        'mapotf transform --mptf-dir'. Resolution order:

          1. $env:AVM_MPTF_CONFIG_DIR - explicit override (test injection and
             power users).
          2. <ModuleRoot>/Resources/mapotf/pre-commit - forward-compatible
             location for when the configs ship inside the module itself.
          3. <RepoRoot>/config/mapotf/pre-commit - the configs as currently
             vendored at the top of this repository (separate from the
             PowerShell module), per the 2026-06-19 vendoring decision.

        Each candidate must be a directory containing at least one
        '*.mptf.hcl' file. Throws AvmConfigurationException when none
        resolve, so the transform engine surfaces as 'skipped' (a deliberate
        placeholder) rather than running mapotf against an empty config set.

    .OUTPUTS
        [string] absolute path to the resolved config directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:AVM_MPTF_CONFIG_DIR) {
        $candidates.Add($env:AVM_MPTF_CONFIG_DIR)
    }

    $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $candidates.Add((Join-Path $moduleRoot (Join-Path 'Resources' (Join-Path 'mapotf' 'pre-commit'))))

    $repoRoot = Split-Path -Parent (Split-Path -Parent $moduleRoot)
    $candidates.Add((Join-Path $repoRoot (Join-Path 'config' (Join-Path 'mapotf' 'pre-commit'))))

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        $configs = @(Get-ChildItem -LiteralPath $candidate -Filter '*.mptf.hcl' -File -ErrorAction SilentlyContinue)
        if ($configs.Count -gt 0) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    throw [AvmConfigurationException]::new(
        ("Cannot resolve the mapotf pre-commit config bundle (looked in: {0}). " -f ($candidates -join '; ')) +
        'Set the AVM_MPTF_CONFIG_DIR environment variable or restore config/mapotf/pre-commit/*.mptf.hcl.')
}

function Get-AvmTerraformFile {
    <#
    .SYNOPSIS
        Enumerate the '*.tf' files mapotf would touch under a module root.

    .DESCRIPTION
        Returns FileInfo records for every '*.tf' file beneath $Root,
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

    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.tf' -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = [System.IO.Path]::GetRelativePath($Root, $_.FullName)
                $parts = $rel -split '[\\/]'
                -not ($parts | Where-Object { $_.StartsWith('.') -or $_ -eq 'node_modules' })
            }
    )
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

            mapotf transform --mptf-dir <configs> --tf-dir <root>
            mapotf clean-backup --tf-dir <root>

        The first call mutates '*.tf' in place (telemetry wiring, azapi
        headers, provider pins, block/attribute ordering, variables/outputs
        partitioning) and leaves '*.tf.mptfbackup' files; the second removes
        those backups. This mirrors the upstream avm-terraform-governance
        pre-commit flow.

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
        'Changed' field (relative paths of every '*.tf' mapotf added, removed
        or modified).

        Drift mode (-CheckDrift, used by pr-check): the transform still runs,
        but any 'Changed' file becomes a Status='fail' Issue. The contract is
        "a module that already ran pre-commit has nothing for mapotf to
        change"; a non-empty change set in CI therefore means the author did
        not run pre-commit, and pr-check flags it.

        mapotf exit codes: 0 = success; anything else is surfaced as
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

        [switch] $CheckDrift
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformTransform requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'mapotf' -AllowPathFallback:$AllowPathFallback
    $configDir = Resolve-AvmMapotfConfigDir

    $beforeFiles = Get-AvmTerraformFile -Root $Context.Root

    if (-not $PSCmdlet.ShouldProcess($Context.Root, ("mapotf transform --mptf-dir '{0}'" -f $configDir))) {
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

    # mapotf reads provider schemas (order_resource_attrs et al.) by shelling
    # out to terraform, which it finds by name on PATH. GitHub-hosted runners
    # no longer ship terraform on PATH, so resolve the pinned terraform the
    # same way as mapotf (managed cache, not a stray PATH binary) and prepend
    # its directory to PATH for the mapotf subprocess. The override propagates
    # to mapotf's terraform grandchild. A missing terraform throws
    # AvmToolException, which the chain surfaces as 'skipped' just like a
    # missing mapotf binary.
    $terraform = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback
    $mapotfEnv = $null
    $terraformDir = Split-Path -Parent $terraform.Path
    if ($terraformDir) {
        $mapotfEnv = @{
            PATH = ($terraformDir + [System.IO.Path]::PathSeparator + $env:PATH)
        }
    }

    $transform = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('transform', '--mptf-dir', $configDir, '--tf-dir', $Context.Root) `
        -WorkingDirectory $Context.Root `
        -EnvVars $mapotfEnv `
        -IgnoreExitCode
    if ($transform.ExitCode -ne 0) {
        $stderr = if ($transform.StdErr) { $transform.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ('mapotf transform exited with code {0}{1}' -f $transform.ExitCode, $tail))
    }

    $clean = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('clean-backup', '--tf-dir', $Context.Root) `
        -WorkingDirectory $Context.Root `
        -EnvVars $mapotfEnv `
        -IgnoreExitCode
    if ($clean.ExitCode -ne 0) {
        $stderr = if ($clean.StdErr) { $clean.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ('mapotf clean-backup exited with code {0}{1}' -f $clean.ExitCode, $tail))
    }

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

    $status = 'pass'
    $issues = New-Object System.Collections.Generic.List[object]
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
