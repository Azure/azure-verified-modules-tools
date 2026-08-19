function Resolve-AvmTyposConfigPath {
    <#
    .SYNOPSIS
        Resolve the vendored AVM typos allowlist.

    .DESCRIPTION
        Returns the absolute path to 'avm.typos.toml', the shared AVM word list.
        Resolution order:

          1. $env:AVM_TYPOS_CONFIG - explicit override (test injection and power
             users pointing at a locally-checked-out governance copy).
          2. <ModuleRoot>/Resources/typos/avm.typos.toml - vendored in the module.

        This file is passed to typos via '--config'. typos MERGES it with any
        '.typos.toml' discovered in the scanned tree rather than replacing it, so
        a module keeps the shared vocabulary while still being able to record its
        own local terms. Only '--isolated' would suppress the repo file, and the
        engine deliberately does not pass it.

        Throws AvmConfigurationException when the file cannot be found, so a
        broken package surfaces as a clear integrity error rather than silently
        scanning with no allowlist - which would flag 'caf' and 'aks' thousands
        of times across the AVM estate.

    .OUTPUTS
        [string] absolute path to the resolved allowlist.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:AVM_TYPOS_CONFIG) {
        $candidates.Add($env:AVM_TYPOS_CONFIG)
    }
    $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $candidates.Add((Join-Path $moduleRoot (Join-Path 'Resources' (Join-Path 'typos' 'avm.typos.toml'))))

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    throw [AvmConfigurationException]::new(
        ("Cannot resolve the AVM typos allowlist (looked in: {0}). " -f ($candidates -join '; ')) +
        'Set the AVM_TYPOS_CONFIG environment variable or reinstall Avm.Authoring so Resources/typos is present.')
}

function Test-AvmGeneratedReadme {
    <#
    .SYNOPSIS
        Report whether a file is a terraform-docs generated README.

    .DESCRIPTION
        AVM READMEs are build output: terraform-docs renders them from the
        'description' fields in variables/outputs plus '_header.md' and
        '_footer.md', wrapping the result in BEGIN_TF_DOCS / END_TF_DOCS markers.
        Reporting a typo at its README coordinates points a contributor at the
        artifact, and any fix made there is erased by the next docs run.

        The marker is the test rather than the filename, so a hand-written README
        that terraform-docs does not own is still scanned.

        Co-located private helper for Invoke-AvmTerraformCheckSpelling.

    .PARAMETER Path
        Absolute path to the candidate file.

    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $Path) { return $false }
    if ([System.IO.Path]::GetFileName($Path) -ne 'README.md') { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    $head = Get-Content -LiteralPath $Path -TotalCount 40 -ErrorAction SilentlyContinue
    return [bool]($head -and ($head -match 'BEGIN_TF_DOCS'))
}

function ConvertFrom-AvmTyposOutput {
    <#
    .SYNOPSIS
        Parse the newline-delimited JSON emitted by 'typos --format json'.

    .DESCRIPTION
        typos writes one JSON object per line rather than a single document, so
        the payload is parsed line by line. Only records with type='typo' are
        returned; typos also emits diagnostic types (e.g. parse errors for
        unreadable files) that are not spelling findings.

        'byte_offset' is a 0-based offset within the line, so Column is
        byte_offset + 1 to match the 1-based convention used by the lint engine.

        Co-located private helper for Invoke-AvmTerraformCheckSpelling.

    .PARAMETER Payload
        Raw stdout from typos.

    .OUTPUTS
        [object[]] of raw typo records.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Payload
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $records = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Payload)) {
        return $records.ToArray()
    }

    foreach ($line in ($Payload -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $parsed = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw [AvmProcessException]::new(
                ("Could not parse typos --format json output: {0}" -f $_.Exception.Message))
        }
        if (-not ($parsed -and ($parsed.PSObject.Properties.Name -contains 'type'))) { continue }
        if ([string]$parsed.type -ne 'typo') { continue }
        $records.Add($parsed)
    }

    return $records.ToArray()
}

