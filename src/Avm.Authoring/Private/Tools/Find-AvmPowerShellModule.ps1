function Find-AvmPowerShellModule {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSModuleInfo])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [version] $Version
    )

    $toolsRoot = [System.IO.Path]::GetFullPath((Get-AvmFolder -Kind Tools))
    $prefix = $toolsRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    foreach ($module in @(Get-Module -ListAvailable -Name $Name)) {
        if ($module.Name -cne $Name -or $module.Version -ne $Version -or -not $module.ModuleBase) { continue }
        $directory = [System.IO.Path]::GetFullPath($module.ModuleBase)
        if ($directory.StartsWith($prefix, $comparison) -or
            (Test-Path -LiteralPath (Join-Path $directory '.unverified') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $directory "$Name.psd1") -PathType Leaf)) { continue }
        return $module
    }
}
