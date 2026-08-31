function Test-AvmRuleTerraformScopesMustBeDirectChildren {
    <#
    .SYNOPSIS
        Primitive: assert that Terraform scopes sit exactly one level below
        each declared scope directory.

    .DESCRIPTION
        Walks every directory below the scope directories named in
        Rule.Parameters.ScopeDirectories (typically 'modules' and 'examples')
        and reports any '*.tf' file found more than one level down.

        Build artifacts are skipped via Get-AvmDescendantDirectory, which prunes
        any subtree Test-AvmIgnoredPath rejects: 'terraform init' populates
        '.terraform/modules/' with copies of external modules, which are
        gitignored, not authored, and cannot be fixed by moving them.

    .PARAMETER Rule
        AvmRule pscustomobject (typically produced by New-AvmRule).

    .PARAMETER TargetRoot
        Absolute path to the module root the rule applies to.

    .PARAMETER Fix
        Accepted for primitive signature compatibility; this rule declares no
        fix, because relocating a scope is an authoring decision.

    .OUTPUTS
        [pscustomobject] with Status, Issues, FilesChanged.
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

    $null = $Fix
    $issues = New-Object 'System.Collections.Generic.List[object]'
    foreach ($scopeDirectory in @($Rule.Parameters.ScopeDirectories | ForEach-Object { [string]$_ })) {
        $scopeRoot = Join-Path $TargetRoot $scopeDirectory
        if (-not (Test-Path -LiteralPath $scopeRoot -PathType Container)) {
            continue
        }

        foreach ($directory in (Get-AvmDescendantDirectory -Root $scopeRoot)) {
            $relativeDirectory = [System.IO.Path]::GetRelativePath($scopeRoot, $directory.FullName)
            if (@($relativeDirectory -split '[\\/]').Count -lt 2) {
                continue
            }

            $terraformFile = Get-ChildItem `
                -LiteralPath $directory.FullName `
                -File `
                -Filter '*.tf' `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $terraformFile) {
                continue
            }

            $relativeFile = [System.IO.Path]::GetRelativePath($TargetRoot, $terraformFile.FullName).Replace('\', '/')
            $issues.Add([pscustomobject][ordered]@{
                    File     = $relativeFile
                    Line     = 0
                    Column   = 0
                    Severity = $Rule.Severity
                    Code     = $Rule.Id
                    Message  = (
                        "Terraform scope '$relativeFile' is nested below '$scopeDirectory/'. " +
                        'AVM permits only one direct child layer.')
                })
        }
    }

    return [pscustomobject][ordered]@{
        Status       = if ($issues.Count -gt 0) { 'fail' } else { 'pass' }
        Issues       = $issues.ToArray()
        FilesChanged = 0
    }
}
