function Get-AvmBicepTestSubscriptionTag {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $ModulePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $modulePattern = '\Aavm/(res|ptn|utl)/[a-z0-9]+(?:-[a-z0-9]+)*(?:/[a-z0-9]+(?:-[a-z0-9]+)*)+\z'
    if ($ModulePath -cnotmatch $modulePattern) {
        throw [AvmConfigurationException]::new('Reservation ModulePath must be an exact canonical avm/res, avm/ptn, or avm/utl module path.')
    }
    $fileName = '.reserved-test-subscriptions.json'
    $entries = @(Get-ChildItem -LiteralPath $RepositoryRoot -Force -ErrorAction Stop |
            Where-Object { $_.Name -ieq $fileName })
    if ($entries.Count -ne 1 -or $entries[0].Name -cne $fileName -or $entries[0].PSIsContainer -or
        ($entries[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw [AvmConfigurationException]::new("The root $fileName must be a regular file with exact casing.")
    }
    if ($entries[0].Length -gt 64KB) {
        throw [AvmConfigurationException]::new("The root $fileName must not exceed 64 KiB.")
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($entries[0].FullName)
        if ($bytes.Length -gt 64KB) {
            throw [AvmConfigurationException]::new("The root $fileName must not exceed 64 KiB.")
        }
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $document = [System.Text.Json.JsonDocument]::Parse($text)
    }
    catch [System.IO.IOException], [System.UnauthorizedAccessException],
    [System.Text.DecoderFallbackException], [System.Text.Json.JsonException] {
        throw [AvmConfigurationException]::new("The root $fileName must contain valid UTF-8 JSON.")
    }
    try {
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw [AvmConfigurationException]::new("The root $fileName must contain a JSON object.")
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $tag = 'General'
        foreach ($property in $document.RootElement.EnumerateObject()) {
            if ($property.Name -cnotmatch $modulePattern -or -not $seen.Add($property.Name)) {
                throw [AvmConfigurationException]::new("The root $fileName must contain unique canonical module paths.")
            }
            if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                $property.Value.GetString().Length -gt 64 -or
                $property.Value.GetString() -cnotmatch '\A[A-Za-z0-9]+(?:[ -][A-Za-z0-9]+)*\z') {
                throw [AvmConfigurationException]::new("The root $fileName must contain valid subscription tag strings of at most 64 characters.")
            }
            if ($property.Name -ceq $ModulePath) { $tag = $property.Value.GetString() }
        }
        return $tag
    }
    finally {
        $document.Dispose()
    }
}
