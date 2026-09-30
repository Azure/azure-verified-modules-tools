function Test-AvmModuleInitializationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Plan
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase }
    else { [System.StringComparison]::Ordinal }
    $comparer = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase }
    else { [System.StringComparer]::Ordinal }
    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $rootPrefix = $rootPath.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $targets = [System.Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($item in $Plan) {
        if (-not $item.Path -or $null -eq $item.Content) {
            throw [System.ArgumentException]::new('Each initialization file needs a path and content.')
        }
        $target = [System.IO.Path]::GetFullPath([string]$item.Path)
        if (-not $target.StartsWith($rootPrefix, $comparison)) {
            throw [System.ArgumentException]::new("Initialization file is outside the module: $target")
        }
        if (-not $targets.Add($target)) {
            throw [System.ArgumentException]::new("Initialization file appears more than once: $target")
        }
        $segments = [System.IO.Path]::GetRelativePath($rootPath, $target) -split '[\\/]'
        $directory = $rootPath
        for ($index = 0; $index -lt $segments.Count - 1; $index++) {
            $segment = $segments[$index]
            if (Test-Path -LiteralPath $directory -PathType Container) {
                $candidates = @(Get-ChildItem -LiteralPath $directory -Force | Where-Object { $_.Name -ieq $segment })
                if ($candidates.Count -gt 0 -and
                    ($candidates.Count -ne 1 -or -not $candidates[0].PSIsContainer -or $candidates[0].Name -cne $segment)) {
                    throw [System.ArgumentException]::new("Scaffold directory must use exact casing: $(Join-Path $directory $segment)")
                }
            }
            $directory = Join-Path -Path $directory -ChildPath $segment
        }
        if ($null -eq $item.Original -and (Test-Path -LiteralPath $target)) {
            throw [System.IO.IOException]::new("Initialization will not overwrite an existing path: $target")
        }
        if ($null -ne $item.Original -and -not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw [System.IO.IOException]::new("Source disappeared during initialization: $target")
        }
        $null = Get-AvmExistingDirectory -Path (Split-Path -Path $target -Parent)
    }
}
