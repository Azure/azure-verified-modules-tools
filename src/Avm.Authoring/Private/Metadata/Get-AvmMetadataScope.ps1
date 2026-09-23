function Get-AvmMetadataScope {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][pscustomobject] $Context)

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $scopes = [System.Collections.Generic.List[object]]::new()
    $root = [System.IO.Path]::GetFullPath($Context.Root)
    $excluded = @('examples', 'tests', 'test', 'modules', 'build', 'out', 'dist', 'node_modules')
    if ($Context.Ecosystem -eq 'terraform') {
        $scopes.Add([pscustomobject]@{ Path = $root; ChildModule = $false })
        $childrenPath = Join-Path $root 'modules'
        $pending = [System.Collections.Generic.Queue[string]]::new()
        if (Test-Path -LiteralPath $childrenPath -PathType Container) {
            $pending.Enqueue($childrenPath)
        }
        while ($pending.Count -gt 0) {
            $path = $pending.Dequeue()
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw [System.ArgumentException]::new('Metadata checks do not traverse a linked modules directory.')
            }
            $items = @(Get-ChildItem -LiteralPath $path -Force)
            if ($path -cne $childrenPath -and @($items | Where-Object {
                        (-not $_.PSIsContainer -and $_.Name -cmatch '\.tf(\.json)?$') -or $_.Name -ieq 'metadata.json'
                    }).Count -gt 0) {
                $scopes.Add([pscustomobject]@{ Path = $path; ChildModule = $true })
            }
            foreach ($child in $items | Where-Object { $_.PSIsContainer } | Sort-Object Name -CaseSensitive) {
                if ($child.Name.StartsWith('.') -or ($child.Name -in $excluded -and $child.Name -ne 'modules')) {
                    continue
                }
                $pending.Enqueue($child.FullName)
            }
        }
        return $scopes.ToArray()
    }

    $pending = [System.Collections.Generic.Queue[string]]::new()
    if ($Context.Kind -eq 'bicep-monorepo') {
        foreach ($kind in @('res', 'ptn', 'utl')) {
            $path = Join-Path -Path (Join-Path -Path $root -ChildPath 'avm') -ChildPath $kind
            if (Test-Path -LiteralPath $path -PathType Container) {
                $pending.Enqueue($path)
            }
        }
    }
    else {
        $pending.Enqueue($root)
    }
    while ($pending.Count -gt 0) {
        $path = $pending.Dequeue()
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw [System.ArgumentException]::new("Metadata checks do not traverse linked module paths: $path")
        }
        $items = @(Get-ChildItem -LiteralPath $path -Force)
        $hasModule = @($items | Where-Object { -not $_.PSIsContainer -and $_.Name -ieq 'main.bicep' }).Count -gt 0
        $hasMetadata = @($items | Where-Object { $_.Name -ieq 'metadata.json' }).Count -gt 0
        if ($hasModule -or $hasMetadata -or ($path -ceq $root -and $Context.Kind -ne 'bicep-monorepo')) {
            $modulePath = [regex]::Match($path, '(?:^|[\\/])avm[\\/](res|ptn|utl)[\\/][^\\/]+[\\/][^\\/]+(?<child>[\\/].+)?$')
            $isChild = if ($modulePath.Success) { $modulePath.Groups['child'].Success } else { $path -cne $root }
            $scopes.Add([pscustomobject]@{ Path = $path; ChildModule = $isChild })
        }
        foreach ($directory in $items | Where-Object { $_.PSIsContainer } | Sort-Object Name -CaseSensitive) {
            if (-not $directory.Name.StartsWith('.') -and $directory.Name -notin $excluded) {
                $pending.Enqueue($directory.FullName)
            }
        }
    }
    return $scopes.ToArray()
}
