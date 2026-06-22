function Invoke-AvmTerraformDocs {
    <#
    .SYNOPSIS
        Generate or inject README documentation via terraform-docs.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmDocs when the module
        context is Ecosystem='terraform'. Resolves the 'terraform-docs'
        binary via Resolve-AvmTool, then runs
            terraform-docs markdown table --output-file README.md --output-mode inject .
        against $Context.Root. The module's README.md must contain the
        marker block (BEGIN_TF_DOCS / END_TF_DOCS) for inject mode to
        work; otherwise terraform-docs falls back to appending and the
        return envelope flags the README path under 'Changed'.

        terraform-docs exit codes:
          0 - success
          others - tool error, surfaced as AvmProcessException.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Pass through to Resolve-AvmTool.

    .PARAMETER OutputFile
        README path (relative to module root) to inject into. Defaults
        to 'README.md'.

    .OUTPUTS
        pscustomobject with Engine, Tool, ToolPath, ToolSource, Status,
        FilesProcessed, Changed.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm CLI verb (avm docs).')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [string] $OutputFile = 'README.md'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformDocs requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $tool = Resolve-AvmTool -Name 'terraform-docs' -AllowPathFallback:$AllowPathFallback

    $readmePath = Join-Path $Context.Root $OutputFile
    $beforeHash = if (Test-Path -LiteralPath $readmePath) {
        (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash
    }
    else {
        ''
    }

    $result = Invoke-AvmProcess `
        -FilePath $tool.Path `
        -ArgumentList @('markdown', 'table', '--output-file', $OutputFile, '--output-mode', 'inject', '.') `
        -WorkingDirectory $Context.Root `
        -IgnoreExitCode

    if ($result.ExitCode -ne 0) {
        $stderr = if ($result.StdErr) { $result.StdErr.Trim() } else { '' }
        $tail = if ($stderr) { ": $stderr" } else { '.' }
        throw [AvmProcessException]::new(
            ('terraform-docs exited with code {0}{1}' -f $result.ExitCode, $tail))
    }

    $afterHash = if (Test-Path -LiteralPath $readmePath) {
        (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash
    }
    else {
        ''
    }

    $changed = if ($beforeHash -ne $afterHash) { , $OutputFile } else { @() }

    return [pscustomobject][ordered]@{
        Engine         = 'terraform'
        Tool           = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath       = $tool.Path
        ToolSource     = $tool.Source
        Status         = 'pass'
        FilesProcessed = 1
        Changed        = $changed
    }
}
