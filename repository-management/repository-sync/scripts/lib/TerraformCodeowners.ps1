function ConvertTo-TerraformCodeowners {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$')] [string] $Organization,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [ValidateNotNull()] [string[]] $DefaultTeams,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [ValidateNotNull()] [string[]] $FileProtectionTeams,
        [Parameter(Mandatory)] [string] $Template
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $placeholder = '__AVM_CODEOWNERS_RULES__'
    if ($Template.Contains("`r") -or $Template.StartsWith([string][char]0xFEFF, [System.StringComparison]::Ordinal) -or
        ([regex]::Matches($Template, $placeholder)).Count -ne 1 -or
        $Template -cnotmatch "(?m)^$placeholder$" -or -not $Template.EndsWith("`n")) {
        throw [System.IO.InvalidDataException]::new('The Terraform CODEOWNERS template must use UTF-8 without BOM, LF endings, and exactly one standalone rules placeholder.')
    }

    $rules = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(
        @{ Pattern = '*'; Teams = $DefaultTeams }
        @{ Pattern = '.github/CODEOWNERS'; Teams = $FileProtectionTeams }
    )) {
        $handles = @(
            foreach ($team in @($entry.Teams | Select-Object -Unique)) {
                if ($team -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') {
                    throw [System.IO.InvalidDataException]::new("Invalid GitHub team slug in Terraform CODEOWNERS configuration: '$team'.")
                }
                "@$Organization/$team"
            }
        )
        if ($handles.Count -gt 0) {
            $rules.Add("$($entry.Pattern) $($handles -join ' ')")
        }
    }

    return $Template.Replace($placeholder, ($rules -join "`n")).TrimEnd("`n") + "`n"
}

function Set-TerraformCodeowners {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $RepositoryRoot,
        [Parameter(Mandatory)] [string] $Content
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("Repository root does not exist: '$RepositoryRoot'.")
    }
    $githubPath = Join-Path $RepositoryRoot '.github'
    $codeownersPath = Join-Path $githubPath 'CODEOWNERS'
    foreach ($target in @(
        @{ Path = $githubPath; IsDirectory = $true }
        @{ Path = $codeownersPath; IsDirectory = $false }
    )) {
        if (Test-Path -LiteralPath $target.Path) {
            $item = Get-Item -LiteralPath $target.Path -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
                $item.PSIsContainer -ne $target.IsDirectory) {
                throw [System.IO.InvalidDataException]::new("Cannot generate CODEOWNERS through a link or incompatible path: '$($target.Path)'.")
            }
        }
    }
    if ($PSCmdlet.ShouldProcess($codeownersPath, 'Write generated Terraform CODEOWNERS')) {
        $null = New-Item -ItemType Directory -Path $githubPath -Force
        [System.IO.File]::WriteAllText($codeownersPath, $Content, [System.Text.UTF8Encoding]::new($false))
    }
}
