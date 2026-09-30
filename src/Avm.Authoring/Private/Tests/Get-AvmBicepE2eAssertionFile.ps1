function Get-AvmBicepE2eAssertionFile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $CasePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $caseDirectory = [System.IO.Path]::GetDirectoryName($CasePath)
    foreach ($file in @(Get-ChildItem -LiteralPath $caseDirectory -Recurse -File -Force -ErrorAction Stop |
                Where-Object { $_.Name -match '(?i)\.tests\.ps1$' } |
                Sort-Object -Property FullName -CaseSensitive)) {
        if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e assertion file cannot be linked: $($file.FullName)")
        }
        $parent = [System.IO.DirectoryInfo]::new($file.DirectoryName)
        $nestedCase = $false
        while (-not [string]::Equals(
                $parent.FullName, $caseDirectory, [System.StringComparison]::Ordinal)) {
            if (Test-Path -LiteralPath (Join-Path $parent.FullName 'main.test.bicep') -PathType Leaf) {
                $nestedCase = $true
                break
            }
            $parent = $parent.Parent
        }
        if (-not $nestedCase) {
            $file.FullName
        }
    }
}
