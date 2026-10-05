function ConvertFrom-TransferJson {
    param([string] $Text)

    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Text, [Text.Json.JsonDocumentOptions]@{ MaxDepth = 100 })
        $pending = [Collections.Generic.Stack[Text.Json.JsonElement]]::new()
        $pending.Push($document.RootElement)
        while ($pending.Count) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw 'Duplicate private JSON property.' }
                    $pending.Push($property.Value)
                }
            } elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) { $pending.Push($item) }
            }
        }
        return ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 100 -NoEnumerate -ErrorAction Stop
    }
    catch { throw 'Invalid private migration JSON; its contents are not logged.' }
    finally { if ($null -ne $document) { $document.Dispose() } }
}

function Read-TransferImage {
    param([string] $Path)

    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xfeff)
        $state = ConvertFrom-TransferJson $text
    }
    catch {
        throw 'Invalid private state JSON; its contents are not logged.'
    }
    $lineage = [guid]::Empty
    if ($state -isnot [System.Collections.IDictionary] -or $state['version'] -ne 4 -or
        $state['serial'] -isnot [long] -or $state['serial'] -lt 0 -or
        -not [guid]::TryParseExact([string]$state['lineage'], 'D', [ref]$lineage) -or $lineage -eq [guid]::Empty -or
        $state['resources'] -isnot [System.Collections.IList] -or $state['outputs'] -isnot [System.Collections.IDictionary]) {
        throw 'State inspection requires a valid version-4 snapshot with serial, lineage, resources, and outputs.'
    }
    foreach ($resource in $state['resources']) {
        if ($resource -isnot [System.Collections.IDictionary] -or $resource['mode'] -cnotin @('managed', 'data') -or
            $resource['instances'] -isnot [System.Collections.IList] -or $resource['instances'].Count -eq 0) {
            throw 'An empty or unrecognized resource entry requires operator review.'
        }
        $indexes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($instance in $resource['instances']) {
            if ($instance -isnot [System.Collections.IDictionary] -or $instance['attributes'] -isnot [System.Collections.IDictionary] -or
                $instance.Contains('deposed') -or $instance.Contains('status')) {
                throw 'Deposed, tainted, or unrecognized instances require operator review before transfer.'
            }
            if (-not $indexes.Add((ConvertTo-Json -InputObject $instance['index_key'] -Compress))) {
                throw 'Duplicate instance index requires operator review before transfer.'
            }
            if ($resource['mode'] -ceq 'managed' -and [string]::IsNullOrWhiteSpace([string]$instance['attributes']['id'])) {
                throw 'A managed instance without its resource ID requires operator review.'
            }
        }
    }
    return @{
        State = $state
        Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    }
}

function Test-TransferValueEqual {
    param($Actual, $Expected)

    return [Text.Json.Nodes.JsonNode]::DeepEquals(
        [Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject $Actual -Depth 100 -Compress)),
        [Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject $Expected -Depth 100 -Compress))
    )
}

function Assert-TransferValueEqual {
    param($Actual, $Expected, [string] $Label)

    if (-not (Test-TransferValueEqual $Actual $Expected)) {
        throw "$Label changed unexpectedly; no state image is approved for publication."
    }
}

function Get-TransferResourceKey {
    param([System.Collections.IDictionary] $Resource)
    return "$($Resource['module'])|$($Resource['mode'])|$($Resource['type'])|$($Resource['name'])"
}
