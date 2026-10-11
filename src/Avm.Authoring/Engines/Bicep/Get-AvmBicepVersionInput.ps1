function Get-AvmBicepVersionInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        $Scope
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $entries = @(Get-ChildItem -LiteralPath $Scope.Path -Force -ErrorAction Stop)
    $versions = @($entries | Where-Object { $_.Name -ceq 'version.json' -and -not $_.PSIsContainer })
    if ($versions.Count -eq 0) { return $null }
    $data = @{
        Scope          = $Scope
        IssuePath      = Join-Path $Scope.Path 'version.json'
        Json           = $null
        VersionError   = $null
        ChangelogPath  = Join-Path $Scope.Path 'CHANGELOG.md'
        ChangelogFiles = @($entries | Where-Object { $_.Name -ieq 'CHANGELOG.md' })
        ChangelogError = $null
        Lines          = @()
        Headings       = @()
        Versions       = @()
    }
    if ($versions[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        $data.VersionError = 'version.json must not be a linked file.'
    }
    else {
        try {
            $text = [System.IO.File]::ReadAllText($data.IssuePath, [System.Text.UTF8Encoding]::new($false, $true))
            $document = [System.Text.Json.JsonDocument]::Parse($text)
            try { $data.Json = $document.RootElement.Clone() }
            finally { $document.Dispose() }
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException],
        [System.Text.DecoderFallbackException], [System.Text.Json.JsonException] {
            $data.VersionError = $_.Exception.Message
        }
    }
    if ($data.ChangelogFiles.Count -ne 1 -or $data.ChangelogFiles[0].PSIsContainer -or
        $data.ChangelogFiles[0].Name -cne 'CHANGELOG.md' -or
        ($data.ChangelogFiles[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $data
    }
    try {
        $data.Lines = [System.IO.File]::ReadAllLines($data.ChangelogPath, [System.Text.UTF8Encoding]::new($false, $true))
    }
    catch [System.IO.IOException], [System.UnauthorizedAccessException], [System.Text.DecoderFallbackException] {
        $data.ChangelogError = $_.Exception.Message
        return $data
    }
    $data.Headings = @(for ($index = 0; $index -lt $data.Lines.Count; $index++) {
            $line = $data.Lines[$index]
            if ($line -cnotmatch '^##\s') { continue }
            $heading = [regex]::Match($line, '^## ([0-9]+\.[0-9]+\.[0-9]+)\s*$')
            $parsed = $null
            if ($heading.Success) { $null = [version]::TryParse($heading.Groups[1].Value, [ref]$parsed) }
            @{ Text = $line; Index = $index; IssueLine = $index + 1; Version = $parsed }
        })
    $data.Versions = @($data.Headings | Where-Object { $null -ne $_.Version })
    for ($index = 0; $index -lt $data.Versions.Count; $index++) {
        $entry = $data.Versions[$index]
        $next = if ($index + 1 -lt $data.Versions.Count) { $data.Versions[$index + 1].Index } else { $data.Lines.Count }
        $entry.Previous = if ($index -gt 0) { $data.Versions[$index - 1].Version } else { $null }
        $entry.Sections = @(foreach ($name in @('Changes', 'Breaking Changes')) {
                $positions = @(for ($line = $entry.Index + 1; $line -lt $next; $line++) {
                        if ($data.Lines[$line] -ceq "### $name") { $line }
                    })
                $content = @()
                if ($positions.Count -eq 1) {
                    $content = @(for ($line = $positions[0] + 1; $line -lt $next; $line++) {
                            if ($data.Lines[$line] -cmatch '^###\s') { break }
                            $data.Lines[$line]
                        })
                }
                @{ Name = $name; Positions = $positions; Content = $content }
            })
    }
    return $data
}
