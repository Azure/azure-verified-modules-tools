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
        foreach ($segment in @('metadata', '_generator', '')) {
            $cursor = $offset + 1
            $child = $null
            foreach ($property in $element.EnumerateObject()) {
                # JsonDocument owns structure and decoded names; the anchored prefix only locates the original value.
                $match = $prefix.Match($Json, $cursor)
                $raw = $property.Value.GetRawText()
                $start = $match.Index + $match.Length
                if (-not $match.Success -or
                    [string]::CompareOrdinal($Json, $start, $raw, 0, $raw.Length) -ne 0) {
                    throw [AvmConfigurationException]::new("$Description has an uninspectable JSON value span.")
                }
                if ($segment -ceq '' -and $property.Name -cin @('version', 'templateHash')) {
                    if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                        [string]::IsNullOrWhiteSpace($property.Value.GetString())) {
                        throw [AvmConfigurationException]::new(
                            "$Description metadata._generator.$($property.Name) must be a nonempty string.")
                    }
                    $spans.Add([pscustomobject]@{ Start = $start; Length = $raw.Length })
                }
                elseif ($segment -cne '' -and $property.Name -ceq $segment) {
                    $child = $property.Value
                    $offset = $start
                }
                $cursor = $start + $raw.Length
            }
            if ($segment -cne '') {
                if ($null -eq $child) { return $Json }
                if ($child.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                    throw [AvmConfigurationException]::new("$Description $segment must be a JSON object.")
                }
                $element = $child
            }
        }
        if ($spans.Count -ne 2) {
            throw [AvmConfigurationException]::new(
                "$Description metadata._generator requires version and templateHash strings.")
        }
        $text = [System.Text.StringBuilder]::new($Json)
        for ($index = $spans.Count - 1; $index -ge 0; $index--) {
            $span = $spans[$index]
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
