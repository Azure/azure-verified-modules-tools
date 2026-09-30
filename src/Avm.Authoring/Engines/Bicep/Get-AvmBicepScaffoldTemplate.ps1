function Get-AvmBicepScaffoldTemplate {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('main.bicep', 'child.bicep', 'utility.bicep', 'main.test.bicep', 'version.json', 'CHANGELOG.md')]
        [string] $Name
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $templateRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' `
        -AdditionalChildPath '..', 'Resources', 'Scaffolds', 'Bicep'
    $path = Join-Path -Path $templateRoot -ChildPath $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("Bundled Bicep scaffold template is missing: $path")
    }
    $content = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $true))
    if ([string]::IsNullOrWhiteSpace($content) -or $content.Contains("`r")) {
        throw [System.IO.InvalidDataException]::new("Bundled Bicep scaffold template is empty or has invalid line endings: $path")
    }
    return $content
}
