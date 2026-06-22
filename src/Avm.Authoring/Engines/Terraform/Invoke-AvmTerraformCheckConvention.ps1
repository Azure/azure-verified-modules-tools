function Invoke-AvmTerraformCheckConvention {
    <#
    .SYNOPSIS
        Run convention checks against a Terraform module.

    .DESCRIPTION
        Engine implementation called by Invoke-AvmCheckConvention when
        the module context is Ecosystem='terraform'. Loads the AvmRule
        set via Read-AvmRuleSet (built-in rules under
        <ModuleRoot>/Resources/Rules/*.psd1 merged with per-repo
        overrides at <Context.Root>/.avm/rules/*.psd1) and dispatches
        each rule to the matching primitive based on its Kind.

        Per-rule, AppliesTo expands to the set of on-disk target roots:

          - 'root'     : just $Context.Root
          - 'examples' : every immediate subdirectory of
                         <Context.Root>/examples (NOT the root itself).
          - 'modules'  : every immediate subdirectory of
                         <Context.Root>/modules (NOT the root itself).
          - 'all'      : root + examples + modules.

        Per-primitive Issues are re-based from "relative to target root"
        to "relative to Context.Root" (with forward-slash separators) so
        downstream callers can address files unambiguously.

        Status='fail' iff at least one Issue has Severity='error'. The
        per-rule Severity controls whether a violation surfaces as an
        error or a warning; warnings never promote to Status='fail'.

        With -Fix, primitives that declare a fix path apply it; the
        engine simply forwards the switch. Fix-only outcomes contribute
        no Issues and so leave Status='pass'.

    .PARAMETER Context
        Module context produced by Get-AvmModuleContext. Must have
        Ecosystem='terraform'.

    .PARAMETER AllowPathFallback
        Accepted for dispatcher signature compatibility; this engine
        does not invoke any external tool so the flag is ignored.

    .PARAMETER Fix
        When set, primitives that declare a fix path apply it.

    .OUTPUTS
        pscustomobject with Engine='terraform', Tool='avm-rules/1',
        ToolPath=$null, ToolSource='builtin', Status, Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [switch] $Fix
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformCheckConvention requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $null = $AllowPathFallback

    $rules = @(Read-AvmRuleSet -Path $Context.Root)

    $issues = New-Object 'System.Collections.Generic.List[object]'

    foreach ($rule in $rules) {
        $targets = Get-AvmRuleTargetRoot -Rule $rule -ContextRoot $Context.Root
        foreach ($target in $targets) {
            $result = Invoke-AvmRulePrimitive -Rule $rule -TargetRoot $target -Fix:$Fix
            if (-not $result.Issues -or $result.Issues.Count -eq 0) { continue }

            $relTarget = [System.IO.Path]::GetRelativePath($Context.Root, $target).Replace('\', '/')
            foreach ($issue in $result.Issues) {
                $rebasedFile = if ([string]::IsNullOrEmpty($relTarget) -or $relTarget -eq '.') {
                    $issue.File
                }
                else {
                    "$relTarget/$($issue.File)"
                }
                $issues.Add([pscustomobject][ordered]@{
                        File     = $rebasedFile
                        Line     = $issue.Line
                        Column   = $issue.Column
                        Severity = $issue.Severity
                        Code     = $issue.Code
                        Message  = $issue.Message
                    })
            }
        }
    }

    $status = if ($issues | Where-Object { $_.Severity -eq 'error' }) { 'fail' } else { 'pass' }

    return [pscustomobject][ordered]@{
        Engine     = 'terraform'
        Tool       = 'avm-rules/1'
        ToolPath   = $null
        ToolSource = 'builtin'
        Status     = $status
        Issues     = $issues.ToArray()
    }
}

function Get-AvmRuleTargetRoot {
    <#
    .SYNOPSIS
        Internal: expand a rule's AppliesTo into absolute on-disk target roots.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] [string] $ContextRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $applies = [string]$Rule.AppliesTo
    $targets = New-Object 'System.Collections.Generic.List[string]'

    if ($applies -eq 'root' -or $applies -eq 'all') {
        $targets.Add($ContextRoot)
    }

    if ($applies -eq 'examples' -or $applies -eq 'all') {
        $examplesDir = Join-Path $ContextRoot 'examples'
        if (Test-Path -LiteralPath $examplesDir -PathType Container) {
            foreach ($d in Get-ChildItem -LiteralPath $examplesDir -Directory -ErrorAction SilentlyContinue) {
                $targets.Add($d.FullName)
            }
        }
    }

    if ($applies -eq 'modules' -or $applies -eq 'all') {
        $modulesDir = Join-Path $ContextRoot 'modules'
        if (Test-Path -LiteralPath $modulesDir -PathType Container) {
            foreach ($d in Get-ChildItem -LiteralPath $modulesDir -Directory -ErrorAction SilentlyContinue) {
                $targets.Add($d.FullName)
            }
        }
    }

    return $targets.ToArray()
}

function Invoke-AvmRulePrimitive {
    <#
    .SYNOPSIS
        Internal: dispatch a single rule to its primitive based on Kind.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] [string] $TargetRoot,
        [switch] $Fix
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    switch ($Rule.Kind) {
        'FileMustNotExist' {
            Test-AvmRuleFileMustNotExist -Rule $Rule -TargetRoot $TargetRoot -Fix:$Fix
        }
        'FileMustExist' {
            Test-AvmRuleFileMustExist -Rule $Rule -TargetRoot $TargetRoot -Fix:$Fix
        }
        'DirectoryMustExist' {
            Test-AvmRuleDirectoryMustExist -Rule $Rule -TargetRoot $TargetRoot -Fix:$Fix
        }
        'GitignoreMustContain' {
            Test-AvmRuleGitignoreMustContain -Rule $Rule -TargetRoot $TargetRoot -Fix:$Fix
        }
        default {
            throw [AvmConfigurationException]::new(
                "avm-rule '$($Rule.Id)': no primitive for Kind '$($Rule.Kind)'.")
        }
    }
}
