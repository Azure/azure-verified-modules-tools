function Merge-AvmToolVersionOverride {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $Pins,
        [Parameter(Mandatory)] [string] $ModuleRoot
    )

    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path -LiteralPath $ModuleRoot -PathType Container)) { return $Pins }
    $signature = Get-AvmContextRootSignature -Path $ModuleRoot
    if (-not $signature.HasTerraformSource) {
        $monorepo = Get-AvmBicepMonorepoRoot -Path $ModuleRoot
        if ($monorepo) { $ModuleRoot = $monorepo }
    }
    $directory = Join-Path $ModuleRoot '.avm'
    if (-not (Test-Path -LiteralPath $directory)) { return $Pins }
    $item = Get-Item -LiteralPath $directory -Force
    if (-not $item.PSIsContainer -or $item.Name -cne '.avm' -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw [AvmConfigurationException]::new("Tool overrides require a regular, exactly cased .avm directory: $directory")
    }
    $files = @(Get-ChildItem -LiteralPath $directory -Force | Where-Object { $_.Name -ieq 'tool-version-overrides.json' })
    if ($files.Count -eq 0) { return $Pins }
    if ($files.Count -ne 1 -or $files[0].PSIsContainer -or $files[0].Name -cne 'tool-version-overrides.json' -or
        ($files[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw [AvmConfigurationException]::new("Tool overrides require one regular, exactly cased .avm/tool-version-overrides.json in '$ModuleRoot'.")
    }
    $path = $files[0].FullName
    try {
        $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($text)
        try {
            $pending = [System.Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
            $pending.Push($document.RootElement)
            while ($pending.Count -gt 0) {
                $element = $pending.Pop()
                if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($property in $element.EnumerateObject()) {
                        if (-not $keys.Add($property.Name)) {
                            throw [System.Data.DataException]::new("Duplicate pin key '$($property.Name)'.")
                        }
                        $pending.Push($property.Value)
                    }
                }
                elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                    foreach ($child in $element.EnumerateArray()) { $pending.Push($child) }
                }
            }
        }
        finally { $document.Dispose() }
        $override = $text | ConvertFrom-Json -AsHashtable
        if ($override -isnot [hashtable]) {
            throw [System.Data.DataException]::new('Expected an object mapping known tool names to version strings.')
        }
        foreach ($name in $override.Keys) {
            $tool = @($Pins.tools | Where-Object { $_.name -ceq $name })
            $isModule = $Pins.ContainsKey('powerShellModules') -and @($Pins.powerShellModules.Keys) -ccontains $name
            if ($tool.Count -ne 1 -and -not $isModule) {
                throw [System.Data.DataException]::new("Unknown tool '$name'. Tool names are case-sensitive.")
            }
            $version = $override[$name]
            $pattern = if ($isModule) { '^[0-9]+\.[0-9]+\.[0-9]+$' } else { '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$' }
            if ($version -isnot [string] -or $version -cnotmatch $pattern) {
                throw [System.Data.DataException]::new("Tool '$name' requires a version string without a leading 'v'.")
            }
            if ($name -ceq 'Pester' -and [version]$version -lt [version]'5.5.0') {
                throw [System.Data.DataException]::new('Pester must be version 5.5.0 or later.')
            }
            $entry = if ($isModule) { $Pins.powerShellModules[$name] } else { $tool[0] }
            $entry['versionOverride'] = @{ PackagedVersion = $entry.version; Path = $path }
            $entry.version = $version
            $entry.sha256 = if ($isModule) { $null } else { @{} }
        }
    }
    catch {
        throw [AvmConfigurationException]::new("Invalid tool overrides in '$path': $($_.Exception.Message)")
    }
    return $Pins
}
