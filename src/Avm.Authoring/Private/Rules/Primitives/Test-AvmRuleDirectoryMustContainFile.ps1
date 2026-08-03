function Test-AvmRuleDirectoryMustContainFile {
    <#
    .SYNOPSIS
        Primitive: assert that a directory contains a matching file.

    .DESCRIPTION
        Checks direct files in Parameters.Path against Parameters.Pattern.
        This primitive is report-only; -Fix never creates placeholder content.
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

    $path = [string]$Rule.Parameters.Path
    $pattern = [string]$Rule.Parameters.Pattern
    $full = Join-Path $TargetRoot $path

    $matchingFiles = @()
    if (Test-Path -LiteralPath $full -PathType Container) {
        $matchingFiles = @(Get-ChildItem -LiteralPath $full -File -Filter $pattern -ErrorAction Stop)
    }

    if ($matchingFiles.Count -gt 0) {
        return [pscustomobject][ordered]@{
            Status       = 'pass'
            Issues       = @()
            FilesChanged = 0
        }
    }

    $issues = @(
        [pscustomobject][ordered]@{
            File     = $path
            Line     = 0
            Column   = 0
            Severity = $Rule.Severity
            Code     = $Rule.Id
            Message  = "Required directory '$path' must contain at least one file matching '$pattern'."
        }
    )

    return [pscustomobject][ordered]@{
        Status       = 'fail'
        Issues       = $issues
        FilesChanged = 0
    }
}
