function ConvertFrom-AvmTerraformModuleManifest {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Payload,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [string[]] $TestFiles = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    try {
        $manifest = ConvertFrom-Json -InputObject $Payload -AsHashtable -ErrorAction Stop
    }
    catch [System.ArgumentException] {
        throw [AvmConfigurationException]::new(
            "Terraform's installed module manifest is not valid JSON: $($_.Exception.Message)")
    }
    if ($manifest -isnot [System.Collections.IDictionary] -or
        -not $manifest.Contains('Modules') -or $manifest.Modules -isnot [array]) {
        throw [AvmConfigurationException]::new(
            "Terraform's installed module manifest must contain a Modules array.")
    }

    $records = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($record in $manifest.Modules) {
        if ($record -isnot [System.Collections.IDictionary] -or
            -not $record.Contains('Key') -or $record.Key -isnot [string] -or
            -not $record.Contains('Dir') -or $record.Dir -isnot [string] -or
            [string]::IsNullOrWhiteSpace($record.Dir)) {
            throw [AvmConfigurationException]::new(
                "Terraform's installed module manifest contains an invalid Key or Dir.")
        }
        if ($records.ContainsKey($record.Key)) {
            throw [AvmConfigurationException]::new(
                "Terraform's installed module manifest repeats module key '$($record.Key)'.")
        }
        $records.Add($record.Key, $record.Dir)
    }
    if (-not $records.ContainsKey('')) {
        throw [AvmConfigurationException]::new(
            "Terraform's installed module manifest has no root module record.")
    }

    $testPrefixes = @(
        foreach ($testFile in $TestFiles) {
            $testName = $testFile.Replace('\', '/') -creplace '\.tftest\.(hcl|json)$', ''
            'test.' + $testName + '.'
        }
    )
    $keys = [string[]]@($records.Keys)
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $reachable = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $directories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $null = $reachable.Add('')
    foreach ($key in $keys) {
        if ($key -ceq '') { continue }
        $normalizedKey = $key.Replace('\', '/')
        if ($testPrefixes | Where-Object { $normalizedKey.StartsWith($_, [System.StringComparison]::Ordinal) }) { continue }
        $separator = $key.LastIndexOf('.')
        $parentKey = if ($separator -lt 0) { '' } else { $key.Substring(0, $separator) }
        # Test-only modules have synthetic parents outside the example's module tree.
        if (-not $reachable.Contains($parentKey)) { continue }

        try {
            $directory = [System.IO.Path]::GetFullPath($records[$key], $WorkingDirectory)
        }
        catch [System.ArgumentException] {
            throw [AvmConfigurationException]::new(
                "Terraform's installed module manifest has an invalid directory for '$key': $($_.Exception.Message)")
        }
        $null = $directories.Add([System.IO.Path]::TrimEndingDirectorySeparator($directory))
        $null = $reachable.Add($key)
    }

    $result = [string[]]@($directories)
    [System.Array]::Sort($result, [System.StringComparer]::Ordinal)
    return $result
}
