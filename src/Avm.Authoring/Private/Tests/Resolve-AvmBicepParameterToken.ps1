function Resolve-AvmBicepParameterToken {
    [CmdletBinding()]
    [OutputType([object], [object[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object] $Value,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, string]] $Tokens,

        [switch] $DeferResourceLocation,

        [System.Collections.Generic.HashSet[string]] $ReferencedTokens,

        [int] $Depth = 0
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Depth -gt 80) {
        throw [AvmConfigurationException]::new('Bicep parameter nesting exceeds 80 levels.')
    }
    $options = @{
        Tokens = $Tokens; DeferResourceLocation = $DeferResourceLocation
        ReferencedTokens = $ReferencedTokens; Depth = $Depth + 1
    }
    if ($Value -is [string]) {
        if ($null -ne $ReferencedTokens) {
            foreach ($token in [regex]::Matches($Value, '#_(?<name>[A-Za-z][A-Za-z0-9_]*)_#')) {
                $null = $ReferencedTokens.Add($token.Groups['name'].Value)
            }
        }
        $json = ConvertTo-Json -InputObject $Value -Compress
        $resolved = Resolve-AvmBicepTestToken -Content $json -SourcePath '<in-memory parameters>' `
            -Tokens $Tokens -DeferResourceLocation:$DeferResourceLocation
        return ConvertFrom-Json -InputObject $resolved -NoEnumerate -ErrorAction Stop
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = if ($Value -is [hashtable]) { @{} } else { [ordered]@{} }
        foreach ($key in $Value.psbase.Keys) {
            $copy[$key] = Resolve-AvmBicepParameterToken -Value $Value[$key] @options
        }
        return $copy
    }
    if ($Value -is [System.Collections.IList]) {
        $copy = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $Value) {
            $copy.Add((Resolve-AvmBicepParameterToken -Value $entry @options))
        }
        return , $copy.ToArray()
    }
    if ($null -ne $Value -and $Value.GetType() -eq [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = Resolve-AvmBicepParameterToken -Value $property.Value @options
        }
        return [pscustomobject]$copy
    }
    return , $Value
}
