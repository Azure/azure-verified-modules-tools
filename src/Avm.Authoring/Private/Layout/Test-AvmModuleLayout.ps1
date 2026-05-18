function Test-AvmModuleLayout {
    <#
    .SYNOPSIS
        Verify the on-disk layout, file casing and manifest shape of an
        Avm.Authoring module folder.

    .DESCRIPTION
        Implements the structural checks defined in the implementation spec
        section 12 (layout enforcement). Used by the InvokeBuild 'layout'
        task and available to any tooling that needs the same guarantees:

          - The folder name uses the exact expected casing.
          - The manifest (.psd1) and module (.psm1) file names exist with
            exact casing on case-sensitive file systems.
          - The manifest Name field matches the manifest file basename
            exactly, including casing.
          - The manifest declares a PowerShellVersion >= the minimum the
            spec requires.

        Throws on the first failure so the caller (build, CI gate, smoke
        test) sees one canonical error. Returns the validated module
        manifest object on success.

    .PARAMETER ModuleRoot
        Absolute path to the module folder (the directory that contains the
        .psd1).

    .PARAMETER ExpectedFolderName
        Expected leaf folder name with exact casing. Defaults to
        'Avm.Authoring'.

    .PARAMETER MinimumPowerShellVersion
        Minimum value accepted for the manifest's PowerShellVersion field.
        Defaults to 7.4 (spec section 2).

    .OUTPUTS
        Microsoft.PowerShell.Commands.PSModuleInfo from Test-ModuleManifest.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSModuleInfo])]
    param(
        [Parameter(Mandatory)] [string] $ModuleRoot,

        [string] $ExpectedFolderName = 'Avm.Authoring',

        [version] $MinimumPowerShellVersion = [version]'7.4'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $ModuleRoot -PathType Container)) {
        throw [AvmConfigurationException]::new("Module root does not exist: $ModuleRoot")
    }

    $manifestPath = Join-Path $ModuleRoot "$ExpectedFolderName.psd1"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw [AvmConfigurationException]::new("Manifest not found: $manifestPath")
    }
    $manifest = Test-ModuleManifest -Path $manifestPath

    # Folder casing.
    $folder = Split-Path -Leaf $ModuleRoot
    if ($folder -cne $ExpectedFolderName) {
        throw [AvmConfigurationException]::new(
            "Module folder casing is '$folder'; expected '$ExpectedFolderName'.")
    }

    # File casing for the manifest and the root .psm1.
    foreach ($expected in @("$ExpectedFolderName.psd1", "$ExpectedFolderName.psm1")) {
        $found = Get-ChildItem -Path $ModuleRoot -File |
            Where-Object { $_.Name -ceq $expected }
        if (-not $found) {
            throw [AvmConfigurationException]::new(
                "Expected file '$expected' not found with exact casing in $ModuleRoot.")
        }
    }

    # Manifest Name vs file basename casing.
    $expectedName = [System.IO.Path]::GetFileNameWithoutExtension($manifestPath)
    if ($manifest.Name -cne $expectedName) {
        throw [AvmConfigurationException]::new(
            "Manifest Name '$($manifest.Name)' does not match file basename '$expectedName' (case-sensitive).")
    }

    # PowerShellVersion must be >= the spec floor.
    if ($manifest.PowerShellVersion -lt $MinimumPowerShellVersion) {
        throw [AvmConfigurationException]::new(
            "Manifest PowerShellVersion is '$($manifest.PowerShellVersion)'; must be >= $MinimumPowerShellVersion.")
    }

    return $manifest
}
