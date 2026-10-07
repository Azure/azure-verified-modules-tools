function Get-AvmToolDefinition {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Pins,
        [string[]] $Name = @(),
        [switch] $IncludeDependencies,
        [Parameter(DontShow)] [string[]] $DependencyChain = @()
    )

    $definitions = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($tool in $Pins.tools) { $definitions.Add($tool) }
    if ($Pins.ContainsKey('powerShellModules')) {
        foreach ($moduleName in @($Pins.powerShellModules.Keys | Sort-Object -CaseSensitive)) {
            $pin = $Pins.powerShellModules[$moduleName]
            $hashes = @{}
            foreach ($platform in @('windows-amd64', 'windows-arm64', 'linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64')) {
                $hashes[$platform] = $pin.sha256
            }
            $definition = @{
                name         = $moduleName
                version      = $pin.version
                kind         = 'powershell-module'
                entrypoint   = "$moduleName.psd1"
                urlTemplate  = "https://www.powershellgallery.com/api/v2/package/$moduleName/{version}"
                archive      = 'zip'
                sha256       = $hashes
                dependencies = @(if ($pin.ContainsKey('dependencies')) { $pin.dependencies })
            }
            if ($pin.ContainsKey('versionOverride')) { $definition['versionOverride'] = $pin.versionOverride }
            $definitions.Add($definition)
        }
    }
    foreach ($requested in $Name) {
        if (@($definitions | ForEach-Object { $_.name }) -cnotcontains $requested) {
            throw [System.ArgumentException]::new("Unknown tool '$requested' (not in avm.pins).")
        }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($tool in $definitions) {
        if ($Name.Count -gt 0 -and $Name -cnotcontains $tool.name) { continue }
        if ($DependencyChain -ccontains $tool.name) {
            throw [AvmConfigurationException]::new("Circular tool dependency: $($DependencyChain -join ' -> ') -> $($tool.name)")
        }
        if ($IncludeDependencies -and $tool.ContainsKey('dependencies') -and $tool.dependencies.Count -gt 0) {
            foreach ($dependency in (Get-AvmToolDefinition -Pins $Pins -Name $tool.dependencies -IncludeDependencies `
                        -DependencyChain @($DependencyChain + $tool.name))) {
                if ($seen.Add($dependency.name)) { $dependency }
            }
        }
        if ($seen.Add($tool.name)) { $tool }
    }
}
