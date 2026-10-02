function Get-AvmBicepPolicySource {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Tokens
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $comparer = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase }
    else { [System.StringComparer]::Ordinal }
    $seen = [System.Collections.Generic.Dictionary[string, object]]::new($comparer)
    $pending = [System.Collections.Generic.Stack[object]]::new()
    $files = [System.Collections.Generic.List[object]]::new()
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $pending.Push([pscustomobject]@{ Path = $Path; Binary = $false })

    while ($pending.Count -gt 0) {
        $candidate = $pending.Pop()
        $sourcePath = [System.IO.Path]::GetFullPath($candidate.Path)
        $existing = if ($seen.ContainsKey($sourcePath)) { $seen[$sourcePath] } else { $null }
        if ($null -ne $existing -and ($candidate.Binary -or $null -ne $existing.Text)) {
            continue
        }
        $relative = [System.IO.Path]::GetRelativePath($root, $sourcePath)
        if ($relative -eq '..' -or
            $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)",
                [System.StringComparison]::Ordinal) -or
            [System.IO.Path]::IsPathRooted($relative)) {
            throw [AvmConfigurationException]::new(
                'A PSRule source references a path outside the repository.')
        }
        if (-not [System.IO.File]::Exists($sourcePath)) {
            throw [AvmConfigurationException]::new(
                'A local PSRule source or its referenced file is missing.')
        }
        $file = Get-Item -LiteralPath $sourcePath -Force
        if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw [AvmConfigurationException]::new(
                'PSRule cannot stage linked source files.')
        }
        $directory = $file.Directory
        while ($null -ne $directory -and -not $comparer.Equals($directory.FullName, $root)) {
            if ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw [AvmConfigurationException]::new(
                    'PSRule cannot stage files through linked directories.')
            }
            $directory = $directory.Parent
        }
        if ($null -eq $directory -or
            ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new(
                'PSRule source is outside the repository or is linked.')
        }

        $bytes = [System.IO.File]::ReadAllBytes($sourcePath)
        $extension = [System.IO.Path]::GetExtension($sourcePath)
        $text = $null
        if (-not $candidate.Binary) {
            try {
                $text = ConvertTo-AvmBicepPolicyText -Text ($utf8.GetString($bytes)) -Tokens $Tokens
            }
            catch [System.Text.DecoderFallbackException] {
                throw [AvmConfigurationException]::new(
                    'PSRule source and text references must contain valid UTF-8.')
            }
        }
        if ($null -ne $existing) {
            $existing.Text = $text
            $existing.Bytes = $null
        }
        else {
            $record = [pscustomobject]@{
                RelativePath = $relative.Replace('\', '/')
                Text         = $text
                Bytes        = if ($null -eq $text) { $bytes } else { $null }
            }
            $files.Add($record)
            $seen[$sourcePath] = $record
        }

        if ($candidate.Binary -or $extension -notin @('.bicep', '.bicepparam')) {
            continue
        }
        $content = Get-AvmBicepCommentFreeSource -Source $text
        $references = @(
            [pscustomobject]@{
                Matches = [regex]::Matches($content, '(?m)^[ \t]*(?:module[ \t]+\w+|using)[ \t\r\n]+''(?<path>[^''\r\n]+)''')
                Binary  = $false
            }
            [pscustomobject]@{
                Matches = [regex]::Matches($content, '(?ms)^[ \t]*import\b.{0,4096}?\bfrom[ \t\r\n]+''(?<path>[^''\r\n]+)''')
                Binary  = $false
            }
            [pscustomobject]@{
                Matches = [regex]::Matches($content, '\b(?:loadJsonContent|loadTextContent|loadYamlContent)\s*\(\s*''(?<path>[^''\r\n]+)''')
                Binary  = $false
            }
            [pscustomobject]@{
                Matches = [regex]::Matches($content, '\bloadFileAsBase64\s*\(\s*''(?<path>[^''\r\n]+)''')
                Binary  = $true
            }
        )
        foreach ($group in $references) {
            foreach ($entry in $group.Matches) {
                $reference = $entry.Groups['path'].Value
                if ($reference -match '^(?:br|ts)(?:/[^:]+)?:') {
                    continue
                }
                if ([System.IO.Path]::IsPathRooted($reference)) {
                    throw [AvmConfigurationException]::new(
                        'PSRule cannot stage absolute local references.')
                }
                $pending.Push([pscustomobject]@{
                        Path   = Join-Path -Path $file.DirectoryName -ChildPath $reference
                        Binary = $group.Binary
                    })
            }
        }

        $ancestor = $file.Directory
        while ($null -ne $ancestor) {
            $config = Join-Path $ancestor.FullName 'bicepconfig.json'
            if ([System.IO.File]::Exists($config)) {
                $pending.Push([pscustomobject]@{ Path = $config; Binary = $false })
                break
            }
            if ($comparer.Equals($ancestor.FullName, $root)) {
                break
            }
            $ancestor = $ancestor.Parent
        }
    }

    return $files.ToArray()
}
