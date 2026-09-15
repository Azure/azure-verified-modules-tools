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
        if (Test-Path -LiteralPath $childrenPath -PathType Container) {
            if ((Get-Item -LiteralPath $childrenPath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw [System.ArgumentException]::new('Metadata checks do not traverse a linked modules directory.')
            }
            foreach ($child in Get-ChildItem -LiteralPath $childrenPath -Directory -Force | Sort-Object Name -CaseSensitive) {
                if ($child.Name.StartsWith('.') -or $child.Name -in $excluded) {
                    continue
                }
                if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw [System.ArgumentException]::new("Metadata checks do not traverse linked module paths: $($child.FullName)")
                }
                $files = @(Get-ChildItem -LiteralPath $child.FullName -File -Force)
                if (@($files | Where-Object { $_.Name -cmatch '\.tf(\.json)?$' -or $_.Name -ieq 'metadata.json' }).Count -gt 0) {
                    $scopes.Add([pscustomobject]@{ Path = $child.FullName; ChildModule = $true })
                }
            }
        }
        return $scopes.ToArray()
    }

    $pending = [System.Collections.Generic.Queue[string]]::new()
    if ($Context.Kind -eq 'bicep-monorepo') {
        foreach ($kind in @('res', 'ptn', 'utl')) {
            $path = Join-Path $root 'avm' $kind
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
