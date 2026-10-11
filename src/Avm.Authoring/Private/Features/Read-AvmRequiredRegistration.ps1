function Read-AvmRequiredRegistration {
    <#
    .SYNOPSIS
        Read an optional subscription feature or resource-provider manifest.

    .DESCRIPTION
        Without ModulePath, Root is a module root whose manifest is a JSON array
        of feature names. Provider requirements always use the registry map.
        With ModulePath, Root is the Bicep registry root whose manifest maps
        exact avm/res|ptn|utl module paths to registration arrays; the
        whole object is validated and only the exact ModulePath entry is returned.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [string] $ModulePath,

        [ValidateSet('Feature', 'Provider')]
        [string] $Kind = 'Feature'
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $modulePattern = '\Aavm/(res|ptn|utl)/[a-z0-9]+(?:-[a-z0-9]+)*(?:/[a-z0-9]+(?:-[a-z0-9]+)*)+\z'
    if (($Kind -eq 'Provider' -and -not $ModulePath) -or ($ModulePath -and $ModulePath -cnotmatch $modulePattern)) {
        throw [AvmConfigurationException]::new(
            "Module path '$ModulePath' is not an exact lowercase avm/res|ptn|utl module directory.")
    }

    $filename = if ($Kind -eq 'Feature') { '.required-features.json' } else { '.required-resource-providers.json' }
    $format = if ($Kind -eq 'Feature') { 'Namespace/FeatureName' } else { 'provider namespace' }
    $files = @(Get-ChildItem -LiteralPath $Root -Force |
            Where-Object { $_.Name -ieq $filename })
    if ($files.Count -eq 0) {
        Write-AvmLog -Level Info -Message "No $filename at '$Root'; subscription $Kind registration is skipped."
        return
    }
    $location = if ($ModulePath) { 'repository' } else { 'module' }
    if ($files.Count -ne 1 -or $files[0].Name -cne $filename -or $files[0].PSIsContainer) {
        throw [AvmConfigurationException]::new(
            "The registration manifest must be a file named exactly '$filename' at the $location root.")
    }
    if ($files[0].Length -gt 65536) {
        throw [AvmConfigurationException]::new(
            "$filename exceeds the 64 KiB limit.")
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
        return ConvertTo-AvmRequiredRegistration -Entries $entries -Kind $Kind
    }

    $objectMessage = "$filename must contain a JSON object mapping module paths to $Kind arrays."
    try {
        $document = [System.Text.Json.JsonDocument]::Parse([string]$contents)
    }
    catch [System.Text.Json.JsonException] {
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
                    "$filename key [$($module.Name)] must be an exact avm/res|ptn|utl module directory.")
            }
            if (-not $modules.Add($module.Name)) {
                throw [AvmConfigurationException]::new(
                    "Duplicate module path [$($module.Name)] in $filename.")
            }
            if ($module.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
                throw [AvmConfigurationException]::new(
                    "$filename entry [$($module.Name)] must be a JSON array of $format strings.")
            }
            $entries = [object[]]@(foreach ($item in $module.Value.EnumerateArray()) {
                    if ($item.ValueKind -eq [System.Text.Json.JsonValueKind]::String) { $item.GetString() } else { $item.ValueKind }
                })
            $requirements = @(ConvertTo-AvmRequiredRegistration -Entries $entries -ModulePath $module.Name -Kind $Kind)
            if ($module.Name -ceq $ModulePath) {
                $selected = $requirements
            }
        }
        if ($selected.Count -eq 0) {
            Write-AvmLog -Level Info -Message "No required $Kind entries for '$ModulePath'; subscription registration is skipped."
        }
        return $selected
    }
    finally {
        $document.Dispose()
    }
}
