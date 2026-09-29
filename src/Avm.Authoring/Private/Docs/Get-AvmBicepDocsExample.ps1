function Get-AvmBicepDocsExample {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $ToolPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $CompiledTemplate,

        [System.Collections.Generic.Dictionary[string, object]] $CompiledTemplateCache,

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
    $pathComparer = if ($IsWindows) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else { [System.StringComparer]::Ordinal }
    $templates = if ($null -ne $CompiledTemplateCache) {
        $CompiledTemplateCache
    }
    else {
        [System.Collections.Generic.Dictionary[string, object]]::new($pathComparer)
    }
    $currentSource = [System.IO.Path]::GetFullPath((Join-Path $ModulePath 'main.bicep'))
    $templates[$currentSource] = [pscustomobject]@{
        Template = $CompiledTemplate
        Required = [string[]]$RequiredParameters
    }
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
                $targetPath = ''
                for ($index = 0; $index -lt $lines.Count; $index++) {
                    $declaration = [regex]::Match(
                        $lines[$index], "^module testDeployment '(\.\./[^']*main\.bicep)' = ")
                    if ($declaration.Success) {
                        $start = $index
                        $reference = $declaration.Groups[1].Value.Replace(
                            '/', [string][System.IO.Path]::DirectorySeparatorChar)
                        $targetPath = [System.IO.Path]::GetFullPath(
                            [System.IO.Path]::Combine($testFile.DirectoryName, $reference))
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
                $validationError = ''
                if ($start -ge 0) {
                    $relativeTest = [System.IO.Path]::GetRelativePath(
                        $root, $testFile.FullName).Replace('\', '/')
                    $relativeTarget = [System.IO.Path]::GetRelativePath(
                        $root, $targetPath)
                    if ($relativeTarget -eq '..' -or
                        $relativeTarget.StartsWith(
                            "..$([System.IO.Path]::DirectorySeparatorChar)",
                            [System.StringComparison]::Ordinal) -or
                        [System.IO.Path]::IsPathRooted($relativeTarget)) {
                        $validationError = "Bicep test '$relativeTest' references a module outside the repository. Correct the test before generating its README."
                    }
                    else {
                        $relativeTarget = $relativeTarget.Replace('\', '/')
                        if (-not [System.IO.File]::Exists($targetPath)) {
                            $validationError = "Bicep test '$relativeTest' references missing module '$relativeTarget'. Correct the test before generating its README."
                        }
                        else {
                            if (-not $templates.ContainsKey($targetPath)) {
                                $compiledPath = Join-Path (
                                    [System.IO.Path]::GetDirectoryName($targetPath)) 'main.json'
                                $json = if ([System.IO.File]::Exists($compiledPath)) {
                                    try {
                                        $utf8.GetString([System.IO.File]::ReadAllBytes($compiledPath))
                                    }
                                    catch [System.Text.DecoderFallbackException] {
                                        throw [AvmConfigurationException]::new(
                                            "Compiled Bicep module must contain valid UTF-8: $compiledPath")
                                    }
                                }
                                else {
                                    Get-AvmBicepCompiledJson -SourcePath $targetPath -ToolPath $ToolPath
                                }
                                try {
                                    $compiled = $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                                }
                                catch {
                                    throw [AvmConfigurationException]::new(
                                        "Cannot read compiled Bicep module '$compiledPath': $($_.Exception.Message)")
                                }
                                if ($compiled -isnot [System.Collections.IDictionary]) {
                                    throw [AvmConfigurationException]::new(
                                        "Compiled Bicep module must contain a JSON object: $compiledPath")
                                }
                                $required = @(Get-AvmBicepDocsRequiredParameter `
                                        -Template $compiled -SourcePath $compiledPath)
                                $templates[$targetPath] = [pscustomobject]@{
                                    Template = $compiled
                                    Required = [string[]]$required
                                }
                            }
                            $target = $templates[$targetPath]
                            $known = [System.Collections.Generic.HashSet[string]]::new(
                                [System.StringComparer]::Ordinal)
                            $targetParameters = $target.Template['parameters']
                            if ($targetParameters -is [System.Collections.IDictionary]) {
                                foreach ($name in $targetParameters.psbase.Keys) {
                                    $null = $known.Add([string]$name)
                                }
                            }
                            $supplied = [System.Collections.Generic.HashSet[string]]::new(
                                [System.StringComparer]::Ordinal)
                            foreach ($name in $parameters.psbase.Keys) {
                                $null = $supplied.Add([string]$name)
                            }
                            $unknown = @($supplied | Where-Object {
                                    -not $known.Contains($_)
                                } | Sort-Object -Culture 'en-US')
                            $missing = @($target.Required | Where-Object {
                                    -not $supplied.Contains($_)
                                } | Sort-Object -Culture 'en-US')
                            $errors = @()
                            if ($unknown.Count -gt 0) {
                                $errors += "unknown parameters: $($unknown -join ', ')"
                            }
                            if ($missing.Count -gt 0) {
                                $errors += "missing required parameters: $($missing -join ', ')"
                            }
                            if ($errors.Count -gt 0) {
                                $validationError = "Bicep test '$relativeTest' targets '$relativeTarget' with $($errors -join '; '). Correct the test before generating its README."
                            }
                        }
                    }
                }
                $ignorePath = Join-Path $testFile.DirectoryName '.e2eignore'
                $ignore = if ([System.IO.File]::Exists($ignorePath)) {
                    $utf8.GetString([System.IO.File]::ReadAllBytes($ignorePath)).Trim()
                }
                else { '' }
                $fragments = if ($start -ge 0 -and $validationError -eq '') {
                    ConvertTo-AvmBicepDocsExampleParameter -Parameters $parameters `
                        -RequiredParameters $templates[$targetPath].Required
                }
                else { $null }
                $value = [pscustomobject]@{
                    IsModule           = $start -ge 0
                    Parameters         = $parameters
                    InvalidReason      = $validationError
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
