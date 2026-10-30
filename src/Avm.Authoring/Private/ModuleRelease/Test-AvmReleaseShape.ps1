function Test-AvmReleaseShape {
    <#
    .SYNOPSIS
        Check a parsed release-state value against a small structural schema.

    .DESCRIPTION
        Walks the value and the schema together and adds one message to Issues for each problem found. Property names must match exactly, including case. Unknown and missing properties are both problems.

        A schema node is one of these:

        - A string type: 'string', 'text' (non-blank string), 'int' (positive integer), 'bool', 'timestamp' (canonical UTC form), 'sha' (40 lowercase hex characters), 'version' (MAJOR.MINOR.PATCH), 'repo' (owner/name), or 'enum:a|b'. A '?' after the type name, as in 'string?' or 'enum?:a|b', allows null.
        - A dictionary with ArrayOf, holding the schema for each item.
        - A dictionary with Properties, holding an ordered dictionary of property schemas.

        Either dictionary form can set Nullable to allow null.

    .PARAMETER Value
        The value to check.

    .PARAMETER Schema
        The schema node.

    .PARAMETER Path
        The JSON path of the value, used in messages.

    .PARAMETER Issues
        The list that collects the messages.

    .EXAMPLE
        $issues = [System.Collections.Generic.List[string]]::new()
        Test-AvmReleaseShape -Value @{ number = 0 } -Schema @{ Properties = [ordered]@{ number = 'int' } } -Path '$' -Issues $issues

        Adds "$.number: must be a positive integer." to the list.

    .OUTPUTS
        None. Messages are added to Issues.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [object] $Schema,

        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $Issues
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Schema -is [System.Collections.IDictionary]) {
        $nullable = $Schema.Contains('Nullable') -and $Schema['Nullable'] -eq $true
        if ($null -eq $Value) {
            if (-not $nullable) {
                $Issues.Add("${Path}: is required.")
            }
            return
        }

        if ($Schema.Contains('ArrayOf')) {
            if ($Value -is [string] -or $Value -is [System.Collections.IDictionary] -or $Value -isnot [System.Collections.IList]) {
                $Issues.Add("${Path}: must be an array.")
                return
            }
            for ($index = 0; $index -lt $Value.Count; $index++) {
                Test-AvmReleaseShape -Value $Value[$index] -Schema $Schema['ArrayOf'] -Path "$Path[$index]" -Issues $Issues
            }
            return
        }

        if ($Value -isnot [System.Collections.IDictionary]) {
            $Issues.Add("${Path}: must be an object.")
            return
        }
        $expected = @($Schema['Properties'].Keys)
        $actual = @($Value.Keys)
        foreach ($key in $actual) {
            if ($expected -cnotcontains $key) {
                $Issues.Add("${Path}.${key}: is not a known property.")
            }
        }
        foreach ($key in $expected) {
            if ($actual -cnotcontains $key) {
                $Issues.Add("${Path}.${key}: is missing.")
                continue
            }
            Test-AvmReleaseShape -Value $Value[$key] -Schema $Schema['Properties'][$key] -Path "$Path.$key" -Issues $Issues
        }
        return
    }

    $match = [regex]::Match([string]$Schema, '^(?<type>[a-z]+)(?<nullable>\?)?(?::(?<argument>.+))?$')
    if (-not $match.Success) {
        throw [System.ArgumentException]::new("Unknown release schema type '$Schema'.")
    }
    $type = $match.Groups['type'].Value
    if ($null -eq $Value) {
        if (-not $match.Groups['nullable'].Success) {
            $Issues.Add("${Path}: is required.")
        }
        return
    }

    $isString = $Value -is [string]
    switch ($type) {
        'string' {
            if (-not $isString) {
                $Issues.Add("${Path}: must be a string.")
            }
        }
        'text' {
            if (-not $isString -or [string]::IsNullOrWhiteSpace($Value)) {
                $Issues.Add("${Path}: must be a non-empty string.")
            }
        }
        'int' {
            $isInteger = ($Value -is [int] -or $Value -is [long]) -and $Value -ge 1
            if (-not $isInteger) {
                $Issues.Add("${Path}: must be a positive integer.")
            }
        }
        'bool' {
            if ($Value -isnot [bool]) {
                $Issues.Add("${Path}: must be true or false.")
            }
        }
        'timestamp' {
            $valid = $isString -and $Value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            if ($valid) {
                $parsed = [System.DateTimeOffset]::MinValue
                $valid = [System.DateTimeOffset]::TryParseExact($Value, "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref] $parsed)
            }
            if (-not $valid) {
                $Issues.Add("${Path}: must be a UTC timestamp such as 2026-09-07T09:00:00Z.")
            }
        }
        'sha' {
            if (-not $isString -or $Value -cnotmatch '^[0-9a-f]{40}$') {
                $Issues.Add("${Path}: must be a 40-character lowercase commit SHA.")
            }
        }
        'version' {
            if (-not $isString -or $Value -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
                $Issues.Add("${Path}: must be a MAJOR.MINOR.PATCH version.")
            }
        }
        'repo' {
            if (-not $isString -or $Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$') {
                $Issues.Add("${Path}: must be an owner/name repository.")
            }
        }
        'enum' {
            $allowed = $match.Groups['argument'].Value -split '\|'
            if (-not $isString -or $allowed -cnotcontains $Value) {
                $Issues.Add("${Path}: must be one of $($allowed -join ', ').")
            }
        }
        default {
            throw [System.ArgumentException]::new("Unknown release schema type '$Schema'.")
        }
    }
}
