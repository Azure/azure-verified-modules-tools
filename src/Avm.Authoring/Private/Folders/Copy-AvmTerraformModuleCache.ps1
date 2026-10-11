function Copy-AvmTerraformModuleCache {
    <#
    .SYNOPSIS
        Seed an isolated Terraform working directory with downloaded modules.

    .DESCRIPTION
        Copies only .terraform/modules from an initialized source directory.
        Provider binaries, state, plans, and other Terraform data remain
        excluded so the destination keeps its isolated provider lifecycle.

    .PARAMETER SourceWorkingDirectory
        Initialized Terraform working directory to copy modules from.

    .PARAMETER DestinationWorkingDirectory
        Isolated Terraform working directory to seed.

    .PARAMETER DestinationDataDirectory
        Terraform data directory to seed. Defaults to
        <DestinationWorkingDirectory>/.terraform.

    .OUTPUTS
        [bool] indicating whether an installed module cache was copied.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $SourceWorkingDirectory,

        [Parameter(Mandatory)]
        [string] $DestinationWorkingDirectory,

        [string] $DestinationDataDirectory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $sourceModules = Join-Path -Path $SourceWorkingDirectory -ChildPath '.terraform' -AdditionalChildPath 'modules'
    $manifestPath = Join-Path $sourceModules 'modules.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($DestinationDataDirectory)) {
        $DestinationDataDirectory = Join-Path $DestinationWorkingDirectory '.terraform'
    }
    $destinationModules = Join-Path $DestinationDataDirectory 'modules'
    Copy-AvmTerraformModuleTree `
        -SourceRoot $sourceModules `
        -DestinationRoot $destinationModules

    $defaultDestinationData = Join-Path $DestinationWorkingDirectory '.terraform'
    $pathComparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not [string]::Equals(
            [System.IO.Path]::GetFullPath($DestinationDataDirectory),
            [System.IO.Path]::GetFullPath($defaultDestinationData),
            $pathComparison)) {
        $destinationManifest = Join-Path $destinationModules 'modules.json'
        $manifest = ConvertFrom-Json `
            -InputObject ([System.IO.File]::ReadAllText($destinationManifest)) `
            -AsHashtable `
            -Depth 100 `
            -ErrorAction Stop
        foreach ($module in @($manifest.Modules)) {
            if ($module.Dir -isnot [string]) {
                continue
            }
            $sourceModulePath = [System.IO.Path]::GetFullPath($module.Dir, $SourceWorkingDirectory)
            $relativeModulePath = [System.IO.Path]::GetRelativePath($sourceModules, $sourceModulePath)
            if ([System.IO.Path]::IsPathRooted($relativeModulePath) -or
                @($relativeModulePath -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0) {
                continue
            }
            $module.Dir = (Join-Path $destinationModules $relativeModulePath).Replace('\', '/')
        }
        $json = ConvertTo-Json -InputObject $manifest -Depth 100
        [System.IO.File]::WriteAllText(
            $destinationManifest,
            $json.ReplaceLineEndings("`n") + "`n",
            [System.Text.UTF8Encoding]::new($false))
    }

    Write-AvmLog (
        'module-cache: seeded {0} from {1}' -f
        $DestinationWorkingDirectory,
        $SourceWorkingDirectory
    ) -Level Verbose | Out-Null
    return $true
}
