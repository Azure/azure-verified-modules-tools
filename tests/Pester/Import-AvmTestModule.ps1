#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceManifest
)

if ([string]::IsNullOrWhiteSpace($env:AVM_TEST_PACKAGE_ROOT)) {
    Import-Module -Name $SourceManifest -Force -ErrorAction Stop
    return
}

$testPackageRoot = (Resolve-Path -LiteralPath $env:AVM_TEST_PACKAGE_ROOT -ErrorAction Stop).ProviderPath
$testPackageManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $testPackageRoot 'Avm.Authoring.psd1')
$testPackageModule = Import-Module -Name 'Avm.Authoring' `
    -RequiredVersion $testPackageManifest.ModuleVersion -Force -PassThru -ErrorAction Stop
if ($testPackageModule.ModuleBase -cne $testPackageRoot) {
    throw [System.InvalidOperationException]::new(
        "Tests imported '$($testPackageModule.ModuleBase)', not the extracted package '$testPackageRoot'.")
}

$testPackagePrefix = $testPackageRoot + [System.IO.Path]::DirectorySeparatorChar
foreach ($testPackageCommand in $testPackageModule.ExportedFunctions.Values) {
    if ([string]::IsNullOrWhiteSpace($testPackageCommand.ScriptBlock.File) -or
        -not $testPackageCommand.ScriptBlock.File.StartsWith(
            $testPackagePrefix, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            "Test command '$($testPackageCommand.Name)' is not defined inside the extracted package.")
    }
}
