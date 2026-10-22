. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-AvmWorkflowRemoteTags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Pattern
    )

    $result = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('ls-remote', '--tags', 'origin', $Pattern) -Remote
    $tags = @{}
    $peeled = @{}
    foreach ($line in $result.StdOut -split '\r?\n') {
        if ($line -ceq '') { continue }
        $match = [regex]::Match($line, '^([0-9a-f]{40})\s+refs/tags/(.+?)(\^\{\})?$')
        if (-not $match.Success) { throw [InvalidOperationException]::new('Git returned an invalid remote tag record.') }
        $name = $match.Groups[2].Value
        if ($match.Groups[3].Success) { $peeled[$name] = $match.Groups[1].Value }
        else { $tags[$name] = $match.Groups[1].Value }
    }
    foreach ($name in $peeled.Keys) { $tags[$name] = $peeled[$name] }
    return $tags
}

function Get-AvmWorkflowPublishableChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [switch] $InitialRelease,
        [switch] $ExactModule
    )

    if ($TargetCommit -cnotmatch '^[0-9a-f]{40}$' -or
        (-not $InitialRelease -and $BaseCommit -cnotmatch '^[0-9a-f]{40}$')) {
        throw [ArgumentException]::new('Publishable change discovery requires full commit identifiers or an initial release.')
    }
    $arguments = if ($InitialRelease) {
        @('ls-tree', '-r', '--name-only', $TargetCommit, '--', $ModulePath)
    }
    else {
        @('diff', '--no-renames', '--name-only', '--diff-filter=ACMRT', $BaseCommit, $TargetCommit, '--', $ModulePath)
    }
    $files = Invoke-AvmWorkflowGitRead -Root $Root -Arguments $arguments
    $candidates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($changed in $files.StdOut -split '\r?\n') {
        if ($changed -cnotmatch '/(?:main|version)\.json$') { continue }
        $relative = $changed.Substring(0, $changed.LastIndexOf('/'))
        if ($ExactModule -and $relative -cne $ModulePath) { continue }
        $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath $relative
        if ((Test-Path -LiteralPath (Join-Path $path 'main.json') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $path 'version.json') -PathType Leaf)) {
            $null = $candidates.Add($relative)
        }
    }
    return @($candidates | Sort-Object @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_ } })
}

function Get-AvmWorkflowPendingReleasePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit
    )

    if ($TargetCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw [ArgumentException]::new('Pending release discovery requires a full target commit identifier.')
    }
    $null = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
    $shallow = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('rev-parse', '--is-shallow-repository')
    if ($shallow.StdOut.Trim() -cne 'false') {
        throw [InvalidOperationException]::new('Pending release discovery requires complete Git history.')
    }
    $files = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('ls-tree', '-r', '--name-only', $TargetCommit, '--', $ModulePath)
    $paths = @($files.StdOut -split '\r?\n' | Where-Object { $_ -cmatch '/main\.json$' } |
            ForEach-Object { $_.Substring(0, $_.LastIndexOf('/')) } |
            Where-Object { Test-Path -LiteralPath (Join-Path $Root $_ 'version.json') -PathType Leaf } |
            Sort-Object @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_ } })
    $tags = Get-AvmWorkflowRemoteTags -Root $Root -Pattern "$ModulePath/*"
    $plan = [Collections.Generic.List[object]]::new()
    foreach ($relative in $paths) {
        $pattern = "^$([regex]::Escape($relative))/\d+\.\d+\.\d+$"
        $latest = @($tags.Keys | Where-Object { $_ -cmatch $pattern } |
                Sort-Object { [version]($_.Substring($_.LastIndexOf('/') + 1)) } -Descending |
                Select-Object -First 1)
        $base = if ($latest.Count -eq 0) { '' } else { $tags[$latest[0]] }
        if ($base) {
            $available = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('cat-file', '-e', "${base}^{commit}") -AllowFailure
            if ($available.ExitCode -ne 0) {
                $null = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('fetch', '--no-tags', 'origin', $base) -Remote
                $null = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('cat-file', '-e', "${base}^{commit}")
            }
            $ancestor = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('merge-base', '--is-ancestor', $base, $TargetCommit) -AllowFailure
            if ($ancestor.ExitCode -ne 0) {
                throw [InvalidOperationException]::new("The latest release tag for $relative is not an ancestor of the release target.")
            }
            foreach ($file in @('main.json', 'version.json')) {
                $null = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('cat-file', '-e', "${base}:$relative/$file")
            }
        }
        $changes = @(Get-AvmWorkflowPublishableChanges -Root $Root -ModulePath $relative `
                -TargetCommit $TargetCommit -BaseCommit $base -InitialRelease:($latest.Count -eq 0) -ExactModule)
        if ($changes.Count -gt 0) {
            $plan.Add([pscustomobject]@{ ModulePath = $relative; BaseCommit = $base; InitialRelease = $latest.Count -eq 0 })
        }
    }
    return $plan.ToArray()
}

function Assert-AvmWorkflowReleaseContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $TargetCommit
    )

    if ($TargetCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw [ArgumentException]::new('Release target commits must be full SHA-1 identifiers.')
    }
    if ($env:GITHUB_REPOSITORY -cne 'Azure/bicep-registry-modules' -or $env:GITHUB_REF -cne 'refs/heads/main') {
        throw [InvalidOperationException]::new('Module release tags are restricted to the upstream registry main branch.')
    }
    $head = (Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('rev-parse', 'HEAD')).StdOut.Trim()
    if ($head -cne $TargetCommit) {
        throw [InvalidOperationException]::new('Release inputs must be inspected from the exact target commit checkout.')
    }
    $remote = (Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('remote', 'get-url', '--push', 'origin')).StdOut.Trim()
    if ($remote -cnotmatch '^https://github\.com/Azure/bicep-registry-modules(?:\.git)?$') {
        throw [InvalidOperationException]::new('The release remote must be the upstream registry HTTPS URL.')
    }
}

function Initialize-AvmWorkflowReleaseMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [ValidateSet('workflow_dispatch', 'push')] [string] $EventName,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit
    )

    Assert-AvmWorkflowReleaseContext -Root $Root -TargetCommit $TargetCommit
    $dirty = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('status', '--porcelain', '--untracked-files=all', '--', 'avm')
    if (-not [string]::IsNullOrWhiteSpace($dirty.StdOut)) {
        throw [InvalidOperationException]::new('Release discovery requires module files unchanged from the target commit.')
    }
    if ($EventName -ceq 'push') {
        $paths = @(Get-AvmWorkflowPublishableChanges -Root $Root -ModulePath avm `
                -TargetCommit $TargetCommit -BaseCommit $BaseCommit)
    }
    else {
        $paths = @(Get-AvmWorkflowPendingReleasePlan -Root $Root -ModulePath avm -TargetCommit $TargetCommit |
                ForEach-Object { $_.ModulePath })
    }
    $modules = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $paths) {
        $match = [regex]::Match($path, '^(avm/(?:res|ptn|utl)/[a-z0-9-]+/[a-z0-9-]+)(?:/|$)')
        if ($match.Success) {
            $null = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$($match.Groups[1].Value)/main.bicep"
            $null = $modules.Add($match.Groups[1].Value)
        }
    }
    if ($modules.Count -gt 256) {
        throw [InvalidOperationException]::new('The release selection exceeds the 256-job matrix limit.')
    }
    return @{ include = @(foreach ($path in $modules) { @{ modulePath = $path } }) }
}

