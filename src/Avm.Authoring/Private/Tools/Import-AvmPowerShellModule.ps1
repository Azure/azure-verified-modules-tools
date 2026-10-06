function Import-AvmPowerShellModule {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSModuleInfo])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $ModuleRoot,
        [Parameter(DontShow)] [string] $PinsPath,
        [switch] $Global,
        [Parameter(DontShow)] [string[]] $ImportChain = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($ImportChain -ccontains $Name) {
        throw [AvmConfigurationException]::new("Circular PowerShell module dependency: $($ImportChain -join ' -> ') -> $Name")
    }
    $pins = Read-AvmPins -ModuleRoot $ModuleRoot -Path $PinsPath
    if (-not $pins.ContainsKey('powerShellModules') -or @($pins.powerShellModules.Keys) -cnotcontains $Name) {
        throw [AvmConfigurationException]::new("No PowerShell module pin for '$Name'.")
    }
    $pin = $pins.powerShellModules[$Name]
    foreach ($loaded in @(Get-Module -All -Name $Name)) {
        if ($loaded.Version -ne [version]$pin.version) {
            throw [AvmToolException]::new(
                "PowerShell module '$Name' $($loaded.Version) is already loaded, but the configured version is $($pin.version). Start a fresh PowerShell session before running AVM commands.",
                'AVM1013')
        }
    }
    $dependencies = @{}
    if ($pin.ContainsKey('dependencies')) {
        foreach ($dependency in $pin.dependencies) {
            $loaded = Import-AvmPowerShellModule -Name $dependency -ModuleRoot $ModuleRoot -PinsPath $PinsPath -Global:$Global `
                -ImportChain @($ImportChain + $Name)
            Import-Module -Name (Join-Path $loaded.ModuleBase "$dependency.psd1") -Global:$Global -ErrorAction Stop
            $dependencies[$dependency] = $loaded
        }
    }
    $tool = Resolve-AvmTool -Name $Name -ModuleRoot $ModuleRoot -PinsPath $PinsPath
    try {
        $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($tool.Path))
        $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        foreach ($loaded in @(Get-Module -All -Name $Name)) {
            if (-not [string]::Equals($loaded.ModuleBase, $directory, $comparison) -and
                (Test-Path -LiteralPath (Join-Path $loaded.ModuleBase '.unverified') -PathType Leaf)) {
                throw [System.IO.InvalidDataException]::new("An unverified '$Name' override is already loaded from '$($loaded.ModuleBase)'.")
            }
        }
        $manifest = Import-PowerShellDataFile -LiteralPath $tool.Path -ErrorAction Stop
        if (-not $manifest.ContainsKey('ModuleVersion') -or [version]$manifest.ModuleVersion -ne [version]$pin.version) {
            throw [System.IO.InvalidDataException]::new("The manifest does not declare '$Name' $($pin.version).")
        }
        if ($manifest.ContainsKey('RequiredModules')) {
            foreach ($requirement in @($manifest.RequiredModules)) {
                $dependencyName = if ($requirement -is [string]) { $requirement } else { $requirement.ModuleName }
                if (-not $dependencies.ContainsKey($dependencyName)) {
                    throw [System.IO.InvalidDataException]::new("Module '$Name' declares an unpinned dependency '$dependencyName'.")
                }
                if ($requirement -is [hashtable]) {
                    $selected = $dependencies[$dependencyName]
                    $compatible = (-not $requirement.ContainsKey('ModuleVersion') -or $selected.Version -ge [version]$requirement.ModuleVersion) -and
                    (-not $requirement.ContainsKey('RequiredVersion') -or $selected.Version -eq [version]$requirement.RequiredVersion) -and
                    (-not $requirement.ContainsKey('MaximumVersion') -or $selected.Version -le [version]$requirement.MaximumVersion) -and
                    (-not $requirement.ContainsKey('GUID') -or $selected.Guid -eq [guid]$requirement.GUID)
                    if (-not $compatible) {
                        throw [System.IO.InvalidDataException]::new("Module '$Name' requires a different '$dependencyName' dependency; selected pin is $($selected.Version).")
                    }
                }
            }
        }
        $module = Import-Module -Name $tool.Path -Global:$Global -PassThru -DisableNameChecking -ErrorAction Stop
        if ($module.Name -cne $Name -or $module.Version -ne [version]$pin.version -or
            -not [string]::Equals($module.ModuleBase, $directory, $comparison)) {
            throw [System.IO.InvalidDataException]::new("The loaded module does not match '$Name' $($pin.version) at '$directory'.")
        }
        foreach ($dependency in $module.RequiredModules) {
            if (-not $dependencies.ContainsKey($dependency.Name) -or
                $dependency.Version -ne $dependencies[$dependency.Name].Version -or
                -not [string]::Equals($dependency.ModuleBase, $dependencies[$dependency.Name].ModuleBase, $comparison)) {
                throw [System.IO.InvalidDataException]::new("Module '$Name' loaded an unpinned dependency '$($dependency.Name)' $($dependency.Version).")
            }
        }
        return $module
    }
    catch {
        throw [AvmToolException]::new(
            "Could not import '$Name' $($pin.version) from '$($tool.Path)': $($_.Exception.Message) Run avm tool install $Name -Force, then retry in a fresh PowerShell session.",
            'AVM1013', $_.Exception)
    }
}
