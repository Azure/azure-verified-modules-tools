function Get-AvmTerraformInspectionModuleKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [object] $Source,
        [AllowNull()] [object] $Version
    )

    if ($Source -isnot [string] -or $Version -isnot [string] -or
        $Source -cnotmatch '^(?:registry\.terraform\.io/)?[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9][A-Za-z0-9_-]*/[a-z][a-z0-9]*$' -or
        $Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        return $null
    }
    $canonical = if ($Source.StartsWith('registry.terraform.io/', [StringComparison]::Ordinal)) {
        $Source
    }
    else { "registry.terraform.io/$Source" }
    return "$canonical@$Version"
}

function Get-AvmTerraformInspectionPackageFingerprint {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $InspectionRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $root = [System.IO.Path]::GetFullPath($InspectionRoot)
    $directory = [System.IO.Path]::GetFullPath($Path)
    $relative = [System.IO.Path]::GetRelativePath($root, $directory)
    if ($relative -ceq '.' -or [System.IO.Path]::IsPathRooted($relative) -or
        @($relative -split '[\\/]' | Where-Object { $_ -ceq '..' }).Count -gt 0) {
        throw [AvmConfigurationException]::new('Inspection packages must remain inside the owned temporary inspection directory.')
    }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        Write-AvmLog "inspection cache: package is unavailable at '$directory'." -Level Verbose | Out-Null
        return $null
    }
    $ancestor = Get-Item -LiteralPath $directory -Force
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-AvmLog "inspection cache: linked package directory '$($ancestor.FullName)' is not reusable." -Level Verbose | Out-Null
            return $null
        }
        if ([System.IO.Path]::GetRelativePath($root, $ancestor.FullName) -ceq '.') { break }
        $ancestor = $ancestor.Parent
    }

    $entries = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($directory)
    while ($pending.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Write-AvmLog "inspection cache: linked package entry '$($entry.FullName)' is not reusable." -Level Verbose | Out-Null
                return $null
            }
            if ($entry.Name -ieq '.terraform' -or $entry.Name -like '*.tfstate*' -or $entry.Name -in @('tfplan', 'tfplan.json')) {
                Write-AvmLog "inspection cache: package entry '$($entry.FullName)' contains initialization or plan data and is not reusable." -Level Verbose | Out-Null
                return $null
            }
            $name = [System.IO.Path]::GetRelativePath($directory, $entry.FullName).Replace('\', '/')
            if ($entry.PSIsContainer) {
                $entries.Add("directory`0$name")
                $pending.Push($entry.FullName)
            }
            else {
                $entries.Add("file`0$name`0$((Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash)")
            }
        }
    }
    $ordered = $entries.ToArray()
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ordered -join "`0")
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
}

function Register-AvmTerraformInspectionModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string] $DataDirectory,
        [Parameter(Mandatory)] [string] $InspectionRoot,
        [Parameter(Mandatory)] [hashtable] $Cache
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    foreach ($record in $Manifest.Modules) {
        $key = Get-AvmTerraformInspectionModuleKey -Source $record['Source'] -Version $record['Version']
        if ($null -eq $key -or $Cache.ContainsKey($key) -or
            $record.Key -cnotmatch '^[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*$') { continue }
        $directory = [System.IO.Path]::GetFullPath($record.Dir, $WorkingDirectory)
        $expected = [System.IO.Path]::GetFullPath((Join-Path -Path $DataDirectory -ChildPath 'modules' -AdditionalChildPath $record.Key))
        if ([System.IO.Path]::GetRelativePath($expected, $directory) -cne '.') { continue }
        $fingerprint = Get-AvmTerraformInspectionPackageFingerprint -Path $directory -InspectionRoot $InspectionRoot
        if ($null -eq $fingerprint) { continue }
        $Cache[$key] = @{
            Directory   = $directory
            Fingerprint = $fingerprint
            Source      = $key.Substring(0, $key.LastIndexOf('@'))
            Version     = $record.Version
        }
    }
}

