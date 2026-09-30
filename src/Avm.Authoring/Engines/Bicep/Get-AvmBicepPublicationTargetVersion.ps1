function Get-AvmBicepPublicationTargetVersion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Scope,

        [Parameter(Mandatory)]
        [string] $Version,

        [Parameter(Mandatory)]
        $GitState
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $number = $null
    if ($Version -cnotmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z' -or
        -not [version]::TryParse("$Version.0", [ref]$number)) {
        throw [AvmConfigurationException]::new(
            "Module '$($Scope.ModuleRelativePath)' has an invalid major.minor version for publication.")
    }
    $path = "$($Scope.ModuleRelativePath)/version.json"
    $tree = Invoke-AvmProcess -FilePath $GitState.GitPath -WorkingDirectory $GitState.RepositoryRoot `
        -ArgumentList @('ls-tree', '-z', $GitState.BaseSha, '--', $path) -TimeoutSec 15
    $previous = $null
    if ($tree.StdOut.Length -gt 0) {
        $entry = [regex]::Match($tree.StdOut, '^(?:100644|100755) blob [0-9a-f]{40,64}\t(?<path>[^\0]+)\0\z')
        if (-not $entry.Success -or $entry.Groups['path'].Value -cne $path) {
            throw [AvmConfigurationException]::new(
                "The upstream version file for '$($Scope.ModuleRelativePath)' is not a regular version.json.")
        }
        $old = Invoke-AvmProcess -FilePath $GitState.GitPath -WorkingDirectory $GitState.RepositoryRoot `
            -ArgumentList @('show', "$($GitState.BaseSha):$path") -TimeoutSec 15
        try {
            $data = $old.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch [System.Management.Automation.RuntimeException] {
            throw [AvmConfigurationException]::new(
                "Cannot parse the upstream version.json for '$($Scope.ModuleRelativePath)'.")
        }
        $previousNumber = $null
        if ($data -isnot [System.Collections.IDictionary] -or
            $data['version'] -isnot [string] -or
            $data['version'] -cnotmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z' -or
            -not [version]::TryParse("$($data['version']).0", [ref]$previousNumber)) {
            throw [AvmConfigurationException]::new(
                "The upstream version.json for '$($Scope.ModuleRelativePath)' lacks a valid major.minor version.")
        }
        $previous = $data['version']
        if ($number -lt $previousNumber) {
            throw [AvmConfigurationException]::new(
                "Module '$($Scope.ModuleRelativePath)' version '$Version' must increase from upstream '$previous'; downgrades cannot be published.")
        }
    }

    $changedVersion = $null -eq $previous -or $previous -cne $Version
    $patch = 0
    if (-not $changedVersion) {
        $upstream = 'https://github.com/Azure/bicep-registry-modules.git'
        $tags = Invoke-AvmProcess -FilePath $GitState.GitPath -WorkingDirectory $GitState.RepositoryRoot `
            -ArgumentList @('ls-remote', '--tags', $upstream, "$($Scope.ModuleRelativePath)/$Version.*") `
            -TimeoutSec 30 -IgnoreExitCode `
            -EnvVars @{ GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'Never' }
        if ($tags.ExitCode -ne 0) {
            throw [AvmConfigurationException]::new(
                "Cannot verify upstream release tags for '$($Scope.ModuleRelativePath)'; the target patch is unknown.")
        }
        $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($line in $tags.StdOut.Split("`n", [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $match = [regex]::Match($line.TrimEnd("`r"),
                '^[0-9a-f]{40,64}\trefs/tags/(?<module>avm/(?:res|ptn|utl)(?:/[a-z0-9]+(?:-[a-z0-9]+)*){2,})/(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?<peeled>\^\{\})?\z')
            if (-not $match.Success -or
                $match.Groups['module'].Value -cne $Scope.ModuleRelativePath -or
                -not $match.Groups['version'].Value.StartsWith("$Version.", [System.StringComparison]::Ordinal)) {
                throw [AvmConfigurationException]::new(
                    "Upstream release tags for '$($Scope.ModuleRelativePath)' have an unexpected format.")
            }
            if (-not $found.Add($match.Groups['version'].Value)) {
                if ($match.Groups['peeled'].Success) {
                    continue
                }
                throw [AvmConfigurationException]::new(
                    "Upstream release tags for '$($Scope.ModuleRelativePath)' contain duplicate versions.")
            }
            $release = $null
            if (-not [version]::TryParse($match.Groups['version'].Value, [ref]$release) -or
                $release.Build -eq [int]::MaxValue) {
                throw [AvmConfigurationException]::new(
                    "Upstream release tags for '$($Scope.ModuleRelativePath)' have an invalid patch.")
            }
            $patch = [Math]::Max($patch, $release.Build + 1)
        }
    }

    $shouldPublish = $Version -ceq '0.1' -and $patch -eq 0
    foreach ($changedPath in $GitState.ChangedPaths) {
        if ($changedPath.StartsWith("$($Scope.ModuleRelativePath)/", [System.StringComparison]::Ordinal) -and
            $changedPath -cmatch '/(?:main|version)\.json\z') {
            $shouldPublish = $true
            break
        }
    }
    return [pscustomobject]@{
        TargetVersion   = "$Version.$patch"
        VersionChanged  = $changedVersion
        PreviousVersion = $previous
        ShouldPublish   = $shouldPublish
    }
}
