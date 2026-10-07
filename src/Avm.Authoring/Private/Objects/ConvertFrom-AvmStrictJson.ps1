function ConvertFrom-AvmStrictJson {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary], [object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Json,

        [string] $Description = 'JSON value',

        [switch] $RejectCaseInsensitiveDuplicates,

        [switch] $AllowArray
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $document = $null
    try {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 100
        $document = [System.Text.Json.JsonDocument]::Parse($Json, $options)
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -and
            (-not $AllowArray -or $document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array)) {
            $expected = if ($AllowArray) { 'object or array' } else { 'object' }
            throw [System.ArgumentException]::new("$Description must be a JSON $expected.")
        }

        $pending = [System.Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
        $pending.Push($document.RootElement)
        while ($pending.Count -gt 0) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $comparer = if ($RejectCaseInsensitiveDuplicates) { [System.StringComparer]::OrdinalIgnoreCase }
                else { [System.StringComparer]::Ordinal }
                $names = [System.Collections.Generic.HashSet[string]]::new($comparer)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) {
                        throw [System.ArgumentException]::new("Duplicate JSON property '$($property.Name)'.")
                    }
                    $pending.Push($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) {
                    $pending.Push($item)
                }
            }
        }

        # PowerShell 7.4's ConvertFrom-Json coerces ISO-looking strings to dates.
        $convert = {
            param([System.Text.Json.JsonElement] $Node)
            switch ($Node.ValueKind) {
                ([System.Text.Json.JsonValueKind]::Object) {
                    $value = [System.Management.Automation.OrderedHashtable]::new()
                    foreach ($property in $Node.EnumerateObject()) {
                        $value.Add($property.Name, (& $convert -Node $property.Value))
                    }
                    return $value
                }
                ([System.Text.Json.JsonValueKind]::Array) {
                    $value = [System.Collections.Generic.List[object]]::new()
                    foreach ($item in $Node.EnumerateArray()) {
                        $value.Add((& $convert -Node $item))
                    }
                    return , $value.ToArray()
                }
                ([System.Text.Json.JsonValueKind]::String) { return $Node.GetString() }
                ([System.Text.Json.JsonValueKind]::Number) {
                    $integer = 0L
                    if ($Node.TryGetInt64([ref]$integer)) {
                        return $integer
                    }
                    return $Node.GetDouble()
                }
                ([System.Text.Json.JsonValueKind]::True) { return $true }
                ([System.Text.Json.JsonValueKind]::False) { return $false }
                ([System.Text.Json.JsonValueKind]::Null) { return $null }
            }
        }
        return , (& $convert -Node $document.RootElement)
    }
    catch [System.Text.Json.JsonException] {
        throw [System.ArgumentException]::new("$Description must be strict JSON: $($_.Exception.Message)", $_.Exception)
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
}
