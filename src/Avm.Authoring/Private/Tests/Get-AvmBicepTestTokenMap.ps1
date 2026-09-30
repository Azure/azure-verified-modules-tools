function Get-AvmBicepTestTokenMap {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [string] $ManagementGroupId,

        [string] $TokenFile,

        [System.Collections.IDictionary] $Tokens = @{}
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not [string]::IsNullOrWhiteSpace($TokenFile) -and $Tokens.Count -gt 0) {
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
    foreach ($name in $provided.Keys) {
        if ($name -isnot [string] -or $name -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw [AvmConfigurationException]::new(
                "Bicep test token names must start with a letter and contain only letters, digits or underscores: $name")
        }
        if ($provided[$name] -isnot [string]) {
            throw [AvmConfigurationException]::new("Bicep test token '$name' must contain a string.")
        }
        if ($name -in @('subscriptionId', 'managementGroupId')) {
            throw [AvmConfigurationException]::new(
                "Bicep test token '$name' must come from the corresponding explicit scope parameter.")
        }
        if ($values.ContainsKey($name)) {
            throw [AvmConfigurationException]::new("Duplicate Bicep test token '$name'.")
        }
        $values.Add($name, [string]$provided[$name])
    }
    return $values
}
