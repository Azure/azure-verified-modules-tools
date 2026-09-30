function Get-AvmBicepPolicyTestFile {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $testRoot = Join-Path -Path $ModulePath -ChildPath 'tests' `
        -AdditionalChildPath 'e2e'
    if (-not [System.IO.Directory]::Exists($testRoot)) {
        return @()
    }
    if ((Get-Item -LiteralPath $testRoot -Force).Attributes -band
        [System.IO.FileAttributes]::ReparsePoint) {
        throw [AvmConfigurationException]::new('PSRule cannot select tests through a linked e2e directory.')
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $testRoot -Recurse -Directory -Force)) {
        if ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw [AvmConfigurationException]::new(
                'PSRule cannot select tests through a linked e2e directory.')
        }
    }

    $selected = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $testRoot -Recurse -File `
                -Filter '*.test.bicep' -Force)) {
        $relative = [System.IO.Path]::GetRelativePath($testRoot, $file.FullName).Replace('\', '/')
        if ($relative -notmatch '(?i)(?:^|/)(?:defaults|waf-aligned)/main\.test\.bicep$') {
            continue
        }
        if ($file.Name -cne 'main.test.bicep' -or
            ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new(
                'PSRule requires regular main.test.bicep files with exact casing.')
        }
        $selected.Add($file)
    }
    return @($selected | Sort-Object -Culture 'en-US' -Property FullName)
}
