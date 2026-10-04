function Get-AvmBicepTestTokenMap {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [string] $ManagementGroupId,

        [string] $TenantId,

        [string] $RunId,

        [string] $TokenFile,

        [System.Collections.IDictionary] $Tokens = @{},

        [System.Collections.IDictionary] $DefaultTokens = @{}
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not [string]::IsNullOrWhiteSpace($TokenFile) -and $Tokens.psbase.Count -gt 0) {
        throw [AvmConfigurationException]::new('Use either -TokenFile or -Tokens, not both.')
    }
    $provided = $Tokens
    if (-not [string]::IsNullOrWhiteSpace($TokenFile)) {
        $path = if ([System.IO.Path]::IsPathRooted($TokenFile)) {
            $TokenFile
        }
        else {
            Join-Path $Root $TokenFile
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw [AvmConfigurationException]::new("Bicep test token file not found: $path")
        }
        $provided = Get-Content -LiteralPath $path -Raw -Encoding utf8 |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($provided -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new("Bicep test token file must contain a JSON object: $path")
        }
    }

    $values = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $values.Add('subscriptionId', $SubscriptionId)
    if (-not [string]::IsNullOrWhiteSpace($ManagementGroupId)) {
        $values.Add('managementGroupId', $ManagementGroupId)
    }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $values.Add('tenantId', $TenantId)
    }
    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        if ($RunId -cnotmatch '^[0-9a-f]{32}$') {
            throw [AvmConfigurationException]::new('Bicep e2e run ID must be 32 lowercase hexadecimal characters.')
        }
        $values.Add('avmE2eRunId', $RunId)
        $values.Add('avmE2eSuffix', $RunId.Substring(0, 10))
    }
    $merged = @{}
    foreach ($source in @($DefaultTokens, $provided)) {
        foreach ($name in $source.psbase.Keys) {
            if ($merged.ContainsKey($name)) {
                throw [AvmConfigurationException]::new("Duplicate Bicep test token '$name'.")
            }
            $merged[$name] = $source[$name]
        }
    }
    foreach ($name in $merged.psbase.Keys) {
        if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw [AvmConfigurationException]::new(
                "Bicep test token names must start with a letter and contain only letters, digits or underscores: $name")
        }
        if ($merged[$name] -isnot [string]) {
            throw [AvmConfigurationException]::new("Bicep test token '$name' must contain a string.")
        }
        if ($name -in @('subscriptionId', 'managementGroupId', 'tenantId') -and
            ($name -ne 'tenantId' -or -not [string]::IsNullOrWhiteSpace($TenantId))) {
            throw [AvmConfigurationException]::new(
                "Bicep test token '$name' must come from the corresponding explicit scope parameter.")
        }
        if ($values.ContainsKey($name)) {
            throw [AvmConfigurationException]::new("Duplicate Bicep test token '$name'.")
        }
        $value = [string]$merged[$name]
        if ($name -eq 'namePrefix' -and -not [string]::IsNullOrWhiteSpace($RunId)) {
            $value = $value.Replace(
                '#_avmE2eSuffix_#', $RunId.Substring(0, 10),
                [System.StringComparison]::OrdinalIgnoreCase)
            $value = $value.Replace(
                '#_avmE2eRunId_#', $RunId,
                [System.StringComparison]::OrdinalIgnoreCase)
        }
        $values.Add($name, $value)
    }
    if (-not [string]::IsNullOrWhiteSpace($RunId) -and -not $values.ContainsKey('namePrefix')) {
        $values.Add('namePrefix', 'avm' + $RunId.Substring(0, 10))
    }
    return $values
}
