function ConvertFrom-AvmBicepTestSubscriptionPool {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $PoolJson
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $document = $null
    try {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 3
        $document = [System.Text.Json.JsonDocument]::Parse($PoolJson, $options)
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or
            $document.RootElement.GetArrayLength() -eq 0) {
            throw [AvmConfigurationException]::new('The test subscription pool must be a nonempty JSON array.')
        }
        $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $document.RootElement.EnumerateArray()) {
            if ($entry.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                throw [AvmConfigurationException]::new('Test subscriptions must be objects with id, name, and an optional tag.')
            }
            $properties = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $entry.EnumerateObject()) {
                if (-not $properties.Add($property.Name) -or $property.Name -cnotin @('id', 'name', 'tag')) {
                    throw [AvmConfigurationException]::new('Test subscriptions must not contain duplicate, miscased, or unknown properties.')
                }
            }
            $idValue = [System.Text.Json.JsonElement]::new()
            $nameValue = [System.Text.Json.JsonElement]::new()
            if (-not $entry.TryGetProperty('id', [ref]$idValue) -or
                -not $entry.TryGetProperty('name', [ref]$nameValue) -or
                $idValue.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                $nameValue.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                throw [AvmConfigurationException]::new('Test subscriptions must contain string id and name properties.')
            }
            $id = $idValue.GetString()
            $name = $nameValue.GetString()
            $guid = [guid]::Empty
            if ($id.Length -ne 36 -or -not [guid]::TryParseExact($id, 'D', [ref]$guid) -or
                $guid -eq [guid]::Empty -or -not $ids.Add($guid.ToString('D'))) {
                throw [AvmConfigurationException]::new('Test subscriptions must contain distinct, nonempty subscription GUIDs.')
            }
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\x00-\x1f\x7f]') {
                throw [AvmConfigurationException]::new('Test subscription names must be nonempty and free of control characters.')
            }
            $tag = 'General'
            $tagValue = [System.Text.Json.JsonElement]::new()
            if ($entry.TryGetProperty('tag', [ref]$tagValue)) {
                if ($tagValue.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                    $tagValue.GetString().Length -gt 64 -or
                    $tagValue.GetString() -cnotmatch '\A[A-Za-z0-9]+(?:[ -][A-Za-z0-9]+)*\z') {
                    throw [AvmConfigurationException]::new('A test subscription tag must be a string of at most 64 alphanumeric characters separated by single spaces or hyphens.')
                }
                $tag = $tagValue.GetString()
            }
            $key = [System.Security.Cryptography.SHA256]::HashData(
                [System.Text.Encoding]::UTF8.GetBytes($guid.ToString('D')))
            $records.Add([pscustomobject]@{
                    SubscriptionId = $id
                    Name           = $name
                    Tag            = $tag
                    Index          = $records.Count
                    Key            = [Convert]::ToHexString($key).ToLowerInvariant()
                })
        }
        return $records.ToArray()
    }
    catch [System.Text.Json.JsonException] {
        throw [AvmConfigurationException]::new('The test subscription pool must be strict JSON containing id/name objects with optional tags.')
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}
