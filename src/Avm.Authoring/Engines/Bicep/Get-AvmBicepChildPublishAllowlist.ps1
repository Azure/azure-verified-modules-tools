function Get-AvmBicepChildPublishAllowlist {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $relative = 'utilities/pipelines/staticValidation/compliance/helper/child-module-publish-allowed-list.json'
    $path = $RepositoryRoot
    $segments = $relative.Split('/')
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = $segments[$index]
        try {
            $entries = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop |
                    Where-Object { $_.Name -ieq $segment })
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException],
        [System.Management.Automation.ActionPreferenceStopException] {
            throw [AvmConfigurationException]::new(
                "Cannot inspect child publishing allowlist '$relative': $($_.Exception.Message)")
        }
        $isFile = $index -eq $segments.Count - 1
        if ($entries.Count -ne 1 -or $entries[0].Name -cne $segment -or
            $entries[0].PSIsContainer -eq $isFile -or
            ($entries[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new(
                "Child publishing allowlist '$relative' must be a regular file in exact-case, non-linked directories.")
        }
        $path = $entries[0].FullName
    }

    try {
        $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($text)
    }
    catch [System.IO.IOException], [System.UnauthorizedAccessException],
    [System.Text.DecoderFallbackException], [System.Text.Json.JsonException] {
        throw [AvmConfigurationException]::new(
            "Cannot read child publishing allowlist '$relative' as UTF-8 JSON: $($_.Exception.Message)")
    }

    try {
        $values = [System.Text.Json.JsonElement]::new()
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or
            -not $document.RootElement.TryGetProperty('allowed-child-modules', [ref]$values) -or
            $values.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
            throw [AvmConfigurationException]::new(
                "Child publishing allowlist '$relative' must contain an allowed-child-modules array.")
        }
        $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($value in $values.EnumerateArray()) {
            if ($value.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                $value.GetString() -cnotmatch '^avm/(?:res|ptn|utl)(?:/[a-z0-9]+(?:-[a-z0-9]+)*){3,}\z') {
                throw [AvmConfigurationException]::new(
                    "Child publishing allowlist '$relative' contains a noncanonical child module path.")
            }
            if (-not $allowed.Add($value.GetString())) {
                throw [AvmConfigurationException]::new(
                    "Child publishing allowlist '$relative' contains a duplicate child module path.")
            }
        }
        return [pscustomobject]@{ Path = $path; Allowed = $allowed }
    }
    finally {
        $document.Dispose()
    }
}
