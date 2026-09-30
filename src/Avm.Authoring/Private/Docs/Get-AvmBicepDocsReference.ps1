function Get-AvmBicepDocsReference {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $module = [System.IO.Path]::GetFullPath($ModulePath)
    $visited = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $remote = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $local = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push((Join-Path $module 'main.bicep'))
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)

    while ($pending.Count -gt 0) {
        $sourcePath = $pending.Pop()
        if (-not $visited.Add($sourcePath)) {
            continue
        }
        if (-not [System.IO.File]::Exists($sourcePath)) {
            throw [AvmConfigurationException]::new(
                "Bicep documentation references a missing local source: $sourcePath")
        }
        $file = Get-Item -LiteralPath $sourcePath -Force
        if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw [AvmConfigurationException]::new(
                "Bicep documentation does not follow linked source files: $sourcePath")
        }
        $parent = $file.Directory
        while ($null -ne $parent -and $parent.FullName -ne $root) {
            if ($parent.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw [AvmConfigurationException]::new(
                    "Bicep documentation does not follow linked source directories: $($parent.FullName)")
            }
            $parent = $parent.Parent
        }
        try {
            $content = $utf8.GetString([System.IO.File]::ReadAllBytes($sourcePath))
        }
        catch [System.Text.DecoderFallbackException] {
            throw [AvmConfigurationException]::new(
                "Bicep source must be valid UTF-8: $sourcePath")
        }
        $sourceMatches = [regex]::Matches(
            $content, '(?m)^[ \t]*(?<kind>module|import)\b[^\r\n''"]*[''"](?<path>[^''"\r\n]+)[''"]')
        foreach ($sourceMatch in $sourceMatches) {
            $reference = $sourceMatch.Groups['path'].Value
            if ($reference -match '^(?:br|ts)(?:/[^:]+)?:') {
                $null = $remote.Add($reference)
                continue
            }
            if (-not $reference.EndsWith('.bicep', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $target = [System.IO.Path]::GetFullPath(
                (Join-Path -Path (Split-Path $sourcePath -Parent) -ChildPath $reference))
            $relative = [System.IO.Path]::GetRelativePath($root, $target)
            if ($relative -eq '..' -or
                $relative.StartsWith(('..' + [System.IO.Path]::DirectorySeparatorChar),
                    [System.StringComparison]::Ordinal) -or
                [System.IO.Path]::IsPathRooted($relative)) {
                throw [AvmConfigurationException]::new(
                    "Bicep documentation cannot follow a reference outside the repository: $reference")
            }
            if ($sourceMatch.Groups['kind'].Value -ne 'module') {
                continue
            }
            $pending.Push($target)
            if ([System.IO.Path]::GetFileName($target) -ceq 'main.bicep' -and
                -not $target.StartsWith(
                    ($module.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
                    [System.IO.Path]::DirectorySeparatorChar),
                    [System.StringComparison]::OrdinalIgnoreCase) -and
                $target -cne (Join-Path $module 'main.bicep')) {
                $null = $local.Add(
                    [System.IO.Path]::GetDirectoryName($relative).Replace('\', '/'))
            }
        }
    }

    $references = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @($local | Sort-Object -Culture 'en-US')) {
        $references.Add([pscustomobject]@{ Path = $path; Kind = 'Local' })
    }
    foreach ($path in @($remote | Sort-Object -Culture 'en-US')) {
        $references.Add([pscustomobject]@{ Path = $path; Kind = 'Remote' })
    }
    return $references.ToArray()
}
