function Get-AvmBicepCompiledJsonComparisonText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Json,

        [Parameter(Mandatory)]
        [string] $Description
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $document = $null
    try {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 1024
        $parseText = if ($Json[0] -eq [char]0xFEFF) { $Json.Substring(1) } else { $Json }
        $document = [System.Text.Json.JsonDocument]::Parse($parseText, $options)
        $element = $document.RootElement
        if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw [AvmConfigurationException]::new("$Description must be a JSON object.")
        }

        $pending = [System.Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
        $pending.Push($element)
        while ($pending.Count -gt 0) {
            $node = $pending.Pop()
            if ($node.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                foreach ($property in $node.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) {
                        throw [AvmConfigurationException]::new("$Description contains a duplicate JSON property.")
                    }
                    $pending.Push($property.Value)
                }
            }
            elseif ($node.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($item in $node.EnumerateArray()) { $pending.Push($item) }
            }
        }

        $offset = $Json.IndexOf($element.GetRawText(), [System.StringComparison]::Ordinal)
        $spans = [System.Collections.Generic.List[object]]::new()
        $prefix = [regex]::new('\G[ \t\r\n]*,?[ \t\r\n]*"(?:[^"\\]|\\.)*"[ \t\r\n]*:[ \t\r\n]*')
        $arrayPrefix = [regex]::new('\G[ \t\r\n]*,?[ \t\r\n]*')
        $pendingSpans = [System.Collections.Generic.Stack[object]]::new()
        $pendingSpans.Push([pscustomobject]@{ Element = $element; Offset = $offset; Role = 'template'; Nested = $false })
        while ($pendingSpans.Count -gt 0) {
            $entry = $pendingSpans.Pop()
            $element = $entry.Element
            $cursor = $entry.Offset + 1
            if ($entry.Role -ceq 'resources' -and $element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) {
                    $match = $arrayPrefix.Match($Json, $cursor)
                    $raw = $item.GetRawText()
                    $start = $match.Index + $match.Length
                    if (-not $match.Success -or
                        [string]::CompareOrdinal($Json, $start, $raw, 0, $raw.Length) -ne 0) {
                        throw [AvmConfigurationException]::new("$Description has an uninspectable JSON value span.")
                    }
                    $pendingSpans.Push([pscustomobject]@{ Element = $item; Offset = $start; Role = 'resource'; Nested = $entry.Nested })
                    $cursor = $start + $raw.Length
                }
                continue
            }
            if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                if ($entry.Role -cin @('metadata', '_generator')) {
                    throw [AvmConfigurationException]::new("$Description $($entry.Role) must be a JSON object.")
                }
                continue
            }
            if ($entry.Role -ceq 'resource') {
                $type = [System.Text.Json.JsonElement]::new()
                if (-not $element.TryGetProperty('type', [ref]$type) -or
                    $type.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                    $type.GetString() -cne 'Microsoft.Resources/deployments') {
                    continue
                }
            }
            if ($entry.Nested -and $entry.Role -ceq '_generator') {
                $name = [System.Text.Json.JsonElement]::new()
                if ($element.TryGetProperty('name', [ref]$name) -and
                    $name.ValueKind -eq [System.Text.Json.JsonValueKind]::String -and
                    $name.GetString() -cne 'bicep') {
                    continue
                }
            }
            $provenanceCount = 0
            foreach ($property in $element.EnumerateObject()) {
                # JsonDocument owns structure and decoded names; the anchored prefix only locates the original value.
                $match = $prefix.Match($Json, $cursor)
                $raw = $property.Value.GetRawText()
                $start = $match.Index + $match.Length
                if (-not $match.Success -or
                    [string]::CompareOrdinal($Json, $start, $raw, 0, $raw.Length) -ne 0) {
                    throw [AvmConfigurationException]::new("$Description has an uninspectable JSON value span.")
                }
                if ($entry.Role -ceq '_generator' -and $property.Name -cin @('version', 'templateHash')) {
                    if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                        [string]::IsNullOrWhiteSpace($property.Value.GetString())) {
                        throw [AvmConfigurationException]::new(
                            "$Description metadata._generator.$($property.Name) must be a nonempty string.")
                    }
                    $spans.Add([pscustomobject]@{ Start = $start; Length = $raw.Length })
                    $provenanceCount++
                }
                $role = switch -CaseSensitive ($entry.Role) {
                    'template' {
                        if ($property.Name -cin @('metadata', 'resources')) { $property.Name }
                    }
                    'metadata' { if ($property.Name -ceq '_generator') { '_generator' } }
                    'resources' { 'resource' }
                    'resource' { if ($property.Name -ceq 'properties') { 'properties' } }
                    'properties' { if ($property.Name -ceq 'template') { 'template' } }
                }
                if ($null -ne $role) {
                    $pendingSpans.Push([pscustomobject]@{
                            Element = $property.Value
                            Offset  = $start
                            Role    = $role
                            Nested  = $entry.Nested -or $role -ceq 'template'
                        })
                }
                $cursor = $start + $raw.Length
            }
            if ($entry.Role -ceq '_generator' -and $provenanceCount -ne 2) {
                throw [AvmConfigurationException]::new(
                    "$Description metadata._generator requires version and templateHash strings.")
            }
        }
        $text = [System.Text.StringBuilder]::new($Json)
        foreach ($span in ($spans | Sort-Object -Property Start -Descending)) {
            $null = $text.Remove($span.Start, $span.Length).Insert($span.Start, '""')
        }
        return $text.ToString()
    }
    catch [System.Text.Json.JsonException] {
        throw [AvmConfigurationException]::new("$Description contains invalid JSON: $($_.Exception.Message)")
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}