function Initialize-AvmTerraformInspectionModule {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $DataDirectory,
        [Parameter(Mandatory)] [object[]] $ModuleTargets,
        [Parameter(Mandatory)] [object] $Options,
        [Parameter(Mandatory)] [hashtable] $Cache
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($Cache.Count -eq 0 -or -not $PSCmdlet.ShouldProcess($DataDirectory, 'Seed freshly downloaded inspection modules')) {
        return 0
    }
    if ($null -eq (Get-AvmTerraformInspectionPackageFingerprint -Path $DataDirectory -InspectionRoot $Options.InspectionRoot) -or
        @(Get-ChildItem -LiteralPath $DataDirectory -Force).Count -gt 0) {
        throw [AvmConfigurationException]::new('Dependency reuse requires a fresh, unlinked inspection data directory.')
    }
    $comparison = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $known = [System.Collections.Generic.HashSet[string]]::new($comparison)
    foreach ($target in @($ModuleTargets.Path) + @($Path)) {
        $null = $known.Add([System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($target)))
    }
    $inspectionProfile = Join-Path $Options.InspectionRoot 'module-inspection'
    $null = New-Item -ItemType Directory -Path $inspectionProfile -Force
    [System.IO.File]::WriteAllText(
        (Join-Path $inspectionProfile 'calls.mptf.hcl'), "data `"module`" `"avm_inspection`" {}`n", [System.Text.UTF8Encoding]::new($false))
    $records = [System.Collections.Generic.List[object]]::new()
    $records.Add(@{ Key = ''; Source = ''; Dir = '.' })
    $copies = [System.Collections.Generic.List[object]]::new()
    $callsByDirectory = [System.Collections.Generic.Dictionary[string, object]]::new($comparison)
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue([pscustomobject]@{ Path = $Path; Key = ''; Ancestors = @() })
    while ($pending.Count -gt 0) {
        $scope = $pending.Dequeue()
        if (-not $callsByDirectory.ContainsKey($scope.Path)) {
            $files = @(Get-ChildItem -LiteralPath $scope.Path -File -Force)
            if (@($files | Where-Object { $_.Name -match '(^|_)override\.tf(?:\.json)?$' }).Count -gt 0) {
                Write-AvmLog "inspection cache: Terraform overrides in '$($scope.Path)' require normal module installation." -Level Verbose | Out-Null
                return 0
            }
            foreach ($file in $files | Where-Object { $_.Name.EndsWith('.tf.json', [StringComparison]::OrdinalIgnoreCase) }) {
                try {
                    Assert-AvmTerraformLocalsOnlyJson -Path $file.FullName -ReviewMessage 'Module-call reuse requires inspectable configuration'
                }
                catch [AvmConfigurationException] {
                    Write-AvmLog "inspection cache: JSON configuration in '$($scope.Path)' requires normal module installation." -Level Verbose | Out-Null
                    return 0
                }
            }
            $result = Invoke-AvmProcess -FilePath $Options.ToolPath -ArgumentList @(
                'debug', '--tf-dir', $scope.Path, '--mptf-dir', $inspectionProfile, '--eval', 'data.module.avm_inspection.result'
            ) -WorkingDirectory $scope.Path -EnvVars $Options.EnvVars
            try {
                $calls = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -NoEnumerate -ErrorAction Stop
            }
            catch [System.ArgumentException] {
                throw [AvmConfigurationException]::new("Cannot inspect module calls for dependency reuse in '$($scope.Path)': invalid native JSON.")
            }
            if ($calls -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new("Cannot inspect module calls for dependency reuse in '$($scope.Path)': expected a native module map.")
            }
            $callsByDirectory[$scope.Path] = $calls
        }
        $calls = $callsByDirectory[$scope.Path]
        foreach ($name in @($calls.Keys | Sort-Object -CaseSensitive)) {
            $call = $calls[$name]
            if ($name -cnotmatch '^[A-Za-z_][A-Za-z0-9_-]*$' -or
                $call -isnot [System.Collections.IDictionary] -or $call['source'] -isnot [string]) {
                Write-AvmLog 'inspection cache: an uninspectable module call requires normal Terraform installation.' -Level Verbose | Out-Null
                return 0
            }
            $moduleKey = if ($scope.Key) { "$($scope.Key).$name" } else { $name }
            $source = $call.source
            $local = $source.StartsWith('./', [StringComparison]::Ordinal) -or
            $source.StartsWith('../', [StringComparison]::Ordinal) -or
            $source.StartsWith('.\', [StringComparison]::Ordinal) -or
            $source.StartsWith('..\', [StringComparison]::Ordinal) -or
            [System.IO.Path]::IsPathRooted($source)
            if ($local) {
                $directory = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($source, $scope.Path))
                if (-not $known.Contains($directory)) { continue }
                $ancestors = @($scope.Ancestors) + @($scope.Path)
                if (@($ancestors | Where-Object { $comparison.Equals($_, $directory) }).Count -gt 0) {
                    Write-AvmLog 'inspection cache: a cyclic local call requires normal Terraform installation.' -Level Verbose | Out-Null
                    return 0
                }
                $records.Add(@{ Key = $moduleKey; Source = $source; Dir = $directory.Replace('\', '/') })
                $pending.Enqueue([pscustomobject]@{ Path = $directory; Key = $moduleKey; Ancestors = $ancestors })
                continue
            }
            $cacheKey = Get-AvmTerraformInspectionModuleKey -Source $source -Version $call['version']
            if ($null -eq $cacheKey -or -not $Cache.ContainsKey($cacheKey)) { continue }
            $cached = $Cache[$cacheKey]
            $fingerprint = Get-AvmTerraformInspectionPackageFingerprint -Path $cached.Directory -InspectionRoot $Options.InspectionRoot
            if ($null -eq $fingerprint -or $fingerprint -cne $cached.Fingerprint) {
                throw [AvmConfigurationException]::new("Downloaded inspection module '$source' changed; retry the transform before reusing it.")
            }
            $destination = Join-Path -Path $DataDirectory -ChildPath 'modules' -AdditionalChildPath $moduleKey
            $copies.Add(@{ Source = $cached.Directory; Destination = $destination })
            $records.Add(@{
                    Key = $moduleKey; Source = $cached.Source; Version = $cached.Version; Dir = $destination.Replace('\', '/')
                })
        }
    }
    if ($copies.Count -eq 0) { return 0 }
    $modulesPath = Join-Path $DataDirectory 'modules'
    $null = New-Item -ItemType Directory -Path $modulesPath -Force
    foreach ($copy in $copies) {
        Copy-Item -LiteralPath $copy.Source -Destination $copy.Destination -Recurse -ErrorAction Stop -ProgressAction SilentlyContinue
    }
    $payload = ConvertTo-Json -InputObject @{ Modules = $records.ToArray() } -Depth 10 -Compress
    [System.IO.File]::WriteAllText((Join-Path $modulesPath 'modules.json'), $payload, [System.Text.UTF8Encoding]::new($false))
    Write-AvmLog ("inspection cache: seeded {0} downloaded module(s) for {1}; Terraform will revalidate the target graph." -f $copies.Count, $Path) -Level Verbose | Out-Null
    return $copies.Count
}
