function Test-AvmReleaseFormatEquivalence {
    <#
    .SYNOPSIS
        Decide whether two versions of a Terraform file differ only in formatting.

    .DESCRIPTION
        Writes each version to its own temporary folder, runs terraform fmt on both, and compares the results. Line endings are ignored. The release-metadata check uses this to tell a formatting-only bot change from a code change.

        Identical content is always equivalent. Otherwise, only *.tf and *.tfvars files can be equivalent, because terraform fmt formats nothing else. A missing version, or a version that terraform fmt can't parse, is never equivalent. The content is parsed, never run.

    .PARAMETER Path
        The repository path of the file. Only its extension and leaf name are used.

    .PARAMETER BaseContent
        The file content before the change. Null means the content is unknown.

    .PARAMETER HeadContent
        The file content after the change. Null means the content is unknown.

    .EXAMPLE
        Test-AvmReleaseFormatEquivalence -Path 'main.tf' -BaseContent "locals {`n  a=1`n}`n" -HeadContent "locals {`n  a = 1`n}`n"

        Returns $true.

    .OUTPUTS
        $true when the versions are identical after formatting. Otherwise $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [AllowNull()]
        [object] $BaseContent,

        [AllowNull()]
        [object] $HeadContent
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($null -eq $BaseContent -or $null -eq $HeadContent) {
        return $false
    }
    $base = ([string]$BaseContent) -replace "`r`n", "`n"
    $head = ([string]$HeadContent) -replace "`r`n", "`n"
    if ($base -ceq $head) {
        return $true
    }
    $leaf = [System.IO.Path]::GetFileName(($Path -replace '\\', '/'))
    if ($leaf -notmatch '(?i)\.(tf|tfvars)$') {
        return $false
    }

    $terraform = Resolve-AvmTool -Name 'terraform'
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-release-fmt-' + [guid]::NewGuid().ToString('N'))
    $encoding = [System.Text.UTF8Encoding]::new($false)
    try {
        $formatted = [System.Collections.Generic.List[string]]::new()
        foreach ($side in @(@{ Name = 'base'; Content = $base }, @{ Name = 'head'; Content = $head })) {
            $folder = Join-Path $root $side.Name
            $null = [System.IO.Directory]::CreateDirectory($folder)
            $file = Join-Path $folder $leaf
            [System.IO.File]::WriteAllText($file, $side.Content, $encoding)
            $result = Invoke-AvmProcess -FilePath $terraform.Path -ArgumentList @('fmt', '-no-color', '-list=false', '-write=true', $folder) -IgnoreExitCode -Label "terraform fmt $($side.Name)/$leaf"
            if ($result.ExitCode -ne 0) {
                return $false
            }
            $formatted.Add(([System.IO.File]::ReadAllText($file) -replace "`r`n", "`n"))
        }
        return $formatted[0] -ceq $formatted[1]
    }
    finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ProgressAction SilentlyContinue
        }
    }
}
