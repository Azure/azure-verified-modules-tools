function Get-AvmTerraformDocsConfig {
    <#
    .SYNOPSIS
        Return the terraform-docs config file in a directory, or '' if none.

    .DESCRIPTION
        Looks for the conventional AVM terraform-docs config (`.terraform-docs.yml`
        then `.terraform-docs.yaml`) directly inside the given directory. Returns
        the absolute path to the first match, or an empty string when the directory
        is missing or carries no config. Co-located private helper for
        Invoke-AvmTerraformDocs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Directory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return ''
    }

    foreach ($name in @('.terraform-docs.yml', '.terraform-docs.yaml')) {
        $candidate = Join-Path $Directory $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return ''
}

function Get-AvmTerraformDocsChildModule {
    <#
    .SYNOPSIS
        Return immediate subdirectories that contain at least one .tf file.

    .DESCRIPTION
        Used to enumerate the per-example (`examples/<name>`) and per-submodule
        (`modules/<name>`) directories that terraform-docs should document, the
        same way the upstream pre-commit porch config runs terraform-docs across
        root + each example + each submodule. Subdirectories with no Terraform
        source are skipped (e.g. a bare `examples/` holding only a shared
        `.terraform-docs.yml`). Results are sorted by name for deterministic
        ordering. Co-located private helper for Invoke-AvmTerraformDocs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Parent
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $Parent -Directory -Force |
        Sort-Object -Property Name |
        ForEach-Object {
            $hasTf = @(Get-ChildItem -LiteralPath $_.FullName -Filter '*.tf' -File -Force).Count -gt 0
            if ($hasTf) { $_.FullName }
        }
}

