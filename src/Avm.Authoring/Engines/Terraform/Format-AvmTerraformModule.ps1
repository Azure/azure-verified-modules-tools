function Format-AvmTerraformModule {
    <#
    .SYNOPSIS
        Run 'terraform fmt -recursive' against the resolved module root.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmFormat when the module
        context is Ecosystem='terraform'. Invokes 'terraform fmt -recursive
        -list -diff -write=true' against $Context.Root. The 'terraform fmt'
        command exits 0 when all files are already formatted, 0 when files
        were rewritten, and non-zero on parser errors; -list prints the
        names of changed files on stdout, which is parsed into Changed.

        The terraform binary is resolved via Resolve-AvmTool against the
        bundled tools.lock. -AllowPathFallback is passed through so callers
        can opt in to the host PATH when the managed cache is empty.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource,
        FilesProcessed (-1 when terraform doesn't report it), Changed.
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

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Format-AvmTerraformModule requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback

    $result = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('fmt', '-recursive', '-list=true', '-write=true', $Context.Root)

    # terraform fmt -list emits one filename per line for changed files.
    $changed = @($result.StdOut -split "`r?`n" | Where-Object { $_ -and $_.Trim() })

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        FilesProcessed = -1
        Changed        = $changed
    }
}