function Set-AvmWorkflowReleaseTags {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [switch] $Force,
        [switch] $IncludeAllVersionedModules,
        [switch] $PendingRelease
    )

    if ($TargetCommit -cnotmatch '^[0-9a-f]{40}$' -or
        (-not [string]::IsNullOrEmpty($BaseCommit) -and $BaseCommit -cnotmatch '^[0-9a-f]{40}$')) {
        throw [ArgumentException]::new('Release target and base commits must be full SHA-1 identifiers.')
    }
    if ($IncludeAllVersionedModules -and -not $WhatIfPreference) {
        throw [ArgumentException]::new('The missing-base all-module fallback is preview-only.')
    }
    if ($PendingRelease -and ($Force -or $IncludeAllVersionedModules -or $BaseCommit)) {
        throw [ArgumentException]::new('Pending releases cannot override per-module baselines or force unchanged modules.')
    }
    Assert-AvmWorkflowReleaseContext -Root $Root -TargetCommit $TargetCommit
    $module = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
    $dirty = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('status', '--porcelain', '--untracked-files=all', '--', $ModulePath)
    if (-not [string]::IsNullOrWhiteSpace($dirty.StdOut)) {
        throw [InvalidOperationException]::new('Release module files must be unchanged from the target commit.')
    }
    if (-not $PendingRelease -and [string]::IsNullOrEmpty($BaseCommit)) {
        $parent = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('rev-parse', '--verify', "${TargetCommit}^") -AllowFailure
        if ($parent.ExitCode -eq 0) { $BaseCommit = $parent.StdOut.Trim() }
    }
    elseif ($BaseCommit) {
        $available = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('cat-file', '-e', "${BaseCommit}^{commit}") -AllowFailure
        if ($available.ExitCode -ne 0) {
            $null = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('fetch', '--no-tags', 'origin', $BaseCommit) -Remote
            $null = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('cat-file', '-e', "${BaseCommit}^{commit}")
        }
    }
    $candidates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($IncludeAllVersionedModules) {
        foreach ($file in Get-ChildItem -LiteralPath $module -Recurse -File -Filter main.json) {
            if (Test-Path -LiteralPath (Join-Path $file.DirectoryName 'version.json') -PathType Leaf) {
                $null = $candidates.Add([IO.Path]::GetRelativePath($Root, $file.DirectoryName).Replace('\', '/'))
            }
        }
    }
    elseif (-not [string]::IsNullOrEmpty($BaseCommit)) {
        foreach ($relative in Get-AvmWorkflowPublishableChanges -Root $Root -ModulePath $ModulePath `
                -BaseCommit $BaseCommit -TargetCommit $TargetCommit) {
            $null = $candidates.Add($relative)
        }
    }
    if ($Force) {
        foreach ($file in @('main.json', 'version.json')) {
            $null = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$ModulePath/$file"
        }
        $null = $candidates.Add($ModulePath)
    }
    $plan = if ($PendingRelease) {
        @(Get-AvmWorkflowPendingReleasePlan -Root $Root -ModulePath $ModulePath -TargetCommit $TargetCommit)
    }
    else {
        @(foreach ($relative in @($candidates | Sort-Object @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_ } })) {
                [pscustomobject]@{ ModulePath = $relative; BaseCommit = $BaseCommit }
            })
    }
    $outputs = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $plan) {
        $relative = $candidate.ModulePath
        $candidateBase = $candidate.BaseCommit
        $versionPath = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$relative/version.json"
        $version = (ConvertFrom-Json -InputObject (Get-Content -LiteralPath $versionPath -Raw)).version
        if ($version -isnot [string] -or $version -cnotmatch '^\d+\.\d+$') {
            throw [ArgumentException]::new("The version file for $relative must contain MAJOR.MINOR.")
        }
        $remoteTags = Get-AvmWorkflowRemoteTags -Root $Root -Pattern "$relative/$version.*"
        $valid = @($remoteTags.Keys | Where-Object { $_ -cmatch "^$([regex]::Escape("$relative/$version."))\d+$" })
        $existing = @($valid | Where-Object { $remoteTags[$_] -ceq $TargetCommit } |
                Sort-Object { [version]($_.Substring($_.LastIndexOf('/') + 1)) } -Descending)
        $reused = $existing.Count -gt 0
        if ($reused) { $tag = $existing[0] }
        else {
            $changedVersion = $false
            if (-not [string]::IsNullOrEmpty($candidateBase)) {
                $previous = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('show', "${candidateBase}:$relative/version.json") -AllowFailure
                $changedVersion = $previous.ExitCode -ne 0 -or (ConvertFrom-Json -InputObject $previous.StdOut).version -cne $version
            }
            $patch = 0
            if (-not $changedVersion -and $valid.Count -gt 0) {
                $patch = 1 + ($valid | ForEach-Object { [int]$_.Substring($_.LastIndexOf('.') + 1) } |
                        Measure-Object -Maximum).Maximum
            }
            $tag = "$relative/$version.$patch"
        }
        $null = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('check-ref-format', "refs/tags/$tag")
        if ($remoteTags.ContainsKey($tag) -and $remoteTags[$tag] -cne $TargetCommit) {
            throw [InvalidOperationException]::new("Release tag $tag already points to a different commit.")
        }
        $created = $false
        if (-not $reused -and $PSCmdlet.ShouldProcess("$tag at $TargetCommit", 'Create and push module release tag')) {
            if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
                throw [InvalidOperationException]::new('The release-tag job requires its scoped GitHub token.')
            }
            $local = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('rev-parse', '-q', '--verify', "refs/tags/$tag^{}") -AllowFailure
            if ($local.ExitCode -eq 0 -and $local.StdOut.Trim() -cne $TargetCommit) {
                throw [InvalidOperationException]::new("Local tag $tag points to a different commit.")
            }
            if ($local.ExitCode -ne 0) {
                $null = Invoke-AvmWorkflowProcess -FilePath git -WorkingDirectory $Root -ArgumentList @('tag', $tag, $TargetCommit)
            }
            $authorization = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$env:GITHUB_TOKEN"))
            $confirmed = $false
            try {
                $push = Invoke-AvmWorkflowProcess -FilePath git -WorkingDirectory $Root `
                    -ArgumentList @('push', 'origin', "refs/tags/${tag}:refs/tags/${tag}") -IgnoreExitCode `
                    -EnvVars @{
                        GIT_TERMINAL_PROMPT = '0'
                        GIT_CONFIG_COUNT = '1'
                        GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
                        GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $authorization"
                    }
                $confirmed = $push.ExitCode -eq 0
            }
            catch [TimeoutException] {
                Write-Warning "Publishing $tag timed out; checking the remote result without replaying the push."
            }
            if (-not $confirmed) {
                $reconciled = Get-AvmWorkflowRemoteTags -Root $Root -Pattern "$tag*"
                if (-not $reconciled.ContainsKey($tag) -or $reconciled[$tag] -cne $TargetCommit) {
                    throw [InvalidOperationException]::new("Publishing $tag failed; no mutation was retried.")
                }
            }
            $created = $true
        }
        $outputs.Add([pscustomobject]@{ Module = $relative; Tag = $tag; Commit = $TargetCommit; Reused = $reused; Created = $created })
    }
    return $outputs.ToArray()
}
