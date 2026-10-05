function Resolve-AvmBicepTestToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content,

        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, string]] $Tokens,

        [switch] $DeferResourceLocation
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    foreach ($entry in $Tokens.GetEnumerator()) {
        # Encode only the interior of a JSON string so token values cannot break the ARM payload.
        $encoded = ConvertTo-Json -InputObject ([string]$entry.Value) -Compress
        $Content = $Content.Replace(
            "#_$($entry.Key)_#", $encoded.Substring(1, $encoded.Length - 2),
            [System.StringComparison]::OrdinalIgnoreCase)
    }
    $unresolved = @([regex]::Matches($Content, '#_([A-Za-z][A-Za-z0-9_]*)_#') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique)
    if ($DeferResourceLocation) {
        $unresolved = @($unresolved | Where-Object { $_ -ine 'resourceLocation' })
    }
    if ($unresolved.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            "Unresolved Bicep test tokens in '$SourcePath': $($unresolved -join ', ').")
    }
    return $Content
}
