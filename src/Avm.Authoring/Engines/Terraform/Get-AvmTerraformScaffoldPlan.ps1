function Get-AvmTerraformScaffoldPlan {
    <#
    .SYNOPSIS
        Plan the packaged minimal Terraform module files that are missing from a module root.
    .DESCRIPTION
        Mirrors Resources/Scaffolds/Terraform into the module root. Existing
        files are left untouched; _header.md is rendered from the module's
        display name and description. tests/.gitkeep is added when the tests
        directory holds no files. Managed files, telemetry, and README.md are
        produced later by avm pre-commit.
    .PARAMETER Path
        Module root directory.
    .PARAMETER Metadata
        Validated module metadata.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Metadata
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $templateRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..' `
                -AdditionalChildPath '..', 'Resources', 'Scaffolds', 'Terraform'))
    $templates = @(Get-ChildItem -LiteralPath $templateRoot -File -Recurse -Force)
    if ($templates.Count -eq 0) {
        throw [System.IO.FileNotFoundException]::new("Bundled Terraform scaffold is missing: $templateRoot")
    }
    $relativePaths = [string[]]@($templates | ForEach-Object {
            [System.IO.Path]::GetRelativePath($templateRoot, $_.FullName).Replace('\', '/')
        })
    [System.Array]::Sort($relativePaths, [System.StringComparer]::Ordinal)

    $root = [System.IO.Path]::GetFullPath($Path)
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $plans = [System.Collections.Generic.List[object]]::new()
    $definitions = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in $relativePaths) {
        $content = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($templateRoot, $relative), $strictUtf8)
        if ([string]::IsNullOrWhiteSpace($content) -or $content.Contains("`r")) {
            throw [System.IO.InvalidDataException]::new("Bundled Terraform scaffold file is empty or has invalid line endings: $relative")
        }
        if ($relative -ceq '_header.md') {
            foreach ($placeholder in @('<Add module name>', '<Add description>')) {
                if (($content.Split([string[]]@($placeholder), [System.StringSplitOptions]::None)).Count -ne 2) {
                    throw [System.IO.InvalidDataException]::new("Bundled Terraform _header.md has an invalid $placeholder placeholder.")
                }
            }
            $content = $content.Replace('<Add module name>', [string]$Metadata['moduleDisplayName'])
            $content = $content.Replace('<Add description>', [string]$Metadata['moduleDescription'])
        }
        $definitions.Add([pscustomobject]@{ Relative = $relative; Content = $content })
    }
    $testsPath = Join-Path -Path $root -ChildPath 'tests'
    if (-not (Test-Path -LiteralPath $testsPath -PathType Container) -or
        @(Get-ChildItem -LiteralPath $testsPath -File -Recurse -Force).Count -eq 0) {
        $definitions.Add([pscustomobject]@{ Relative = 'tests/.gitkeep'; Content = '' })
    }

    foreach ($definition in $definitions) {
        $target = $root
        foreach ($segment in ($definition.Relative -split '/')) {
            $target = Join-Path -Path $target -ChildPath $segment
        }
        $parent = Split-Path -Path $target -Parent
        $leaf = Split-Path -Path $target -Leaf
        if (Test-Path -LiteralPath $parent -PathType Container) {
            $collisions = @(Get-ChildItem -LiteralPath $parent -Force | Where-Object { $_.Name -ieq $leaf })
            if ($collisions.Count -gt 0) {
                if ($collisions.Count -ne 1 -or $collisions[0].PSIsContainer -or $collisions[0].Name -cne $leaf) {
                    throw [System.ArgumentException]::new("Scaffold file must be a file with exact casing: $target")
                }
                continue
            }
        }
        elseif (Test-Path -LiteralPath $parent -PathType Leaf) {
            throw [System.ArgumentException]::new("Scaffold parent is a file: $parent")
        }
        $plans.Add([pscustomobject]@{ Path = $target; Content = $definition.Content; Original = $null })
    }
    return $plans.ToArray()
}
