function Get-AvmBicepCiParameter {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary] $TemplateParameters,

        [System.Collections.IDictionary] $TemplateDefinitions = @{},

        [System.Collections.IDictionary] $Variables = @{},

        [System.Collections.IDictionary] $Secrets = @{},

        [string] $KeyVaultName
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $names = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $TemplateParameters.psbase.Keys) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
            -not $names.TryAdd($name, $name)) {
            throw [AvmConfigurationException]::new('Template parameter names must be distinct, nonempty strings ignoring case.')
        }
    }
    $selected = @{}
    foreach ($source in @(
            @{ Name = 'variables'; Values = $Variables; Secret = $false }
            @{ Name = 'secrets'; Values = $Secrets; Secret = $true }
        )) {
        $aliases = @{}
        foreach ($key in $source.Values.psbase.Keys) {
            if ($key -isnot [string] -or $key -ieq 'CI_KEY_VAULT_NAME') { continue }
            $name = if ($key.StartsWith('CI__', [System.StringComparison]::OrdinalIgnoreCase)) {
                $key.Substring(4)
            }
            elseif ($key.StartsWith('CI_', [System.StringComparison]::OrdinalIgnoreCase)) {
                $key.Substring(3).Replace('_', '')
            }
            else { continue }
            if (-not $names.ContainsKey($name)) { continue }
            $name = $names[$name]
            if (-not $aliases.ContainsKey($name)) { $aliases[$name] = @() }
            $aliases[$name] += $key
        }
        foreach ($name in $aliases.psbase.Keys) {
            $preferred = @($aliases[$name] | Where-Object {
                    -not $_.StartsWith('CI__', [System.StringComparison]::OrdinalIgnoreCase)
                })
            if ($preferred.Count -eq 0) { $preferred = @($aliases[$name]) }
            if ($preferred.Count -ne 1) {
                throw [AvmConfigurationException]::new(
                    "Multiple CI $($source.Name) names in the preferred prefix target parameter '$name'.")
            }
            $selected[$name] = @{
                Name   = $preferred[0]
                Value  = $source.Values[$preferred[0]]
                Secret = $source.Secret
            }
        }
    }
    $result = @{}
    foreach ($name in $selected.psbase.Keys) {
        $entry = $selected[$name]
        $value = $entry.Value
        if ($value -isnot [string]) {
            throw [AvmConfigurationException]::new("CI value for parameter '$name' must be a string.")
        }
        $definition = $TemplateParameters[$name]
        $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        while ($definition -is [System.Collections.IDictionary] -and
            -not $definition['type'] -and $definition.Contains('$ref')) {
            $reference = $definition['$ref']
            if ($reference -isnot [string] -or
                -not $reference.StartsWith('#/definitions/', [System.StringComparison]::Ordinal)) {
                throw [AvmConfigurationException]::new("Parameter '$name' has an unsupported type reference.")
            }
            $typeName = $reference.Substring('#/definitions/'.Length).Replace('~1', '/').Replace('~0', '~')
            if (-not $visited.Add($typeName) -or -not $TemplateDefinitions.Contains($typeName)) {
                throw [AvmConfigurationException]::new("Parameter '$name' has an unresolved or circular type reference.")
            }
            $definition = $TemplateDefinitions[$typeName]
        }
        $type = Get-AvmPropertyValue -InputObject $definition -Name 'type'
        if ($entry.Secret -and $type -notin @('secureString', 'secureObject')) {
            Write-AvmLog -Level Warning -Message "CI secret '$($entry.Name)' targets non-secure parameter '$name'."
        }
        switch ($type) {
            'string' { $result[$name] = $value }
            'secureString' {
                $secureValue = [System.Security.SecureString]::new()
                foreach ($character in $value.ToCharArray()) { $secureValue.AppendChar($character) }
                $secureValue.MakeReadOnly()
                $result[$name] = $secureValue
            }
            { $_ -in @('int', 'bool', 'array', 'object', 'secureObject') } {
                try {
                    $converted = ConvertFrom-Json -InputObject $value -AsHashtable -NoEnumerate -ErrorAction Stop
                }
                catch [System.ArgumentException] {
                    throw [AvmConfigurationException]::new("CI parameter '$name' must be JSON of type '$type'.")
                }
                $valid = switch ($type) {
                    'int' { $converted -is [int] -or $converted -is [long] }
                    'bool' { $converted -is [bool] }
                    'array' { $converted -is [array] }
                    default { $converted -is [System.Collections.IDictionary] }
                }
                if (-not $valid) {
                    throw [AvmConfigurationException]::new("CI parameter '$name' must be JSON of type '$type'.")
                }
                $result[$name] = $converted
            }
            default {
                throw [AvmConfigurationException]::new("Parameter '$name' has an unsupported CI parameter type.")
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($KeyVaultName) -and
        $result.psbase.Count -lt $names.Count) {
        Write-AvmLog -Level Warning -Message 'CI Key Vault inputs are deprecated; prefer CI-prefixed variables or secrets.'
        foreach ($secret in Get-AzKeyVaultSecret -VaultName $KeyVaultName -ErrorAction Stop) {
            if ($secret.Name -notmatch '^CI-.+') { continue }
            $name = $secret.Name.Substring(3)
            if (-not $names.ContainsKey($name) -or $result.ContainsKey($name)) { continue }
            $value = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secret.Name -ErrorAction Stop
            if ($value.SecretValue -isnot [System.Security.SecureString]) {
                throw [AvmProcessException]::new("Key Vault did not return a secure value for CI parameter '$name'.")
            }
            $result[$names[$name]] = $value.SecretValue
        }
    }
    return $result
}
