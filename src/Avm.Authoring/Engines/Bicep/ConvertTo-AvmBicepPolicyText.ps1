function ConvertTo-AvmBicepPolicyText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Tokens
    )

    Set-StrictMode -Version 3.0
    $result = $Text
    foreach ($match in [regex]::Matches($Text, '#_(?<name>[^#\r\n]+?)_#')) {
        $name = $match.Groups['name'].Value
        if ($name -match '(?i)(?:password|secret|credential|(?:private|access|account|api|storage)[_-]?key|connection[_-]?string|sas[_-]?token)') {
            throw [AvmConfigurationException]::new(
                "PSRule cannot stage sensitive token '$name'. Use a non-sensitive test value.")
        }
        if (-not $Tokens.Contains($name) -or
            [string]::IsNullOrWhiteSpace([string]$Tokens[$name])) {
            $source = switch ($name) {
                'subscriptionId' { 'VALIDATE_SUBSCRIPTION_ID' }
                'tenantId' { 'VALIDATE_TENANT_ID' }
                'managementGroupId' { 'VALIDATE_MANAGEMENT_GROUP_ID or ARM_MGMTGROUP_ID' }
                'namePrefix' { 'localToken_namePrefix or TOKEN_NAMEPREFIX' }
                default { "localToken_$name" }
            }
            throw [AvmConfigurationException]::new(
                "PSRule token '$name' is missing; set $source before running the check.")
        }
        $result = $result.Replace($match.Value, [string]$Tokens[$name])
    }
    if ($result.Contains('#_', [System.StringComparison]::Ordinal)) {
        throw [AvmConfigurationException]::new(
            'PSRule token replacement left an unresolved token in a referenced file.')
    }
    return $result
}