function Invoke-AvmTerraformCheckSpelling {
    <#
    .SYNOPSIS
        Spell-check Terraform sources with typos, reporting only - never editing.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmCheckSpelling when the module
        context is Ecosystem='terraform'. Resolves the pinned 'typos' binary via
        Resolve-AvmTool and the shared AVM word list via
        Resolve-AvmTyposConfigPath, then runs one scan over the module root:

            typos --config <allowlist> --format json <module root>

        typos matches against a corpus of known misspellings rather than doing
        dictionary lookup, so unknown identifiers ('azurerm', 'mptf', 'tfvars')
        are never flagged. What it does flag are short Azure acronyms that
        collide with real English typos - 'aks' scans as 'ask', 'caf' as 'calf' -
        which is what the vendored allowlist exists to silence.

        Two properties are deliberate and load-bearing:

        REPORT-ONLY. The engine never passes '--write-changes'. typos rewrites
        word-parts inside identifiers with no idea whether it is editing prose or
        a published interface, and it does so inconsistently across file types -
        renaming 'module "criterias_alert"' while leaving its own 'source' line
        untouched. For a published AVM module that is a silent breaking change,
        so fixes stay a human decision.

        GENERATED READMEs ARE SKIPPED. terraform-docs renders README.md from the
        'description' fields this scan already covers, so reporting there would
        double every finding and point contributors at a file whose edits the
        next docs run erases. Hand-written READMEs (no BEGIN_TF_DOCS marker) are
        still scanned.

        Severity ramps rather than landing red. At the default 'warning' the
        findings are reported and Status stays 'pass', which surfaces the
        existing backlog without blocking. Callers move to 'error' once the
        repository is clean.

        typos exit codes:
          0     - no findings
          2     - findings (parsed; drives Status via -Severity)
          other - typos itself failed (throws AvmProcessException)

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER Severity
        'warning' (default) reports findings and returns Status='pass'.
        'error' returns Status='fail' when any finding remains.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [ValidateSet('warning', 'error')]
        [string] $Severity = 'warning'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformCheckSpelling requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    try {
        $tool = Resolve-AvmTool -Name 'typos' -AllowPathFallback:$AllowPathFallback
    }
    catch [AvmToolException] {
        # AVM1012 means upstream ships no binary for this platform (typos has no
        # windows-arm64 asset). Spelling is advisory, so surface it as
        # not-supported: the gauntlet then records a visible 'skipped' step with
        # this reason instead of erroring the whole chain out from under a
        # contributor who simply cannot obtain the tool. CI runs on a supported
        # platform, so coverage is not lost.
        if ($_.Exception.Code -eq 'AVM1012') {
            throw [AvmNotSupportedException]::new($_.Exception.Message)
        }
        throw
    }
    $configPath = Resolve-AvmTyposConfigPath
    $root = (Resolve-Path -LiteralPath $Context.Root).ProviderPath

    Write-AvmLog ("check spelling: allowlist = {0}" -f $configPath) -Level Verbose | Out-Null

    $run = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('--config', $configPath, '--format', 'json', $root) `
        -WorkingDirectory $root `
        -IgnoreExitCode `
        -StreamOutput:(Test-AvmVerboseEnabled) `
        -Label 'check spelling: typos'

    if ($run.ExitCode -ne 0 -and $run.ExitCode -ne 2) {
        $stderr = if ($run.StdErr) { $run.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ("typos exited with code {0}{1}" -f $run.ExitCode, $tail))
    }

    $records = @(ConvertFrom-AvmTyposOutput -Payload ([string]$run.StdOut))

    $issues = New-Object System.Collections.Generic.List[object]
    $generatedCache = @{}
    $skippedGenerated = 0
    $files = New-Object System.Collections.Generic.HashSet[string]

    foreach ($record in $records) {
        # typos emits the path it was given: absolute when the scan root is
        # absolute, but relative ('./README.md') otherwise. Anchor it to the
        # module root so the generated-README probe and the relative path below
        # never depend on the caller's working directory.
        $absolute = [string]$record.path
        if ($absolute -and -not [System.IO.Path]::IsPathRooted($absolute)) {
            $absolute = [System.IO.Path]::GetFullPath((Join-Path $root $absolute))
        }
        if (-not $generatedCache.ContainsKey($absolute)) {
            $generatedCache[$absolute] = Test-AvmGeneratedReadme -Path $absolute
        }
        if ($generatedCache[$absolute]) {
            $skippedGenerated++
            continue
        }

        $relative = $absolute
        try {
            $relative = [System.IO.Path]::GetRelativePath($root, $absolute)
        }
        catch {
            # A path outside the module root keeps its absolute form.
            $relative = $absolute
        }
        $relative = $relative -replace '\\', '/'
        $null = $files.Add($relative)

        $word = [string]$record.typo
        $suggestions = @($record.corrections | ForEach-Object { [string]$_ })
        $column = if ($record.PSObject.Properties.Name -contains 'byte_offset') {
            [int]$record.byte_offset + 1
        }
        else {
            0
        }

        $issues.Add([pscustomobject][ordered]@{
                File        = $relative
                Line        = [int]$record.line_num
                Column      = $column
                Severity    = $Severity
                Code        = 'AVM-SPELL'
                Word        = $word
                Suggestions = $suggestions
                Message     = ("'{0}' should be '{1}'" -f $word, ($suggestions -join "' or '"))
            })
    }

    if ($skippedGenerated -gt 0) {
        Write-AvmLog ("check spelling: skipped {0} finding(s) in terraform-docs generated README files; fix the source description instead" -f $skippedGenerated) -Level Verbose | Out-Null
    }

    $status = if ($Severity -eq 'error' -and $issues.Count -gt 0) { 'fail' } else { 'pass' }
    Write-AvmLog ("check spelling: terraform completed with {0} finding(s) across {1} file(s)" -f $issues.Count, $files.Count) -Level Verbose | Out-Null

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = $status
        FilesProcessed = $files.Count
        Issues         = $issues.ToArray()
    }
}
