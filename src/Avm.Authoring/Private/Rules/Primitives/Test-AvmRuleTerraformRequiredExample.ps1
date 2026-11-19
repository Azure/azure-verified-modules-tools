function Test-AvmRuleTerraformRequiredExample {
    <#
    .SYNOPSIS
        Primitive: check Terraform canonical example coverage by module class.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] [string] $TargetRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $context = [pscustomobject]@{ Root = $TargetRoot; Ecosystem = 'terraform' }
    $moduleClass = Get-AvmTflintRootModuleClass -Context $context
    $examples = @(Get-AvmTerraformE2eExample -Root $TargetRoot)
    $examplesRoot = Join-Path $TargetRoot 'examples'
    $directories = if (Test-Path -LiteralPath $examplesRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $examplesRoot -Directory -ErrorAction SilentlyContinue)
    }
    else {
        @()
    }

    $issues = [System.Collections.Generic.List[object]]::new()
    $canonical = @($examples | Where-Object { $_.Name -ceq 'defaults' -and -not $_.Ignored })
    $legacyDirectory = @($directories | Where-Object Name -CEQ 'default')
    $legacy = @($examples | Where-Object { $_.Name -ceq 'default' -and -not $_.Ignored })

    if ($canonical.Count -eq 0) {
        $detail = if ($legacy.Count -gt 0) {
            "Runnable 'examples/default' exists, but TFNFR42 expects the canonical 'examples/defaults'; this legacy spelling remains runnable."
        }
        else {
            "TFNFR42 expects a runnable 'examples/defaults' directory with Terraform source."
        }
        $issues.Add([pscustomobject][ordered]@{
                File     = 'examples/defaults'
                Line     = 0
                Column   = 0
                Severity = $Rule.Severity
                Code     = "$($Rule.Id).missing-defaults"
                Message  = $detail
            })
    }
    if ($legacyDirectory.Count -gt 0 -and $canonical.Count -gt 0) {
        $issues.Add([pscustomobject][ordered]@{
                File     = 'examples/default'
                Line     = 0
                Column   = 0
                Severity = $Rule.Severity
                Code     = "$($Rule.Id).legacy-default"
                Message  = "Canonical 'examples/defaults' is present; migrate or remove the legacy 'examples/default' spelling."
            })
    }
    foreach ($name in @('default', 'defaults')) {
        $present = @($directories | Where-Object Name -CEQ $name)
        $runnable = @($examples | Where-Object { $_.Name -ceq $name -and -not $_.Ignored })
        if ($present.Count -gt 0 -and $runnable.Count -eq 0 -and
            -not ($name -ceq 'default' -and $canonical.Count -eq 0)) {
            $issues.Add([pscustomobject][ordered]@{
                    File     = "examples/$name"
                    Line     = 0
                    Column   = 0
                    Severity = $Rule.Severity
                    Code     = "$($Rule.Id).non-runnable-$name"
                    Message  = "'examples/$name' must contain Terraform source and must not contain .e2eignore."
                })
        }
    }

    if ($moduleClass -ceq 'resource') {
        $waf = @($examples | Where-Object { $_.Name -ceq 'waf-aligned' -and -not $_.Ignored })
        if ($waf.Count -eq 0) {
            $issues.Add([pscustomobject][ordered]@{
                    File     = 'examples/waf-aligned'
                    Line     = 0
                    Column   = 0
                    Severity = $Rule.Severity
                    Code     = "$($Rule.Id).missing-waf-aligned"
                    Message  = "TFNFR42 expects a runnable 'examples/waf-aligned' directory for resource modules."
                })
        }
    }

    return [pscustomobject][ordered]@{
        Status       = if (@($issues | Where-Object Severity -EQ 'error').Count -gt 0) { 'fail' } else { 'pass' }
        Issues       = $issues.ToArray()
        FilesChanged = 0
    }
}
