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
        tools.lock. -AllowPathFallback is passed through so callers can opt
        in to the host PATH when the managed cache is empty.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='bicep'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool: accept a PATH-resolved bicep if the
        lock-pinned version matches.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource,
        FilesProcessed, Changed (string[]).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback
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
    foreach ($file in $files) {
        $before = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('format', $file.FullName) | Out-Null
        $after = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ($before -ne $after) { $changed.Add($file.FullName) }
    }

    return [pscustomobject][ordered]@{
        Engine         = 'bicep'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        FilesProcessed = $files.Count
        Changed        = $changed.ToArray()
    }
}