function Invoke-AvmTerraformDocs {
    <#
    .SYNOPSIS
        Generate or inject README documentation via terraform-docs.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmDocs when the module
        context is Ecosystem='terraform'. Resolves the 'terraform-docs'
        binary via Resolve-AvmTool, then runs terraform-docs against the
        module root and - mirroring the upstream pre-commit porch config -
        each `examples/<name>` and `modules/<name>` subdirectory.

        When a directory carries the conventional AVM terraform-docs config
        (`.terraform-docs.yml` / `.terraform-docs.yaml`) the engine honours it:

            terraform-docs --config <config> <module-path>

        The config drives the AVM 'markdown document' formatter, the
        header/footer injection (`_header.md` / `_footer.md`) and the
        `output.file` / `output.mode` (replace) behaviour. terraform-docs
        resolves `output.file`, `header-from`, `footer-from` and any
        `{{ include }}` paths relative to the positional module path, so a
        single shared `examples/.terraform-docs.yml` documents every example
        subdirectory. The examples config lives one level up from each example,
        so it is applied with the example directory as the positional argument.

        When a directory has no config the engine falls back to the previous
        behaviour:

            terraform-docs markdown table --output-file README.md --output-mode inject .

        The module's README.md must contain the marker block
        (BEGIN_TF_DOCS / END_TF_DOCS) for inject/replace mode to work.

        terraform-docs exit codes:
          0 - success
          others - tool error, surfaced as AvmProcessException.

        Drift mode (-CheckDrift, used by pr-check): terraform-docs has no
        dry-run for inject/replace mode, so generation still runs and any
        README it rewrote becomes a Status='fail' Issue. The generated content
        is then rolled back, so drift mode leaves the working copy
        byte-identical. The contract is "a module that already ran pre-commit
        has an up-to-date README"; a non-empty change set in CI therefore means
        the author did not regenerate the docs.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER OutputFile
        README path (relative to each module root) to generate. Defaults
        to 'README.md'.

    .PARAMETER CheckDrift
        When set, treat any README terraform-docs rewrote as a failure
        (Status='fail' with one Issue per file) instead of a silent
        regeneration. Used by the pr-check chain.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Changed, Issues.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm CLI verb (avm docs).')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [string] $OutputFile = 'README.md',

        [switch] $CheckDrift
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformDocs requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'terraform-docs' -AllowPathFallback:$AllowPathFallback
    $root = $Context.Root

    # Build the ordered list of documentation targets: the module root first,
    # then every example and submodule that carries Terraform source. Each
    # target records the directory to hash for drift, the config to honour (or
    # '' for the legacy table fallback) and the positional path passed to
    # terraform-docs (relative to $root so the invocation matches upstream).
    $targets = [System.Collections.Generic.List[pscustomobject]]::new()

    $targets.Add([pscustomobject]@{
            Dir    = $root
            Config = (Get-AvmTerraformDocsConfig -Directory $root)
        })

    foreach ($group in @('examples', 'modules')) {
        $parent = Join-Path $root $group
        $groupConfig = Get-AvmTerraformDocsConfig -Directory $parent
        if (-not $groupConfig) { continue }

        foreach ($childDir in @(Get-AvmTerraformDocsChildModule -Parent $parent)) {
            $targets.Add([pscustomobject]@{
                    Dir    = $childDir
                    Config = $groupConfig
                })
        }
    }
    Write-AvmLog ("docs: discovered {0} documentation target(s)" -f $targets.Count) -Level Verbose | Out-Null

    $changed = [System.Collections.Generic.List[string]]::new()

    # Drift mode must not mutate the caller's working copy, but terraform-docs
    # has no dry-run for inject/replace mode. Snapshot every README up front and
    # restore it in the finally, so generation still runs (and still reports
    # drift) while the tree is left byte-identical even if the tool throws.
    $snapshot = $null
    if ($CheckDrift) {
        Write-AvmLog ("docs: check-drift mode; snapshotting {0} output file(s)" -f $targets.Count) -Level Verbose | Out-Null
        $snapshot = Get-AvmFileSnapshot -Path @($targets | ForEach-Object { Join-Path $_.Dir $OutputFile })
    }

    try {
        foreach ($target in $targets) {
            $readmePath = Join-Path $target.Dir $OutputFile
            $beforeHash = if (Test-Path -LiteralPath $readmePath) {
                (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash
            }
            else {
                ''
            }

            $positional = [System.IO.Path]::GetRelativePath($root, $target.Dir)

            if ($target.Config) {
                $configArg = [System.IO.Path]::GetRelativePath($root, $target.Config)
                $argumentList = @('--config', $configArg, $positional)
                Write-AvmLog ("docs: target {0} uses config {1}" -f $positional, $configArg) -Level Verbose | Out-Null
            }
            else {
                $argumentList = @('markdown', 'table', '--output-file', $OutputFile, '--output-mode', 'inject', $positional)
                Write-AvmLog ("docs: target {0} uses legacy table fallback" -f $positional) -Level Verbose | Out-Null
            }

            $result = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList $argumentList `
                -WorkingDirectory $root `
                -IgnoreExitCode

            if ($result.ExitCode -ne 0) {
                $stderr = if ($result.StdErr) { $result.StdErr.Trim() } else { '' }
                $tail = if ($stderr) { ": $stderr" } else { '.' }
                throw [AvmProcessException]::new(
                    ('terraform-docs exited with code {0} for {1}{2}' -f $result.ExitCode, $positional, $tail))
            }

            $afterHash = if (Test-Path -LiteralPath $readmePath) {
                (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash
            }
            else {
                ''
            }

            if ($beforeHash -ne $afterHash) {
                $relative = [System.IO.Path]::GetRelativePath($root, $readmePath).Replace('\', '/')
                $changed.Add($relative)
                Write-AvmLog ("docs: changed {0}" -f $relative) -Level Verbose | Out-Null
            }
            else {
                Write-AvmLog ("docs: unchanged {0}" -f ([System.IO.Path]::GetRelativePath($root, $readmePath).Replace('\', '/'))) -Level Verbose | Out-Null
            }
        }
    }
    finally {
        if ($null -ne $snapshot) {
            Write-AvmLog 'docs: restoring output snapshot after drift check' -Level Verbose | Out-Null
            Restore-AvmFileSnapshot -Snapshot $snapshot
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
                    Code     = 'avm.tf.docs-drift'
                    Message  = ("'{0}' is out of date; run 'avm docs' and commit the result." -f $rel)
                })
        }
        Write-AvmLog ("docs: completed; targets={0}; changed={1}; status={2}" -f $targets.Count, $changed.Count, $status) -Level Verbose | Out-Null
    }

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = $status
        FilesProcessed = $targets.Count
        Changed        = [string[]]$changed.ToArray()
        Issues         = $issues.ToArray()
    }
}
