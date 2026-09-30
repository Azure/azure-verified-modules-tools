function Format-AvmBicepModule {
    <#
    .SYNOPSIS
        Run 'bicep format' over every .bicep / .bicepparam source under
        the resolved module root.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmFormat when the module
        context is Ecosystem='bicep'. Discovers all .bicep and .bicepparam
        files under $Context.Root (excluding dot-folders and node_modules),
        invokes 'bicep format <file>' on each, and reports which files were
        actually modified by hashing content before and after.

        The bicep binary is resolved via Resolve-AvmTool against the bundled
        avm.pins. -AllowPathFallback is passed through so callers can opt
        in to the host PATH when the managed cache is empty.

        Drift mode (-CheckDrift, used by pr-check) invokes 'bicep format
        <file> --stdout' and compares its UTF-8 bytes with the source bytes.
        Formatting differences become Status='fail' Issues without writing
        to the working copy. Formatter failures still throw.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool: accept a PATH-resolved bicep if the
        lock-pinned version matches.

    .PARAMETER CheckDrift
        When set, report formatting differences without modifying files
        (Status='fail' with one Issue per file). Used by the pr-check chain.

    .OUTPUTS
        pscustomobject with Status, Engine, Tool, ToolPath,
        ToolSource, FilesProcessed, Changed (string[]), Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [switch] $CheckDrift
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new(
            "Format-AvmBicepModule requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback

    $discovered = Get-ChildItem -Path $Context.Root -Recurse -File -Include '*.bicep', '*.bicepparam' -ErrorAction Stop |
        Where-Object { $_.FullName -notmatch '[\\/]\.[^\\/]+[\\/]' } |
        Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' }
    $files = @($discovered)

    $changed = New-Object System.Collections.Generic.List[string]
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    foreach ($file in $files) {
        if ($CheckDrift) {
            $original = [System.IO.File]::ReadAllBytes($file.FullName)
            $result = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('format', $file.FullName, '--stdout')
            $formatted = $utf8NoBom.GetBytes($result.StdOut)
            if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]]$formatted)) {
                $changed.Add($file.FullName)
            }
            continue
        }

        $before = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('format', $file.FullName) | Out-Null
        $after = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ($before -ne $after) { $changed.Add($file.FullName) }
    }

    $status = 'pass'
    $issues = New-Object System.Collections.Generic.List[object]
    if ($CheckDrift -and $changed.Count -gt 0) {
        $status = 'fail'
        foreach ($item in $changed) {
            $rel = ([System.IO.Path]::GetRelativePath($Context.Root, $item)).Replace('\', '/')
            $issues.Add([pscustomobject][ordered]@{
                    File     = $rel
                    Line     = 0
                    Column   = 0
                    Severity = 'error'
                    Code     = 'avm.bicep.fmt-drift'
                    Message  = ("'{0}' is not formatted; run 'avm format' and commit the result." -f $rel)
                })
        }
    }

    return [pscustomobject][ordered]@{
        Status         = $status
        Engine         = 'bicep'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        FilesProcessed = $files.Count
        Changed        = $changed.ToArray()
        Issues         = $issues.ToArray()
    }
}
