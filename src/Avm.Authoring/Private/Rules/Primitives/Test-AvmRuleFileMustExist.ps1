function Test-AvmRuleFileMustExist {
    <#
    .SYNOPSIS
        Primitive: assert that a named file exists in the target root.

    .DESCRIPTION
        Used by AVM convention rules that require a specific file (e.g.
        'terraform.tf' or '_header.md').

        Parameters honoured on the rule:
          - Path (required, string) : path relative to TargetRoot.
          - FixContentTemplate (optional, string) : content used to create a
            missing file. Supports {DirectoryName} and {DirectoryTitle}.

    .PARAMETER Rule
        AvmRule pscustomobject (typically produced by New-AvmRule).

    .PARAMETER TargetRoot
        Absolute path to the directory the rule applies to.

    .PARAMETER Fix
        When set and FixContentTemplate is declared, creates the missing file.

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

    if (Test-Path -LiteralPath $full -PathType Leaf) {
        return [pscustomobject][ordered]@{
            Status       = 'pass'
            Issues       = @()
            FilesChanged = 0
        }
    }

    $fixContentTemplate = if ($Rule.Parameters.ContainsKey('FixContentTemplate')) {
        [string]$Rule.Parameters.FixContentTemplate
    }
    else {
        $null
    }

    if ($Fix -and $fixContentTemplate -and -not (Test-Path -LiteralPath $full)) {
        $directoryName = [System.IO.DirectoryInfo]::new($TargetRoot).Name
        $textInfo = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
        $directoryTitle = (($directoryName -split '[-_ ]+' | ForEach-Object {
                    $textInfo.ToTitleCase($_.ToLowerInvariant())
                }) -join ' ')
        $content = $fixContentTemplate.
            Replace('{DirectoryName}', $directoryName).
            Replace('{DirectoryTitle}', $directoryTitle).
            Replace("`r`n", "`n").
            Replace("`r", "`n")
        if (-not $content.EndsWith("`n")) {
            $content += "`n"
        }

        if ($PSCmdlet.ShouldProcess($full, 'Create required file')) {
            $parent = Split-Path -Parent $full
            $null = [System.IO.Directory]::CreateDirectory($parent)
            [System.IO.File]::WriteAllText(
                $full,
                $content,
                [System.Text.UTF8Encoding]::new($false))
        }

        return [pscustomobject][ordered]@{
            Status       = 'fixed'
            Issues       = @()
            FilesChanged = 1
        }
    }

    $message = if ($fixContentTemplate) {
        "Required file '$path' does not exist (run with -Fix to create it)."
    }
    else {
        "Required file '$path' does not exist."
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
