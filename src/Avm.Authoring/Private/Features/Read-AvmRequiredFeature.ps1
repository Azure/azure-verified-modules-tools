function Read-AvmRequiredFeature {
    <#
    .SYNOPSIS
        Read the optional .required-features.json manifest.

    .DESCRIPTION
        Without ModulePath, Root is a module root whose manifest is a JSON array
        of feature names. With ModulePath, Root is the Bicep registry root whose
        manifest maps exact avm/res|ptn|utl module paths to feature arrays; the
        whole object is validated and only the exact ModulePath entry is returned.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [string] $ModulePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $modulePattern = '\Aavm/(res|ptn|utl)/[a-z0-9]+(?:-[a-z0-9]+)*(?:/[a-z0-9]+(?:-[a-z0-9]+)*)+\z'
    if ($ModulePath -and $ModulePath -cnotmatch $modulePattern) {
        throw [AvmConfigurationException]::new(
            "Module path '$ModulePath' is not an exact lowercase avm/res|ptn|utl module directory.")
    }

    $files = @(Get-ChildItem -LiteralPath $Root -File -Force |
            Where-Object { $_.Name -ieq '.required-features.json' })
    if ($files.Count -eq 0) {
        return
    }
    $location = if ($ModulePath) { 'repository' } else { 'module' }
    if ($files.Count -ne 1 -or $files[0].Name -cne '.required-features.json') {
        throw [AvmConfigurationException]::new(
            "The required-features manifest must be named exactly '.required-features.json' at the $location root.")
    }
    if ($files[0].Length -gt 65536) {
        throw [AvmConfigurationException]::new(
            '.required-features.json exceeds the 64 KiB limit.')
    }

    $contents = Get-Content -LiteralPath $files[0].FullName -Raw -Encoding utf8
    if (-not $ModulePath) {
        try {
            $entries = ConvertFrom-Json -InputObject $contents -NoEnumerate -ErrorAction Stop
        }
        catch {
            throw [AvmConfigurationException]::new(
                '.required-features.json must contain a valid JSON array of feature names.',
                $_.Exception)
        }
        if ($entries -isnot [array]) {
            throw [AvmConfigurationException]::new(
                '.required-features.json must contain a top-level JSON array of feature names.')
        }
        return ConvertTo-AvmRequiredFeature -Entries $entries
    }

    # JsonDocument keeps exact key case and exposes duplicate keys, unlike ConvertFrom-Json.
    $objectMessage = '.required-features.json must contain a JSON object mapping module paths to feature arrays.'
    try {
        $document = [System.Text.Json.JsonDocument]::Parse([string]$contents)
    }
    catch {
        throw [AvmConfigurationException]::new($objectMessage, $_.Exception)
    }
    try {
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw [AvmConfigurationException]::new($objectMessage)
        }
        $modules = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $selected = @()
        foreach ($module in $document.RootElement.EnumerateObject()) {
            if ($module.Name -cnotmatch $modulePattern) {
                throw [AvmConfigurationException]::new(
                    ".required-features.json key [$($module.Name)] must be an exact avm/res|ptn|utl module directory.")
            }
            if (-not $modules.Add($module.Name)) {
                throw [AvmConfigurationException]::new(
                    "Duplicate module path [$($module.Name)] in .required-features.json.")
            }
            if ($module.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
                throw [AvmConfigurationException]::new(
                    ".required-features.json entry [$($module.Name)] must be a JSON array of Namespace/FeatureName strings.")
            }
            $entries = [object[]]@(foreach ($item in $module.Value.EnumerateArray()) {
                    if ($item.ValueKind -eq [System.Text.Json.JsonValueKind]::String) { $item.GetString() } else { $item.ValueKind }
                })
            $features = @(ConvertTo-AvmRequiredFeature -Entries $entries -ModulePath $module.Name)
            if ($module.Name -ceq $ModulePath) {
                $selected = $features
            }
        }
        return $selected
    }
    finally {
        $document.Dispose()
    }
}
