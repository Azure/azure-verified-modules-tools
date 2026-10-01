function New-AvmBicepTestParameterFile {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $DestinationPath,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, string]] $Tokens,

        [string] $ParameterFile,

        [System.Collections.IDictionary] $Parameters = @{}
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not [string]::IsNullOrWhiteSpace($ParameterFile) -and $Parameters.Count -gt 0) {
        throw [AvmConfigurationException]::new('Use either -ParameterFile or -Parameters, not both.')
    }
    if ([string]::IsNullOrWhiteSpace($ParameterFile) -and $Parameters.Count -eq 0) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($ParameterFile)) {
        $path = if ([System.IO.Path]::IsPathRooted($ParameterFile)) {
            $ParameterFile
        }
        else {
            Join-Path $Root $ParameterFile
        }
        if ([System.IO.Path]::GetExtension($path) -cne '.json' -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw [AvmConfigurationException]::new(
                "Bicep test parameter file must be an existing JSON file: $path")
        }
        $content = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $true))
    }
    else {
        $parameterValues = [ordered]@{}
        foreach ($name in $Parameters.Keys) {
            if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) {
                throw [AvmConfigurationException]::new('Bicep test parameter names must be nonempty strings.')
            }
            if ($Parameters[$name] -is [System.Security.SecureString]) {
                throw [AvmConfigurationException]::new(
                    "Bicep test parameter '$name' cannot be a SecureString in a plaintext ARM parameter file.")
            }
            $parameterValues[$name] = @{ value = $Parameters[$name] }
        }
        $content = [ordered]@{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = $parameterValues
        } | ConvertTo-Json -Depth 80 -Compress -ErrorAction Stop
        $path = '<PowerShell parameters>'
    }

    $content = Resolve-AvmBicepTestToken -Content $content -SourcePath $path -Tokens $Tokens
    $parsed = $content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($parsed -isnot [System.Collections.IDictionary] -or
        $parsed['parameters'] -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new(
            "Bicep test parameter file must contain an ARM parameters object: $path")
    }
    foreach ($name in $parsed['parameters'].Keys) {
        $parameter = $parsed['parameters'][$name]
        if ($parameter -isnot [System.Collections.IDictionary] -or
            (-not $parameter.Contains('value') -and -not $parameter.Contains('reference'))) {
            throw [AvmConfigurationException]::new(
                "Bicep test parameter '$name' must specify value or reference: $path")
        }
    }
    if (-not $PSCmdlet.ShouldProcess($DestinationPath, 'Write temporary ARM test parameters')) {
        throw [AvmConfigurationException]::new(
            "Temporary ARM test parameter creation was declined: $DestinationPath")
    }
    [System.IO.File]::WriteAllText($DestinationPath, $content, [System.Text.UTF8Encoding]::new($false))
    return $DestinationPath
}
