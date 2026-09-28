function Get-AvmBicepDocsExample {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [AllowEmptyCollection()]
        [string[]] $RequiredParameters = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $examples = @{}
    $directory = [System.IO.DirectoryInfo]::new(
        [System.IO.Path]::GetFullPath($ModulePath))
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    while ($null -ne $directory -and $directory.FullName -ne $root) {
        $exampleRoot = Join-Path -Path $directory.FullName -ChildPath 'tests' `
            -AdditionalChildPath 'e2e'
        if ([System.IO.Directory]::Exists($exampleRoot)) {
            $testFiles = @(Get-ChildItem -LiteralPath $exampleRoot -Recurse -File `
                    -Filter 'main.test.bicep' | Sort-Object -Culture 'en-US' -Property FullName)
            foreach ($testFile in $testFiles) {
                $keys = @(
                    [System.IO.Path]::GetRelativePath($directory.FullName, $testFile.FullName).Replace('\', '/'),
                    [System.IO.Path]::GetRelativePath($ModulePath, $testFile.FullName).Replace('\', '/')
                )
                if ($examples.ContainsKey($keys[0]) -and $examples.ContainsKey($keys[1])) {
                    continue
                }
                try {
                    $source = $utf8.GetString([System.IO.File]::ReadAllBytes($testFile.FullName))
                }
                catch [System.Text.DecoderFallbackException] {
                    throw [AvmConfigurationException]::new(
                        "Bicep example must contain valid UTF-8: $($testFile.FullName)")
                }
                $lines = $source.ReplaceLineEndings("`n") -split "`n"
                $start = -1
                for ($index = 0; $index -lt $lines.Count; $index++) {
                    if ($lines[$index] -match "^module testDeployment '\.\./.*main\.bicep' = ") {
                        $start = $index
                        break
                    }
                }
                $parameters = @{}
                if ($start -ge 0) {
                    $end = $start + 1
                    while ($end -lt $lines.Count -and $lines[$end] -notin @('}', '}]', ']')) {
                        $end++
                    }
                    if ($end -ge $lines.Count) {
                        throw [AvmConfigurationException]::new(
                            "Cannot locate the test module end in '$($testFile.FullName)'.")
                    }
                    for ($index = $start + 1; $index -lt $end; $index++) {
                        if ($lines[$index] -notmatch '\s+params:.*') {
                            continue
                        }
                        if ($lines[$index] -match '^\s*params:\s*{\s*}\s*$') {
                            break
                        }
                        $indent = ([regex]::Match($lines[$index], '^(\s+)')).Groups[1].Value.Length
                        $paramsEnd = $index + 1
                        while ($paramsEnd -lt $end -and
                            $lines[$paramsEnd] -notmatch "^\s{$indent}\}(?:\])?\s*$" -and
                            $lines[$paramsEnd] -notmatch "^\s{$indent}\]\s*$") {
                            $paramsEnd++
                        }
                        if ($paramsEnd -ge $end) {
                            throw [AvmConfigurationException]::new(
                                "Cannot locate the Bicep test parameters in '$($testFile.FullName)'.")
                        }
                        $block = if ($paramsEnd -gt $index + 1) {
                            @($lines[($index + 1)..($paramsEnd - 1)] |
                                    ForEach-Object { "  $($_ -replace "^\s{$indent}")" }) -join "`n"
                        }
                        else { '' }
                        $service = [regex]::Match(
                            $source, "(?m)^param serviceShort string = '(.+)'\s*$").Groups[1].Value
                        $block = $block -replace '\$\{serviceShort\}', $service
                        $block = $block -replace '\$\{namePrefix\}[-|\.|_]?', ''
                        $block = $block -replace '(?m):\s*location\s*$', ": '<location>'"
                        $parameters = ConvertFrom-AvmBicepDocsParameterBlock `
                            -Block $block -SourcePath $testFile.FullName
                        break
                    }
                }
                $ignorePath = Join-Path $testFile.DirectoryName '.e2eignore'
                $ignore = if ([System.IO.File]::Exists($ignorePath)) {
                    $utf8.GetString([System.IO.File]::ReadAllBytes($ignorePath)).Trim()
                }
                else { '' }
                $fragments = if ($start -ge 0) {
                    ConvertTo-AvmBicepDocsExampleParameter -Parameters $parameters `
                        -RequiredParameters $RequiredParameters
                }
                else { $null }
                $value = [pscustomobject]@{
                    IsModule           = $start -ge 0
                    Parameters         = $parameters
                    IgnoreReason       = $ignore
                    HasIgnore          = [System.IO.File]::Exists($ignorePath)
                    BicepParameters    = if ($null -ne $fragments) { $fragments.BicepParameters } else { '' }
                    JsonParameters     = if ($null -ne $fragments) { $fragments.JsonParameters } else { '' }
                    BicepParameterFile = if ($null -ne $fragments) { $fragments.BicepParameterFile } else { '' }
                }
                foreach ($key in $keys) {
                    if (-not $examples.ContainsKey($key)) {
                        $examples[$key] = $value
                    }
                }
            }
        }
        if ([System.IO.Path]::GetRelativePath($root, $directory.FullName) -match
            '^avm[/\\](?:res|ptn|utl)[/\\][^/\\]+[/\\][^/\\]+$') {
            break
        }
        $directory = $directory.Parent
    }

    return $examples
}
