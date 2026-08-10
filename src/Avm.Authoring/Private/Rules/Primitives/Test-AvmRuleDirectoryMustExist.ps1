function Test-AvmRuleDirectoryMustExist {
    <#
    .SYNOPSIS
        Primitive: assert that a named directory exists in the target root.

    .DESCRIPTION
        Used by AVM convention rules that require a specific directory
        (e.g. 'examples' and 'tests').

        Parameters honoured on the rule:
          - Path (required, string) : path relative to TargetRoot.
          - MinimumChildDirectories (optional, positive integer) : minimum
            number of immediate child directories.
          - FixCreateFile (optional, string) : leaf placeholder file to create
            inside a missing directory.

    .PARAMETER Rule
        AvmRule pscustomobject (typically produced by New-AvmRule).

    .PARAMETER TargetRoot
        Absolute path to the directory the rule applies to.

    .PARAMETER Fix
        When set and FixCreateFile is declared, creates the missing directory
        and placeholder file.

    .OUTPUTS
        [pscustomobject] with Status, Issues, FilesChanged.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] [string] $TargetRoot,
        [switch] $Fix
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $path = [string]$Rule.Parameters.Path
    $full = Join-Path $TargetRoot $path

    if (Test-Path -LiteralPath $full -PathType Container) {
        if ($Rule.Parameters.ContainsKey('MinimumChildDirectories')) {
            $minimum = [int]$Rule.Parameters.MinimumChildDirectories
            $actual = @(Get-ChildItem -LiteralPath $full -Directory).Count
            if ($actual -lt $minimum) {
                $noun = if ($minimum -eq 1) { 'directory' } else { 'directories' }
                return [pscustomobject][ordered]@{
                    Status       = 'fail'
                    Issues       = @(
                        [pscustomobject][ordered]@{
                            File     = $path
                            Line     = 0
                            Column   = 0
                            Severity = $Rule.Severity
                            Code     = $Rule.Id
                            Message  = "Required directory '$path' must contain at least $minimum immediate child $noun; found $actual."
                        }
                    )
                    FilesChanged = 0
                }
            }
        }

        return [pscustomobject][ordered]@{
            Status       = 'pass'
            Issues       = @()
            FilesChanged = 0
        }
    }

    $fixCreateFile = if ($Rule.Parameters.ContainsKey('FixCreateFile')) {
        [string]$Rule.Parameters.FixCreateFile
    }
    else {
        $null
    }

    if ($Fix -and $fixCreateFile -and -not (Test-Path -LiteralPath $full)) {
        $placeholder = Join-Path $full $fixCreateFile
        if ($PSCmdlet.ShouldProcess($full, "Create directory with '$fixCreateFile'")) {
            $null = [System.IO.Directory]::CreateDirectory($full)
            [System.IO.File]::WriteAllText(
                $placeholder,
                '',
                [System.Text.UTF8Encoding]::new($false))
        }

        return [pscustomobject][ordered]@{
            Status       = 'fixed'
            Issues       = @()
            FilesChanged = 1
        }
    }

    $message = if ($fixCreateFile) {
        "Required directory '$path' does not exist (run with -Fix to create it)."
    }
    else {
        "Required directory '$path' does not exist."
    }
    $issues = @(
        [pscustomobject][ordered]@{
            File     = $path
            Line     = 0
            Column   = 0
            Severity = $Rule.Severity
            Code     = $Rule.Id
            Message  = $message
        }
    )

    return [pscustomobject][ordered]@{
        Status       = 'fail'
        Issues       = $issues
        FilesChanged = 0
    }
}
