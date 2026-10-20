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

function Set-AvmWorkflowReleaseTags {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [switch] $Force,
        [switch] $IncludeAllVersionedModules
    )

    if ($TargetCommit -cnotmatch '^[0-9a-f]{40}$' -or
        (-not [string]::IsNullOrEmpty($BaseCommit) -and $BaseCommit -cnotmatch '^[0-9a-f]{40}$')) {
        throw [ArgumentException]::new('Release target and base commits must be full SHA-1 identifiers.')
    }
    if ($IncludeAllVersionedModules -and -not $WhatIfPreference) {
        throw [ArgumentException]::new('The missing-base all-module fallback is preview-only.')
    }
    if ($env:GITHUB_REPOSITORY -cne 'Azure/bicep-registry-modules' -or $env:GITHUB_REF -cne 'refs/heads/main') {
        throw [InvalidOperationException]::new('Module release tags are restricted to the upstream registry main branch.')
    }
    $module = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
    $head = (Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('rev-parse', 'HEAD')).StdOut.Trim()
    if ($head -cne $TargetCommit) {
        throw [InvalidOperationException]::new('Release inputs must be inspected from the exact target commit checkout.')
    }
    $remote = (Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('remote', 'get-url', '--push', 'origin')).StdOut.Trim()
    if ($remote -cnotmatch '^https://github\.com/Azure/bicep-registry-modules(?:\.git)?$') {
        throw [InvalidOperationException]::new('The release remote must be the upstream registry HTTPS URL.')
    }
    $dirty = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('status', '--porcelain', '--untracked-files=all', '--', $ModulePath)
    if (-not [string]::IsNullOrWhiteSpace($dirty.StdOut)) {
        throw [InvalidOperationException]::new('Release module files must be unchanged from the target commit.')
    }
    if ([string]::IsNullOrEmpty($BaseCommit)) {
        $parent = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('rev-parse', '--verify', "${TargetCommit}^") -AllowFailure
        if ($parent.ExitCode -eq 0) { $BaseCommit = $parent.StdOut.Trim() }
    }
    else {
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
        $diff = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @(
            'diff', '--no-renames', '--name-only', '--diff-filter=ACMRT', $BaseCommit, $TargetCommit, '--', $ModulePath)
        foreach ($changed in $diff.StdOut -split '\r?\n') {
            if ($changed -cnotmatch '/(?:main|version)\.json$') { continue }
            $relative = $changed.Substring(0, $changed.LastIndexOf('/'))
            $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath $relative
            if ((Test-Path -LiteralPath (Join-Path $path 'main.json') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $path 'version.json') -PathType Leaf)) {
                $null = $candidates.Add($relative)
            }
        }
    }
    if ($Force) {
        foreach ($file in @('main.json', 'version.json')) {
            $null = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$ModulePath/$file"
        }
        $null = $candidates.Add($ModulePath)
    }
    $outputs = [Collections.Generic.List[object]]::new()
    foreach ($relative in @($candidates | Sort-Object @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_ } })) {
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
            if (-not [string]::IsNullOrEmpty($BaseCommit)) {
                $previous = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('show', "${BaseCommit}:$relative/version.json") -AllowFailure
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
