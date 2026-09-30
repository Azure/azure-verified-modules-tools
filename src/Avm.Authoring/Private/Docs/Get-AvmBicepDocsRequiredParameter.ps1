function Get-AvmBicepDocsRequiredParameter {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Template,

        [Parameter(Mandatory)]
        [string] $SourcePath
    )

    Set-StrictMode -Version 3.0

    $parameters = $Template['parameters']
    if ($null -eq $parameters) {
        return
    }
    if ($parameters -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new(
            "Compiled Bicep parameters must be a JSON object in '$SourcePath'.")
    }

    $required = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($parameters.psbase.Keys | Sort-Object -Culture 'en-US')) {
        $parameter = $parameters[$name]
        if ($parameter -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new(
                "Compiled Bicep parameter '$name' must be a JSON object in '$SourcePath'.")
        }
        $definitionNullable = $false
        if ($parameter.ContainsKey('$ref')) {
            $reference = [string]$parameter['$ref']
            if ($reference -cnotmatch '^#/definitions/(.+)$') {
                throw [AvmConfigurationException]::new(
                    "Compiled Bicep parameter '$name' has an invalid definition reference '$reference' in '$SourcePath'.")
            }
            $definitionName = $matches[1].Replace('~1', '/').Replace('~0', '~')
            $definitions = $Template['definitions']
            $definition = if ($definitions -is [System.Collections.IDictionary]) {
                $definitions[$definitionName]
            }
            else { $null }
            if ($definition -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new(
                    "Compiled Bicep parameter '$name' references a missing definition '$definitionName' in '$SourcePath'.")
            }
            $definitionNullable = $definition['nullable'] -eq $true
        }
        if (-not $parameter.ContainsKey('defaultValue') -and
            $parameter['nullable'] -ne $true -and -not $definitionNullable) {
            $required.Add([string]$name)
        }
    }

    return $required.ToArray()
}
