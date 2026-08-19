function Invoke-AvmCheckSpelling {
    <#
    .SYNOPSIS
        Spell-check the prose in the resolved module's sources.

    .DESCRIPTION
        Routes to the engine matching the module's ecosystem:

          - terraform  -> Invoke-AvmTerraformCheckSpelling (typos, report-only)
          - bicep      -> not implemented; throws AvmNotSupportedException

        Typos in 'variable' and 'output' descriptions propagate into the
        generated README.md, because terraform-docs renders that file from those
        description fields. Contributors who notice a typo months later tend to
        patch README.md, which the next docs run reverts. Checking the source
        catches the mistake at the PR that introduces it, and points at the file
        where a fix survives.

        The check never edits. See Invoke-AvmTerraformCheckSpelling for why
        auto-fix is unsafe on a published module interface.

        The ecosystem is determined by Get-AvmModuleContext, which honours the
        .avm/context.psd1 override file and the -Ecosystem filter.

        Routed by the dispatcher: 'avm check spelling'.

    .PARAMETER Path
        Working directory whose enclosing module to check. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER Severity
        'warning' (default) reports findings and returns Status='pass'.
        'error' returns Status='fail' when any finding remains. The gauntlets
        run at 'warning' while the estate is brought clean.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Issues.

    .EXAMPLE
        avm check spelling

    .EXAMPLE
        Invoke-AvmCheckSpelling -Path C:\repos\my-tf-module -Severity error
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [ValidateSet('warning', 'error')]
        [string] $Severity = 'warning',

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck | Out-Null

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem
    Write-AvmLog ("check spelling: module root = {0}; ecosystem = {1}" -f $context.Root, $context.Ecosystem) -Level Verbose | Out-Null

    switch ($context.Ecosystem) {
        'terraform' {
            Invoke-AvmTerraformCheckSpelling `
                -Context $context `
                -AllowPathFallback:$AllowPathFallback `
                -Severity $Severity
        }
        default {
            throw [AvmNotSupportedException]::new(
                "avm check spelling is a terraform-only command; the resolved module ecosystem is '$($context.Ecosystem)'. Bicep spell checking is not implemented.")
        }
    }
}
