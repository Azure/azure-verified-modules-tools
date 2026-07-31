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

        Drift mode (-CheckDrift, used by pr-check): the same command runs
        with -write=false, so nothing is rewritten and -list reports the
        files that *would* change. Any such file becomes a Status='fail'
        Issue. The contract is "a module that already ran pre-commit has
        nothing left for terraform fmt to change"; a non-empty change set
        in CI therefore means the author did not run pre-commit.

        The terraform binary is resolved via Resolve-AvmTool against the
        bundled avm.pins. -AllowPathFallback is passed through so callers
        can opt in to the host PATH when the managed cache is empty.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER CheckDrift
        Report-only mode. Runs with -write=false so no file is rewritten;
        any file that would change makes the result Status='fail' with one
        Issue per file. Used by the pr-check chain.

    .OUTPUTS
        pscustomobject with Status, Engine, Tool, ToolPath, ToolSource,
        FilesProcessed, Changed, Issues.
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

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Format-AvmTerraformModule requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback

    $writeArg = if ($CheckDrift) { '-write=false' } else { '-write=true' }

    $result = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('fmt', '-recursive', '-list=true', $writeArg, $Context.Root)

    # terraform fmt -list emits one filename per line for changed files.
    $changed = @($result.StdOut -split "`r?`n" | Where-Object { $_ -and $_.Trim() })

    # terraform fmt reports only the files it rewrote, not the total it
    # inspected. Count the .tf / .tfvars sources it would have visited so the
    # result contract carries a real FilesProcessed instead of a -1 sentinel.
    $processed = @(
        Get-ChildItem -Path $Context.Root -Recurse -File -Include '*.tf', '*.tfvars' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.[^\\/]+[\\/]' }
    )

    $status = 'pass'
    $issues = New-Object System.Collections.Generic.List[object]
    if ($CheckDrift -and $changed.Count -gt 0) {
        $status = 'fail'
        foreach ($item in $changed) {
            $rel = if ([System.IO.Path]::IsPathRooted($item)) {
                [System.IO.Path]::GetRelativePath($Context.Root, $item)
            }
            else {
                $item
            }
            $rel = $rel.Replace('\', '/')
            $issues.Add([pscustomobject][ordered]@{
                    File     = $rel
                    Line     = 0
                    Column   = 0
                    Severity = 'error'
                    Code     = 'avm.tf.fmt-drift'
                    Message  = ("'{0}' is not formatted; run 'avm format' and commit the result." -f $rel)
                })
        }
    }

    return [pscustomobject][ordered]@{
        Status         = $status
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        FilesProcessed = $processed.Count
        Changed        = $changed
        Issues         = $issues.ToArray()
    }
}
