function Read-AvmRuleSet {
    <#
    .SYNOPSIS
        Load every AvmRule that applies to a given on-disk target root.

    .DESCRIPTION
        Walks (in this order) and merges by rule Id (later entries override
        earlier ones with the same Id):

          1. Built-in rules at <ModuleRoot>/Resources/Rules/*.psd1
             (sorted by filename, ordinal). These ship with the module.
          2. Per-repo rules at <Path>/.avm/rules/*.psd1
             (sorted by filename, ordinal). These let a repo override a
             built-in rule by re-declaring its Id, or introduce custom
             rules entirely. Highest precedence.

        Each .psd1 file is loaded with Import-PowerShellDataFile (safer
        than dot-sourcing arbitrary code) and must return a single
        hashtable matching the AvmRule schema (see Test-AvmRule). The
        loader hands each definition to New-AvmRule for normalisation +
        validation; on schema violation it rethrows as
        AvmConfigurationException with the offending file path prefixed.

        The Source property of every returned rule is the full path to the
        .psd1 file it came from so downstream diagnostics (and engine
        envelopes) can cite the source.

        Pinned-asset rule bundles ('assets.avm-rules-*' via
        Resolve-AvmPinnedAsset) are NOT loaded by this function in
        Slice C -- that integration is tracked as a future slice.

    .PARAMETER Path
        A directory (typically the module root) used to locate the per-repo
        rules dir at <Path>/.avm/rules/. Required.

    .OUTPUTS
        An object array of validated AvmRule pscustomobjects, sorted by
        Id (ordinal) so callers can rely on a stable processing order.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $rulesById = [ordered]@{}

    $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $builtinDir = Join-Path (Join-Path $moduleRoot 'Resources') 'Rules'
    if (Test-Path -LiteralPath $builtinDir -PathType Container) {
        foreach ($file in Get-AvmRuleFilesOrdinal -Directory $builtinDir) {
            $rule = Read-AvmRuleFile -ConfigPath $file.FullName
            $rulesById[$rule.Id] = $rule
        }
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $dir = $resolved.ProviderPath
    if ((Get-Item -LiteralPath $dir).PSIsContainer -eq $false) {
        $dir = Split-Path -Parent $dir
    }
    $repoDir = Join-Path (Join-Path $dir '.avm') 'rules'
    if (Test-Path -LiteralPath $repoDir -PathType Container) {
        foreach ($file in Get-AvmRuleFilesOrdinal -Directory $repoDir) {
            $rule = Read-AvmRuleFile -ConfigPath $file.FullName
            $rulesById[$rule.Id] = $rule
        }
    }

    if ($rulesById.Count -eq 0) {
        return @()
    }

    $ids = @($rulesById.Keys)
    [System.Array]::Sort($ids, [System.StringComparer]::Ordinal)
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in $ids) {
        $result.Add($rulesById[$id])
    }
    return $result.ToArray()
}

function Read-AvmRuleFile {
    <#
    .SYNOPSIS
        Internal: parse and validate one rule .psd1 file.

    .DESCRIPTION
        Uses Import-PowerShellDataFile so arbitrary script in the .psd1
        cannot execute. The file must declare a single top-level hashtable
        carrying the AvmRule fields. Schema violations bubble up as
        AvmConfigurationException with the file path prefixed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ConfigPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    try {
        $loaded = Import-PowerShellDataFile -LiteralPath $ConfigPath -ErrorAction Stop
    }
    catch {
        throw [AvmConfigurationException]::new(
            "${ConfigPath}: unable to load rule definition: $($_.Exception.Message)",
            $_.Exception)
    }

    if ($loaded -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new(
            "${ConfigPath}: rule .psd1 must declare a single top-level hashtable.")
    }

    try {
        return New-AvmRule -Definition ([hashtable]$loaded) -Source $ConfigPath
    }
    catch [System.Data.DataException] {
        throw [AvmConfigurationException]::new(
            "${ConfigPath}: $($_.Exception.Message)",
            $_.Exception)
    }
}

function Get-AvmRuleFilesOrdinal {
    <#
    .SYNOPSIS
        Internal: list rule .psd1 files in a directory in ordinal-stable order.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Directory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $files = Get-ChildItem -LiteralPath $Directory -File -Filter '*.psd1' -ErrorAction SilentlyContinue
    if (-not $files) { return @() }
    $arr = @($files | ForEach-Object { $_.FullName })
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return @($arr | ForEach-Object { Get-Item -LiteralPath $_ })
}
