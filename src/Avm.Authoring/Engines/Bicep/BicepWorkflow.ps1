function Resolve-AvmBicepWorkflowPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $RelativePath,
        [switch] $AllowMissing
    )

    $relative = $RelativePath.Replace('\', '/')
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '[:\x00-\x1f*?\[\]]' -or
        $relative.Split('/') -contains '..' -or [string]::IsNullOrWhiteSpace($relative)) {
        throw [ArgumentException]::new('A workflow path must be a literal, repository-relative path without parent segments.')
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $path = [IO.Path]::GetFullPath((Join-Path $rootPath $relative))
    $prefix = $rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw [ArgumentException]::new('The workflow path must remain inside its checkout.')
    }
    $current = $rootPath
    foreach ($segment in $relative.Split('/', [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if ((Test-Path -LiteralPath $current) -and
            ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw [ArgumentException]::new('Workflow inputs must not traverse linked files or directories.')
        }
    }
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $path)) {
        throw [IO.FileNotFoundException]::new("Workflow input does not exist: $relative")
    }
    return $path
}

function ConvertTo-AvmBicepWorkflowBooleanInternal {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [object] $Value)

    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string] -and $Value -match '^(true|false)$') { return $Value -ieq 'true' }
    throw [ArgumentException]::new('A workflow boolean must be true or false.')
}

function Test-AvmBicepWorkflowLegacyModuleLockInternal {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [Collections.IDictionary] $Template)

    $resources = @(if ($Template['resources'] -is [Collections.IDictionary]) {
            $Template.resources.Values
        }
        else { $Template['resources'] | Where-Object { $null -ne $_ } })
    if ($resources.Count -gt 0 -and $Template['$schema'] -match '/(?:managementGroup|tenant)DeploymentTemplate\.json#?$') {
        return $true
    }
    foreach ($resource in $resources) {
        if ($resource -isnot [Collections.IDictionary]) {
            throw [ArgumentException]::new('Compiled deployment resources must be objects.')
        }
        if ($resource['type'] -ieq 'Microsoft.Resources/deployments') {
            $properties = $resource['properties']
            if ($properties -isnot [Collections.IDictionary]) {
                throw [ArgumentException]::new('Compiled nested deployments must have properties.')
            }
            if ($properties['templateLink']) { return $true }
            $nested = $properties['template']
            if ($nested -is [string] -and $nested -cmatch "^\[variables\('([^']+)'\)\]$" -and
                $Template['variables'] -is [Collections.IDictionary]) {
                $nested = $Template['variables'][$Matches[1]]
            }
            if ($nested -isnot [Collections.IDictionary]) { return $true }
            if (Test-AvmBicepWorkflowLegacyModuleLockInternal -Template $nested) { return $true }
        }
        if ($resource['resources'] -and (Test-AvmBicepWorkflowLegacyModuleLockInternal -Template @{ resources = $resource.resources })) {
            return $true
        }
    }
    return $false
}

function Get-AvmBicepWorkflowNamePrefixInternal {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateSet('isolated', 'shared', 'fallback')] [string] $IsolationMode,
        [AllowEmptyString()] [string] $Prefix
    )

    if ($IsolationMode -eq 'fallback') { return '' }
    if ([string]::IsNullOrEmpty($Prefix)) { $Prefix = 'gci' }
    if ($Prefix -cnotmatch '^[a-z][a-z0-9]{0,2}$') {
        throw [ArgumentException]::new('Reviewed Bicep tests require a lowercase alphanumeric naming prefix of one to three characters.')
    }
    return $Prefix + '#_avmE2eSuffix_#'
}

function Assert-AvmBicepWorkflowIsolationInputInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('isolated', 'shared', 'fallback')] [string] $IsolationMode,
        [Parameter(Mandatory)] [string] $CompiledTemplate,
        [bool] $RemoveDeployment = $true
    )

    if ($IsolationMode -eq 'fallback') { return }
    if ($IsolationMode -eq 'shared' -and -not $RemoveDeployment) {
        throw [ArgumentException]::new('Shared-target execution requires cleanup before releasing the lifecycle lock; removeDeployment must be true.')
    }
    $template = ConvertFrom-Json -InputObject $CompiledTemplate -AsHashtable
    $ci = Get-AvmBicepWorkflowEnvironment -Enabled
    if (@($ci.Tokens.Keys | Where-Object { $_ -ine 'namePrefix' }).Count -gt 0) {
        throw [ArgumentException]::new('Reviewed isolation does not allow custom localToken overrides.')
    }
    if (-not [string]::IsNullOrEmpty($ci.KeyVaultName)) {
        throw [ArgumentException]::new('Reviewed isolation does not allow implicit CI Key Vault parameter overrides.')
    }
    $parameters = @{}
    if ($template['parameters'] -is [Collections.IDictionary]) {
        foreach ($name in $template['parameters'].Keys) { $parameters[$name] = @{ type = 'secureString' } }
    }
    $overrides = Get-AvmBicepCiParameter -TemplateParameters $parameters -Variables $ci.Variables -Secrets $ci.Secrets
    if ($overrides.Count -gt 0) {
        throw [ArgumentException]::new('Reviewed isolation does not allow CI parameter overrides of compiled test defaults.')
    }
}

function Invoke-AvmBicepWorkflowGit {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $Remote,
        [switch] $AllowFailure
    )

    $maximum = if ($Remote) { 3 } else { 1 }
    $git = (Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    for ($attempt = 1; $attempt -le $maximum; $attempt++) {
        try {
            $result = Invoke-AvmProcess -FilePath $git -ArgumentList $Arguments -WorkingDirectory $Root `
                -EnvVars @{ GIT_TERMINAL_PROMPT = '0' } -TimeoutSec 120 -IgnoreExitCode
        }
        catch [TimeoutException] {
            if ($attempt -eq $maximum) { throw }
            Write-Warning "Git $($Arguments[0]) timed out on attempt $attempt of $maximum; retrying the read."
            Start-Sleep -Seconds (2 * $attempt)
            continue
        }
        if ($result.ExitCode -eq 0) { return $result }
        if ($attempt -lt $maximum) { Start-Sleep -Seconds (2 * $attempt) }
    }
    if ($AllowFailure) { return $result }
    throw [InvalidOperationException]::new("Git $($Arguments[0]) failed after $maximum attempt(s): $($result.StdErr)")
}

function Get-AvmBicepWorkflowTestFilesInternal {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAlignAssignmentStatement', '',
        Justification = 'Compact workflow matrix fields intentionally use their public JSON names.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [string] $PsRuleFilterRegex = '(defaults|waf-aligned)'
    )

    $module = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath $ModulePath
    $filter = [regex]::new($PsRuleFilterRegex, [Text.RegularExpressions.RegexOptions]::None,
        [TimeSpan]::FromSeconds(1))
    $files = @(Get-ChildItem -LiteralPath $module -Recurse -File -Filter 'main.test.bicep' |
            Sort-Object FullName | ForEach-Object {
                $relative = [IO.Path]::GetRelativePath($module, $_.FullName).Replace('\', '/')
                $null = Resolve-AvmBicepWorkflowPath -Root $module -RelativePath $relative
                [ordered]@{
                    path = $relative
                    name = $_.Directory.Name
                    e2eIgnore = Test-Path -LiteralPath (Join-Path $_.Directory.FullName '.e2eignore')
                }
            })
    $policyFiles = @($files | Where-Object { $filter.IsMatch($_.path) } |
            ForEach-Object { [ordered]@{ path = $_.path; name = $_.name } })
    return @{
        moduleTestFilePaths = ConvertTo-Json -InputObject $files -Compress
        psRuleModuleTestFilePaths = ConvertTo-Json -InputObject $policyFiles -Compress
    }
}

function Get-AvmBicepWorkflowModuleMatrixInternal {
    [CmdletBinding(DefaultParameterSetName = 'Changed')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory, ParameterSetName = 'Requested')] [string] $ModulePaths,
        [Parameter(Mandatory, ParameterSetName = 'Changed')] [AllowEmptyCollection()] [string[]] $ChangedFiles,
        [switch] $ExcludeMetadataChanges
    )

    $requested = $PSCmdlet.ParameterSetName -eq 'Requested'
    $paths = if ($requested) { $ModulePaths.Split(',') } else { $ChangedFiles }
    $modules = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            if ($requested) { throw [ArgumentException]::new('Every requested module path must be nonempty.') }
            continue
        }
        $relative = $path.Trim().Replace('\', '/').TrimEnd('/')
        if ($relative.StartsWith('./', [StringComparison]::Ordinal)) { $relative = $relative.Substring(2) }
        if ($relative.Split('/') -contains '..' -or $relative -match '[*?\[\]\x00-\x1f]') {
            throw [ArgumentException]::new('Module paths must not contain parent segments, wildcards or control characters.')
        }
        if (-not $requested -and ($relative -imatch '/README\.md$' -or
                ($ExcludeMetadataChanges -and $relative -imatch '/metadata\.json$'))) { continue }
        $match = [regex]::Match($relative, '^(avm/(?:res|ptn|utl)/[a-z0-9-]+/[a-z0-9-]+)(?:/|$)')
        if (-not $match.Success) {
            if ($requested) { throw [ArgumentException]::new("Not a top-level AVM module: $relative") }
            continue
        }
        $modulePath = $match.Groups[1].Value
        $source = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath "$modulePath/main.bicep" -AllowMissing
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            if ($requested) { throw [ArgumentException]::new("No top-level AVM module exists at $modulePath.") }
            continue
        }
        $null = $modules.Add($modulePath)
    }
    if ($modules.Count -gt 256) {
        throw [ArgumentException]::new('The selection exceeds the 256-job matrix limit. Use smaller manual module batches.')
    }
    $entries = @(foreach ($modulePath in $modules) {
            $entry = Get-AvmBicepWorkflowTestFilesInternal -Root $Root -ModulePath $modulePath
            $entry.modulePath = $modulePath
            $entry
        })
    return @{ include = $entries }
}

function Get-AvmBicepWorkflowRemoteTags {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The function returns the complete remote tag collection.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Pattern
    )

    $result = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('ls-remote', '--tags', 'origin', $Pattern) -Remote
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

function Get-AvmBicepWorkflowPublishableChangesInternal {
    [CmdletBinding()]
    [OutputType([object[]])]
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
    $files = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments $arguments
    $candidates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($changed in $files.StdOut -split '\r?\n') {
        if ($changed -cnotmatch '/(?:main|version)\.json$') { continue }
        $relative = $changed.Substring(0, $changed.LastIndexOf('/'))
        if ($ExactModule -and $relative -cne $ModulePath) { continue }
        $path = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath $relative
        if ((Test-Path -LiteralPath (Join-Path $path 'main.json') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $path 'version.json') -PathType Leaf)) {
            $null = $candidates.Add($relative)
        }
    }
    return @($candidates | Sort-Object @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_ } })
}

function Get-AvmBicepWorkflowPendingReleasePlanInternal {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit
    )

    if ($TargetCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw [ArgumentException]::new('Pending release discovery requires a full target commit identifier.')
    }
    $null = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath $ModulePath
    $shallow = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('rev-parse', '--is-shallow-repository')
    if ($shallow.StdOut.Trim() -cne 'false') {
        throw [InvalidOperationException]::new('Pending release discovery requires complete Git history.')
    }
    $files = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('ls-tree', '-r', '--name-only', $TargetCommit, '--', $ModulePath)
    $paths = @($files.StdOut -split '\r?\n' | Where-Object { $_ -cmatch '/main\.json$' } |
            ForEach-Object { $_.Substring(0, $_.LastIndexOf('/')) } |
            Where-Object {
                Test-Path -LiteralPath (Join-Path -Path $Root -ChildPath $_ -AdditionalChildPath 'version.json') -PathType Leaf
            } |
            Sort-Object @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_ } })
    $tags = Get-AvmBicepWorkflowRemoteTags -Root $Root -Pattern "$ModulePath/*"
    $plan = [Collections.Generic.List[object]]::new()
    foreach ($relative in $paths) {
        $pattern = "^$([regex]::Escape($relative))/\d+\.\d+\.\d+$"
        $latest = @($tags.Keys | Where-Object { $_ -cmatch $pattern } |
                Sort-Object { [version]($_.Substring($_.LastIndexOf('/') + 1)) } -Descending |
                Select-Object -First 1)
        $base = if ($latest.Count -eq 0) { '' } else { $tags[$latest[0]] }
        if ($base) {
            $available = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('cat-file', '-e', "${base}^{commit}") -AllowFailure
            if ($available.ExitCode -ne 0) {
                $null = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('fetch', '--no-tags', 'origin', $base) -Remote
                $null = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('cat-file', '-e', "${base}^{commit}")
            }
            $ancestor = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('merge-base', '--is-ancestor', $base, $TargetCommit) -AllowFailure
            if ($ancestor.ExitCode -ne 0) {
                throw [InvalidOperationException]::new("The latest release tag for $relative is not an ancestor of the release target.")
            }
            foreach ($file in @('main.json', 'version.json')) {
                $null = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('cat-file', '-e', "${base}:$relative/$file")
            }
        }
        $changes = @(Get-AvmBicepWorkflowPublishableChangesInternal -Root $Root -ModulePath $relative `
                -TargetCommit $TargetCommit -BaseCommit $base -InitialRelease:($latest.Count -eq 0) -ExactModule)
        if ($changes.Count -gt 0) {
            $plan.Add([pscustomobject]@{ ModulePath = $relative; BaseCommit = $base; InitialRelease = $latest.Count -eq 0 })
        }
    }
    return $plan.ToArray()
}

function Assert-AvmBicepWorkflowReleaseContext {
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
    $head = (Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('rev-parse', 'HEAD')).StdOut.Trim()
    if ($head -cne $TargetCommit) {
        throw [InvalidOperationException]::new('Release inputs must be inspected from the exact target commit checkout.')
    }
    $remote = (Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('remote', 'get-url', '--push', 'origin')).StdOut.Trim()
    if ($remote -cnotmatch '^https://github\.com/Azure/bicep-registry-modules(?:\.git)?$') {
        throw [InvalidOperationException]::new('The release remote must be the upstream registry HTTPS URL.')
    }
}

function Assert-AvmBicepWorkflowReleaseChangelog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $Version
    )

    $context = "CHANGELOG.md for $ModulePath release $Version"
    $path = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath $ModulePath
    try {
        $data = Get-AvmBicepVersionInput -Scope @{ Path = $path; ModuleRelativePath = $ModulePath }
    }
    catch [IO.IOException], [UnauthorizedAccessException], [Text.DecoderFallbackException],
    [Management.Automation.CommandNotFoundException], [Management.Automation.ItemNotFoundException] {
        throw [InvalidOperationException]::new("${context}: cannot read changelog data: $($_.Exception.Message)", $_.Exception)
    }
    if ($null -eq $data -or $data.VersionError) {
        throw [ArgumentException]::new("${context}: cannot inspect valid version.json data.")
    }
    if ($data.ChangelogFiles.Count -ne 1 -or $data.ChangelogFiles[0].Name -cne 'CHANGELOG.md' -or
        $data.ChangelogFiles[0].PSIsContainer -or
        ($data.ChangelogFiles[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw [ArgumentException]::new("${context}: a regular exact-case changelog file is required.")
    }
    if ($data.ChangelogError) {
        throw [ArgumentException]::new("${context}: changelog is unreadable as UTF-8: $($data.ChangelogError)")
    }
    if (@($data.Headings | Where-Object { $null -eq $_.Version }).Count -gt 0) {
        throw [ArgumentException]::new("${context}: release headings must use '## MAJOR.MINOR.PATCH'.")
    }
    $heading = "^## $([regex]::Escape($Version))\s*$"
    $releases = @($data.Versions | Where-Object { $_.Text -cmatch $heading })
    if ($releases.Count -ne 1) {
        throw [ArgumentException]::new("${context}: exactly one expected-version section is required.")
    }
    $sections = $releases[0].Sections
    foreach ($section in $sections) {
        if ($section.Positions.Count -ne 1 -or
            @($section.Content | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
            throw [ArgumentException]::new("${context}: exactly one nonempty '$($section.Name)' section is required.")
        }
    }
    if ($sections[0].Positions[0] -ge $sections[1].Positions[0]) {
        throw [ArgumentException]::new("${context}: Changes must precede Breaking Changes.")
    }
}

function Initialize-AvmBicepWorkflowMatrixInternal {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAlignAssignmentStatement', '',
        Justification = 'The output fields preserve the established workflow-output contract.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [ValidateSet('push', 'pull_request', 'workflow_dispatch')] [string] $EventName,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [string] $PullRequestHeadCommit,
        [string] $ModulePaths,
        [bool] $CreateReleaseTag = $false,
        [bool] $PublishOnly = $false,
        [bool] $StaticValidation = $true,
        [bool] $DeploymentValidation = $true,
        [bool] $RemoveDeployment = $true,
        [string] $CustomLocation
    )

    if ($TargetCommit -cnotmatch '^[0-9a-f]{40}$' -or
        ($EventName -eq 'push' -and -not [string]::IsNullOrEmpty($BaseCommit) -and $BaseCommit -cnotmatch '^[0-9a-f]{40}$')) {
        throw [ArgumentException]::new('Workflow commits must be full SHA-1 commit identifiers.')
    }
    if ($EventName -eq 'pull_request' -and $PullRequestHeadCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw [ArgumentException]::new('The pull request head must be a full SHA-1 commit identifier.')
    }
    if ($PublishOnly -and -not $CreateReleaseTag) {
        throw [ArgumentException]::new('publishOnly requires createReleaseTag.')
    }
    if ($CreateReleaseTag -and -not $PublishOnly -and (-not $StaticValidation -or -not $DeploymentValidation)) {
        throw [ArgumentException]::new('createReleaseTag requires staticValidation and deploymentValidation unless publishOnly is selected.')
    }
    $head = (Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('rev-parse', 'HEAD')).StdOut.Trim()
    if ($head -cne $TargetCommit) {
        throw [InvalidOperationException]::new('Module discovery requires the checkout to match targetCommit exactly.')
    }
    $includeAll = $false
    if ($EventName -eq 'workflow_dispatch') {
        $matrix = Get-AvmBicepWorkflowModuleMatrixInternal -Root $Root -ModulePaths $ModulePaths
        $BaseCommit = ''
    }
    else {
        if ($EventName -eq 'pull_request') {
            $history = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('rev-list', '--parents', '-n', '1', $TargetCommit, '--') -AllowFailure
            $records = @($history.StdOut -split '\r?\n' | Where-Object { $_ -cne '' })
            if ($history.ExitCode -ne 0 -or $records.Count -ne 1) {
                throw [InvalidOperationException]::new('The tested pull request merge commit is unavailable.')
            }
            $parents = $records[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            if ($parents.Count -ne 3) {
                throw [InvalidOperationException]::new('The tested pull request merge commit must have exactly two parents.')
            }
            if ($parents[0] -cne $TargetCommit -or $parents[1] -cnotmatch '^[0-9a-f]{40}$' -or
                $parents[2] -cnotmatch '^[0-9a-f]{40}$') {
                throw [InvalidOperationException]::new('The tested pull request merge history is malformed.')
            }
            if ($parents[2] -cne $PullRequestHeadCommit) {
                throw [InvalidOperationException]::new('The tested merge second parent does not match the pull request head.')
            }
            $BaseCommit = $parents[1]
        }
        $available = -not [string]::IsNullOrEmpty($BaseCommit) -and $BaseCommit -notmatch '^0+$'
        if ($available) {
            $available = (Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('cat-file', '-e', "${BaseCommit}^{commit}") -AllowFailure).ExitCode -eq 0
            if (-not $available) {
                $fetch = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('fetch', '--no-tags', 'origin', $BaseCommit) -Remote -AllowFailure
                if ($fetch.ExitCode -eq 0) {
                    $available = (Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('cat-file', '-e', "${BaseCommit}^{commit}") -AllowFailure).ExitCode -eq 0
                }
            }
        }
        if (-not $available -and $EventName -eq 'pull_request') {
            throw [InvalidOperationException]::new('The pull request base commit is unavailable.')
        }
        if ($available) {
            $git = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @(
                'diff', '--no-renames', '--name-only', '--diff-filter=ACMRTD', $BaseCommit, $TargetCommit, '--', 'avm')
        }
        else {
            Write-Warning 'The push base is unavailable. Selecting all current modules for static validation and release preview only.'
            $git = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('ls-tree', '-r', '--name-only', $TargetCommit, '--', 'avm')
            $BaseCommit = ''
            $includeAll = $true
            $DeploymentValidation = $false
        }
        $changedFiles = @($git.StdOut -split '\r?\n' | Where-Object { $_ -cne '' })
        $matrix = Get-AvmBicepWorkflowModuleMatrixInternal -Root $Root -ChangedFiles $changedFiles `
            -ExcludeMetadataChanges:($EventName -ne 'pull_request')
    }
    return @{
        baseCommit = $BaseCommit
        targetCommit = $TargetCommit
        hasModules = ($matrix.include.Count -gt 0).ToString().ToLowerInvariant()
        includeAllVersionedModules = $includeAll.ToString().ToLowerInvariant()
        moduleMatrix = ConvertTo-Json -InputObject $matrix -Depth 10 -Compress
        workflowInput = ConvertTo-Json -InputObject @{
            customLocation = $CustomLocation
            staticValidation = $StaticValidation.ToString().ToLowerInvariant()
            deploymentValidation = $DeploymentValidation.ToString().ToLowerInvariant()
            removeDeployment = $RemoveDeployment.ToString().ToLowerInvariant()
        } -Compress
    }
}

function Initialize-AvmBicepReleaseMatrixInternal {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [ValidateSet('workflow_dispatch', 'push')] [string] $EventName,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit
    )

    Assert-AvmBicepWorkflowReleaseContext -Root $Root -TargetCommit $TargetCommit
    $dirty = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('status', '--porcelain', '--untracked-files=all', '--', 'avm')
    if (-not [string]::IsNullOrWhiteSpace($dirty.StdOut)) {
        throw [InvalidOperationException]::new('Release discovery requires module files unchanged from the target commit.')
    }
    if ($EventName -ceq 'push') {
        $paths = @(Get-AvmBicepWorkflowPublishableChangesInternal -Root $Root -ModulePath avm `
                -TargetCommit $TargetCommit -BaseCommit $BaseCommit)
    }
    else {
        $paths = @(Get-AvmBicepWorkflowPendingReleasePlanInternal -Root $Root -ModulePath avm -TargetCommit $TargetCommit |
                ForEach-Object { $_.ModulePath })
    }
    $modules = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $paths) {
        $match = [regex]::Match($path, '^(avm/(?:res|ptn|utl)/[a-z0-9-]+/[a-z0-9-]+)(?:/|$)')
        if ($match.Success) {
            $null = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath "$($match.Groups[1].Value)/main.bicep"
            $null = $modules.Add($match.Groups[1].Value)
        }
    }
    if ($modules.Count -gt 256) {
        throw [InvalidOperationException]::new('The release selection exceeds the 256-job matrix limit.')
    }
    return @{ include = @(foreach ($path in $modules) { @{ modulePath = $path } }) }
}

function Set-AvmBicepReleaseTagsInternal {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAlignAssignmentStatement', '',
        Justification = 'Proposal fields preserve the established release result contract.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseConsistentIndentation', '',
        Justification = 'The nested process environment hashtable is indented for readable argument grouping.')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TargetCommit,
        [string] $BaseCommit,
        [switch] $Force,
        [switch] $IncludeAllVersionedModules,
        [switch] $PendingRelease,
        [switch] $RequireChangelog
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
    Assert-AvmBicepWorkflowReleaseContext -Root $Root -TargetCommit $TargetCommit
    $module = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath $ModulePath
    $dirty = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('status', '--porcelain', '--untracked-files=all', '--', $ModulePath)
    if (-not [string]::IsNullOrWhiteSpace($dirty.StdOut)) {
        throw [InvalidOperationException]::new('Release module files must be unchanged from the target commit.')
    }
    if (-not $PendingRelease -and [string]::IsNullOrEmpty($BaseCommit)) {
        $parent = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('rev-parse', '--verify', "${TargetCommit}^") -AllowFailure
        if ($parent.ExitCode -eq 0) { $BaseCommit = $parent.StdOut.Trim() }
    }
    elseif ($BaseCommit) {
        $available = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('cat-file', '-e', "${BaseCommit}^{commit}") -AllowFailure
        if ($available.ExitCode -ne 0) {
            $null = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('fetch', '--no-tags', 'origin', $BaseCommit) -Remote
            $null = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('cat-file', '-e', "${BaseCommit}^{commit}")
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
        foreach ($relative in Get-AvmBicepWorkflowPublishableChangesInternal -Root $Root -ModulePath $ModulePath `
                -BaseCommit $BaseCommit -TargetCommit $TargetCommit) {
            $null = $candidates.Add($relative)
        }
    }
    if ($Force) {
        foreach ($file in @('main.json', 'version.json')) {
            $null = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath "$ModulePath/$file"
        }
        $null = $candidates.Add($ModulePath)
    }
    $plan = if ($PendingRelease) {
        @(Get-AvmBicepWorkflowPendingReleasePlanInternal -Root $Root -ModulePath $ModulePath -TargetCommit $TargetCommit)
    }
    else {
        @(foreach ($relative in @($candidates | Sort-Object @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_ } })) {
                [pscustomobject]@{ ModulePath = $relative; BaseCommit = $BaseCommit }
            })
    }
    $proposals = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $plan) {
        $relative = $candidate.ModulePath
        $candidateBase = $candidate.BaseCommit
        $versionPath = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath "$relative/version.json"
        $version = (ConvertFrom-Json -InputObject (Get-Content -LiteralPath $versionPath -Raw)).version
        if ($version -isnot [string] -or $version -cnotmatch '^\d+\.\d+$') {
            throw [ArgumentException]::new("The version file for $relative must contain MAJOR.MINOR.")
        }
        $remoteTags = Get-AvmBicepWorkflowRemoteTags -Root $Root -Pattern "$relative/$version.*"
        $valid = @($remoteTags.Keys | Where-Object { $_ -cmatch "^$([regex]::Escape("$relative/$version."))\d+$" })
        $existing = @($valid | Where-Object { $remoteTags[$_] -ceq $TargetCommit } |
                Sort-Object { [version]($_.Substring($_.LastIndexOf('/') + 1)) } -Descending)
        $reused = $existing.Count -gt 0
        if ($reused) { $tag = $existing[0] }
        else {
            $changedVersion = $false
            if (-not [string]::IsNullOrEmpty($candidateBase)) {
                $previous = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('show', "${candidateBase}:$relative/version.json") -AllowFailure
                $changedVersion = $previous.ExitCode -ne 0 -or (ConvertFrom-Json -InputObject $previous.StdOut).version -cne $version
            }
            $patch = 0
            if (-not $changedVersion -and $valid.Count -gt 0) {
                $patch = 1 + ($valid | ForEach-Object { [int]$_.Substring($_.LastIndexOf('.') + 1) } |
                        Measure-Object -Maximum).Maximum
            }
            $tag = "$relative/$version.$patch"
        }
        $null = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('check-ref-format', "refs/tags/$tag")
        if ($remoteTags.ContainsKey($tag) -and $remoteTags[$tag] -cne $TargetCommit) {
            throw [InvalidOperationException]::new("Release tag $tag already points to a different commit.")
        }
        $proposals.Add([pscustomobject]@{ Module = $relative; Tag = $tag; Commit = $TargetCommit; Reused = $reused; Created = $false })
    }
    if ($RequireChangelog) {
        foreach ($proposal in $proposals) {
            Assert-AvmBicepWorkflowReleaseChangelog -Root $Root -ModulePath $proposal.Module `
                -Version $proposal.Tag.Substring($proposal.Module.Length + 1)
        }
    }
    foreach ($proposal in $proposals) {
        if ($proposal.Reused -or -not $PSCmdlet.ShouldProcess("$($proposal.Tag) at $TargetCommit", 'Create and push module release tag')) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
            throw [InvalidOperationException]::new('The release-tag job requires its scoped GitHub token.')
        }
        $local = Invoke-AvmBicepWorkflowGit -Root $Root -Arguments @('rev-parse', '-q', '--verify', "refs/tags/$($proposal.Tag)^{}") -AllowFailure
        if ($local.ExitCode -eq 0 -and $local.StdOut.Trim() -cne $TargetCommit) {
            throw [InvalidOperationException]::new("Local tag $($proposal.Tag) points to a different commit.")
        }
        $git = (Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        if ($local.ExitCode -ne 0) {
            $null = Invoke-AvmProcess -FilePath $git -WorkingDirectory $Root -ArgumentList @('tag', $proposal.Tag, $TargetCommit)
        }
        $authorization = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$env:GITHUB_TOKEN"))
        $confirmed = $false
        $pushEnvironment = @{
            GIT_TERMINAL_PROMPT = '0'
            GIT_CONFIG_COUNT = '1'
            GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
            GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $authorization"
        }
        try {
            $push = Invoke-AvmProcess -FilePath $git -WorkingDirectory $Root `
                -ArgumentList @('push', 'origin', "refs/tags/$($proposal.Tag):refs/tags/$($proposal.Tag)") -IgnoreExitCode `
                -EnvVars $pushEnvironment
            $confirmed = $push.ExitCode -eq 0
        }
        catch [TimeoutException] {
            Write-Warning "Publishing $($proposal.Tag) timed out; checking the remote result without replaying the push."
        }
        if (-not $confirmed) {
            $reconciled = Get-AvmBicepWorkflowRemoteTags -Root $Root -Pattern "$($proposal.Tag)*"
            if (-not $reconciled.ContainsKey($proposal.Tag) -or $reconciled[$proposal.Tag] -cne $TargetCommit) {
                throw [InvalidOperationException]::new("Publishing $($proposal.Tag) failed; no mutation was retried.")
            }
        }
        $proposal.Created = $true
    }
    return $proposals.ToArray()
}

function Get-AvmBicepWorkflowModuleIdentityInternal {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAlignAssignmentStatement', '',
        Justification = 'Identity field names preserve the public E2E context contract.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ModuleClientIds,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $TenantId
    )

    if ([string]::IsNullOrWhiteSpace($ModuleClientIds)) {
        throw [ArgumentException]::new('ModuleClientIds must contain the published module client-ID mapping; no shared identity fallback is supported.')
    }
    try {
        $mapping = ConvertFrom-AvmStrictJson -Json $ModuleClientIds -RejectCaseInsensitiveDuplicates
    }
    catch [System.Exception] {
        throw [ArgumentException]::new('ModuleClientIds is invalid; require unique canonical root paths and distinct nonempty client GUIDs.', $_.Exception)
    }
    if ($mapping -isnot [Collections.IDictionary]) {
        throw [ArgumentException]::new('ModuleClientIds must be a JSON object.')
    }
    $clients = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $mapping.Keys) {
        $id = [guid]::Empty
        if ($key -cnotmatch '^avm/(?:res|ptn|utl)/[a-z0-9-]+/[a-z0-9-]+$' -or
            $mapping[$key] -isnot [string] -or -not [guid]::TryParseExact($mapping[$key], 'D', [ref]$id) -or
            $id -eq [guid]::Empty -or -not $clients.Add($id.ToString('D'))) {
            throw [ArgumentException]::new('ModuleClientIds is invalid; require unique canonical root paths and distinct nonempty client GUIDs.')
        }
    }
    $path = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath $ModulePath
    $relative = $ModulePath.Replace('\', '/')
    if ([IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root), $path).Replace('\', '/') -cne $relative) {
        throw [ArgumentException]::new('The module path must be canonical without empty or current-directory segments.')
    }
    $roots = @($mapping.Keys | Where-Object { $relative -ceq $_ -or $relative.StartsWith("$_/", [StringComparison]::Ordinal) })
    if ($roots.Count -ne 1) {
        throw [ArgumentException]::new("ModuleClientIds must contain exactly one canonical root for '$relative'.")
    }
    $tenant = [guid]::Empty
    if (-not [guid]::TryParseExact($TenantId, 'D', [ref]$tenant) -or $tenant -eq [guid]::Empty) {
        throw [ArgumentException]::new('TenantId must be the nonempty GUID published with the module identity mapping.')
    }
    $client = ([guid]$mapping[$roots[0]]).ToString('D')
    return [pscustomobject]@{
        ModuleRoot = $roots[0]
        ClientId = $client
        TenantId = $tenant.ToString('D')
        IdentityKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes("$($roots[0])|$client|$($tenant.ToString('D'))"))).ToLowerInvariant()
    }
}

function Select-AvmBicepWorkflowDeploymentSubscriptionInternal {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $Example,
        [AllowEmptyString()] [string] $PoolJson,
        [AllowEmptyString()] [string] $FallbackSubscriptionId,
        [ValidateRange(0, [int]::MaxValue)] [int] $RandomSeed = 0,
        [ValidateRange(0, [int]::MaxValue)] [int] $CaseIndex = 0
    )

    if ([string]::IsNullOrEmpty($PoolJson)) {
        $PoolJson = ConvertTo-Json -InputObject @(@{ id = $FallbackSubscriptionId; name = 'Configured subscription 1' }) -Compress
    }
    $selected = @(Select-AvmTestSubscription -Path $Root -ModulePath $ModulePath -Example $Example `
            -TestSubscriptionIds $PoolJson -RandomSeed $RandomSeed -CaseIndex $CaseIndex -SkipModuleVersionCheck)
    if ($selected.Count -ne 1) {
        throw [InvalidOperationException]::new('Native subscription selection must return exactly one eligible target.')
    }
    if ($selected[0].Tag -cne 'General') {
        throw [InvalidOperationException]::new('Reserved test subscriptions require the registry-local prepared environment lifecycle; shared native deployment cannot authenticate or execute this case.')
    }
    $ownerPath = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath $selected[0].ModulePath
    $null = Get-AvmModuleContext -Path $ownerPath -Ecosystem bicep -SkipModuleVersionCheck
    return $selected[0]
}

function Get-AvmBicepWorkflowCompiledTestInternal {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TestPath,
        [scriptblock] $ToolResolver,
        [scriptblock] $ToolInstaller,
        [scriptblock] $ProcessInvoker
    )

    $module = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath $ModulePath
    $tool = if ($null -ne $ToolResolver) {
        & $ToolResolver -Name bicep -Path $module
    }
    else {
        Get-AvmTool -Name bicep -Path $module -SkipModuleVersionCheck
    }
    if ($tool.Status -ceq 'not-installed') {
        if ($null -ne $ToolInstaller) {
            $null = & $ToolInstaller -Name bicep -Path $module
        }
        else {
            $null = Install-AvmTool -Name bicep -Path $module -SkipModuleVersionCheck -Confirm:$false
        }
        $tool = if ($null -ne $ToolResolver) {
            & $ToolResolver -Name bicep -Path $module
        }
        else {
            Get-AvmTool -Name bicep -Path $module -SkipModuleVersionCheck
        }
    }
    if ($tool.Status -cne 'installed') { throw [InvalidOperationException]::new('The managed Bicep compiler is not installed.') }
    $path = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath "$ModulePath/$TestPath"
    $result = if ($null -ne $ProcessInvoker) {
        & $ProcessInvoker -FilePath $tool.Path -ArgumentList @('build', $path, '--stdout') -WorkingDirectory $Root
    }
    else {
        Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('build', $path, '--stdout') -WorkingDirectory $Root
    }
    $template = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable
    if ($template -isnot [Collections.IDictionary]) { throw [ArgumentException]::new('The compiled test must be an ARM template object.') }
    return [string]$result.StdOut
}

function Get-AvmBicepWorkflowIsolationInternal {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAlignAssignmentStatement', '',
        Justification = 'Isolation fields preserve the public E2E context contract.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [string] $TestPath,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $CompiledTemplate,
        [Parameter(Mandatory)] [string] $FallbackGroup
    )

    $casePath = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath "$ModulePath/$TestPath"
    $directory = Split-Path -Path $casePath -Parent
    $fallback = [pscustomobject]@{
        IsolationMode = 'fallback'
        IsolationBoundary = ''
        ConcurrencyGroup = $FallbackGroup
        FallbackModuleLock = Test-AvmBicepWorkflowLegacyModuleLockInternal -Template (ConvertFrom-Json -InputObject $CompiledTemplate -AsHashtable)
        IsolationDiagnostic = 'Isolation is not established: no case-local isolation.json. Retaining legacy fallback serialization, not claiming ownership.'
    }
    $manifestPath = Join-Path $directory 'isolation.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $fallback }
    try {
        $contract = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifestPath, [Text.UTF8Encoding]::new($false, $true))) -AsHashtable
    }
    catch [System.Exception] {
        throw [ArgumentException]::new('Isolation evidence must be valid UTF-8 JSON.', $_.Exception)
    }
    if ($contract -isnot [Collections.IDictionary] -or
        @($contract.Keys | Where-Object { $_ -cnotin @('version', 'evidence', 'sharedTarget') }).Count -gt 0 -or
        ($contract['version'] -isnot [long] -and $contract['version'] -isnot [int]) -or $contract['version'] -ne 1 -or
        $contract['evidence'] -isnot [Collections.IDictionary] -or
        @($contract['evidence'].Keys | Where-Object { $_ -notin @('resources', 'cleanup', 'sharedState', 'identity') }).Count -gt 0 -or
        $contract['evidence'].Count -ne 4) {
        throw [ArgumentException]::new('Isolation requires version 1 and four reviewed ownership evidence fields.')
    }
    foreach ($name in @('resources', 'cleanup', 'sharedState', 'identity')) {
        if ($contract['evidence'][$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($contract['evidence'][$name])) {
            throw [ArgumentException]::new("Isolation evidence must explain '$name'.")
        }
    }
    $template = ConvertFrom-Json -InputObject $CompiledTemplate -AsHashtable
    try {
        $boundary = Assert-AvmBicepResourceIsolationTemplate -Template $template
    }
    catch [AvmConfigurationException] {
        $fallback.IsolationDiagnostic = "Isolation ownership is not established: $($_.Exception.Message) Retaining legacy fallback serialization."
        return $fallback
    }
    if (-not $boundary -or (Test-Path -LiteralPath (Join-Path $directory 'post.ps1'))) {
        $fallback.IsolationDiagnostic = 'Isolation ownership is not established. Retaining legacy fallback serialization.'
        return $fallback
    }
    $target = if ($contract.Contains('sharedTarget')) { $contract['sharedTarget'] } else { $null }
    if ($null -ne $target -and ($target -isnot [string] -or
            $target -notmatch '^/(?:subscriptions/|providers/)[A-Za-z0-9_()./#-]+$' -or $target.Contains('//'))) {
        throw [ArgumentException]::new('sharedTarget must identify one absolute ARM resource or singleton setting.')
    }
    if ($null -ne $target) {
        $target = $target.Replace('#_subscriptionId_#', ([guid]$SubscriptionId).ToString('D'))
        if ($target.Contains('#')) { throw [ArgumentException]::new('sharedTarget contains an unsupported token.') }
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes(("azurecloud|$TenantId|$target").ToLowerInvariant()))).ToLowerInvariant()
        return [pscustomobject]@{
            IsolationMode = 'shared'; IsolationBoundary = $boundary; ConcurrencyGroup = "avm-deploy-target-$hash"
            FallbackModuleLock = $false
            IsolationDiagnostic = 'Reviewed isolation with an explicit shared-target lifecycle lock.'
        }
    }
    return [pscustomobject]@{
        IsolationMode = 'isolated'; IsolationBoundary = $boundary
        ConcurrencyGroup = 'avm-deploy-isolated-' + [guid]::NewGuid().ToString('N')
        FallbackModuleLock = $false
        IsolationDiagnostic = 'Reviewed resource and cleanup isolation: no serialization lock required.'
    }
}

function Get-AvmBicepE2eDeploymentMatrixInternal {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAlignAssignmentStatement', '',
        Justification = 'Matrix field names preserve the public E2E context contract.')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $TestFiles,
        [AllowEmptyString()] [string] $PoolJson,
        [AllowEmptyString()] [string] $FallbackSubscriptionId,
        [AllowEmptyString()] [string] $ModuleClientIds,
        [AllowEmptyString()] [string] $TenantId,
        [ValidateRange(0, [int]::MaxValue)] [int] $RandomSeed = 0,
        [switch] $DisplaySubscriptionNames,
        [scriptblock] $ToolResolver,
        [scriptblock] $ToolInstaller,
        [scriptblock] $ProcessInvoker
    )

    $active = @($TestFiles | Where-Object { -not (ConvertTo-AvmBicepWorkflowBooleanInternal -Value $_.e2eIgnore) })
    $identity = if ($active.Count -gt 0) {
        Get-AvmBicepWorkflowModuleIdentityInternal -Root $Root -ModulePath $ModulePath -ModuleClientIds $ModuleClientIds -TenantId $TenantId
    }
    $moduleKey = $ModulePath.Replace('\', '/').Trim('/').ToLowerInvariant()
    $selections = @{}
    for ($index = 0; $index -lt $TestFiles.Count; $index++) {
        $test = $TestFiles[$index]
        if (-not (ConvertTo-AvmBicepWorkflowBooleanInternal -Value $test.e2eIgnore)) {
            $selections[$index] = Select-AvmBicepWorkflowDeploymentSubscriptionInternal -Root $Root -ModulePath $ModulePath `
                -Example $test.path -PoolJson $PoolJson -FallbackSubscriptionId $FallbackSubscriptionId `
                -RandomSeed $RandomSeed -CaseIndex $index
        }
    }
    $result = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $TestFiles.Count; $index++) {
        $test = $TestFiles[$index]
        if ($test.path -isnot [string] -or $test.name -isnot [string] -or [string]::IsNullOrWhiteSpace($test.name)) {
            throw [ArgumentException]::new('Every deployment test must contain a path and a single-line name.')
        }
        $ignored = ConvertTo-AvmBicepWorkflowBooleanInternal -Value $test.e2eIgnore
        if ($ignored) {
            $result.Add([pscustomobject]@{
                    Path = $test.path; Name = $test.name; E2eIgnore = $true; SubscriptionIndex = $null; SubscriptionKey = ''
                    SelectionSeed = $null; CaseIndex = $index; SubscriptionModulePath = ''; IdentityKey = ''
                    SubscriptionName = 'Deployment disabled'; ConcurrencyGroup = "avm-deploy-$moduleKey-ignored-$([guid]::NewGuid().ToString('N'))"
                    IsolationMode = 'ignored'; IsolationBoundary = ''; IsolationDiagnostic = 'Deployment disabled.'
                    FallbackModuleLock = $false
                })
            continue
        }
        $selected = $selections[$index]
        $compiled = Get-AvmBicepWorkflowCompiledTestInternal -Root $Root -ModulePath $ModulePath -TestPath $test.path `
            -ToolResolver $ToolResolver -ToolInstaller $ToolInstaller -ProcessInvoker $ProcessInvoker
        $isolation = Get-AvmBicepWorkflowIsolationInternal -Root $Root -ModulePath $ModulePath -TestPath $test.path `
            -TenantId $identity.TenantId -SubscriptionId $selected.SubscriptionId -CompiledTemplate $compiled `
            -FallbackGroup "avm-deploy-$moduleKey-$($selected.Key)"
        $result.Add([pscustomobject]@{
                Path = $test.path; Name = $test.name; E2eIgnore = $false; SubscriptionIndex = $selected.Index; SubscriptionKey = $selected.Key
                SelectionSeed = $RandomSeed; CaseIndex = $index; SubscriptionModulePath = $selected.ModulePath; IdentityKey = $identity.IdentityKey
                SubscriptionName = if ($DisplaySubscriptionNames) { $selected.Name } else { "Configured subscription $($selected.Index + 1)" }
                IsolationMode = $isolation.IsolationMode; ConcurrencyGroup = $isolation.ConcurrencyGroup
                IsolationBoundary = $isolation.IsolationBoundary; IsolationDiagnostic = $isolation.IsolationDiagnostic
                FallbackModuleLock = $isolation.FallbackModuleLock
            })
    }
    $legacyModuleLock = @($result | Where-Object { $_.IsolationMode -eq 'fallback' -and $_.FallbackModuleLock }).Count -gt 0
    foreach ($entry in $result) {
        if ($entry.IsolationMode -eq 'fallback') { $entry.FallbackModuleLock = $legacyModuleLock }
    }
    return $result.ToArray()
}

function Get-AvmBicepWorkflowTestCaseValueInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $TestCase,
        [Parameter(Mandatory)] [string] $Name,
        [switch] $Optional
    )

    if ($TestCase -is [Collections.IDictionary]) {
        $key = @($TestCase.Keys | Where-Object { $_ -ieq $Name } | Select-Object -First 1)
        if ($key.Count -eq 1) { return $TestCase[$key[0]] }
        if ($Optional) { return $null }
        throw [ArgumentException]::new("The selected test case does not contain '$Name'. Rerun selection.")
    }
    $property = $TestCase.PSObject.Properties[$Name]
    if ($null -eq $property -and $Optional) { return $null }
    if ($null -eq $property) {
        throw [ArgumentException]::new("The selected test case does not contain '$Name'. Rerun selection.")
    }
    return $property.Value
}

function Get-AvmBicepWorkflowSubscriptionCleanupManagementGroupInternal {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ModuleRoot,
        [AllowEmptyString()] [string] $ModuleSubscriptionCleanupManagementGroupIds
    )

    if ([string]::IsNullOrWhiteSpace($ModuleSubscriptionCleanupManagementGroupIds)) { return '' }
    try {
        $mapping = ConvertFrom-AvmStrictJson -Json $ModuleSubscriptionCleanupManagementGroupIds -RejectCaseInsensitiveDuplicates
    }
    catch [System.Exception] {
        throw [ArgumentException]::new('Module subscription cleanup management groups must be valid JSON.', $_.Exception)
    }
    $root = 'avm/ptn/lz/sub-vending'
    if ($mapping -isnot [Collections.IDictionary] -or $mapping.Count -gt 1 -or
        ($mapping.Count -eq 1 -and -not $mapping.Contains($root)) -or
        ($mapping.Contains($root) -and (
            $mapping[$root] -isnot [string] -or
            $mapping[$root] -cnotmatch '^[A-Za-z0-9_().-]{1,90}$' -or
            $mapping[$root] -in @('.', '..') -or $mapping[$root].EndsWith('.')))) {
        throw [ArgumentException]::new('Module subscription cleanup management groups must contain only one valid canonical target.')
    }
    if ($ModuleRoot -ceq $root) { return [string]$mapping[$root] }
    return ''
}

function Get-AvmBicepE2eTestContextInternal {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [object] $TestCase,
        [AllowEmptyString()] [string] $PoolJson,
        [AllowEmptyString()] [string] $FallbackSubscriptionId,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ModuleClientIds,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $TenantId,
        [AllowEmptyString()] [string] $ModuleSubscriptionCleanupManagementGroupIds,
        [AllowEmptyString()] [string] $NamePrefix,
        [scriptblock] $ToolResolver,
        [scriptblock] $ToolInstaller,
        [scriptblock] $ProcessInvoker
    )

    $identity = Get-AvmBicepWorkflowModuleIdentityInternal -Root $Root -ModulePath $ModulePath -ModuleClientIds $ModuleClientIds -TenantId $TenantId
    $subscriptionCleanupManagementGroupId = Get-AvmBicepWorkflowSubscriptionCleanupManagementGroupInternal `
        -ModuleRoot $identity.ModuleRoot -ModuleSubscriptionCleanupManagementGroupIds $ModuleSubscriptionCleanupManagementGroupIds
    $caseIdentityKey = Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name IdentityKey -Optional
    if ($caseIdentityKey -cne $identity.IdentityKey) { throw [ArgumentException]::new('The selected module identity no longer matches its root, client and tenant. Rerun selection.') }
    $seed = [int](Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name SelectionSeed)
    $index = [int](Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name CaseIndex)
    $path = Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name Path
    $selected = Select-AvmBicepWorkflowDeploymentSubscriptionInternal -Root $Root -ModulePath $ModulePath -Example $path `
        -PoolJson $PoolJson -FallbackSubscriptionId $FallbackSubscriptionId -RandomSeed $seed -CaseIndex $index
    $caseSubscriptionIndex = Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name SubscriptionIndex -Optional
    $caseSubscriptionKey = Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name SubscriptionKey
    $caseSubscriptionModulePath = Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name SubscriptionModulePath
    if ($null -eq $caseSubscriptionIndex -or $selected.Index -ne [int]$caseSubscriptionIndex -or $selected.Key -cne $caseSubscriptionKey -or
        $selected.ModulePath -cne $caseSubscriptionModulePath) {
        throw [ArgumentException]::new('The selected subscription no longer matches the original pool index and digest. Rerun selection.')
    }
    $testPath = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath "$ModulePath/$path"
    $ownerPath = Resolve-AvmBicepWorkflowPath -Root $Root -RelativePath $selected.ModulePath
    $example = [IO.Path]::GetRelativePath($ownerPath, $testPath).Replace('\', '/')
    $compiled = Get-AvmBicepWorkflowCompiledTestInternal -Root $Root -ModulePath $ModulePath -TestPath $path `
        -ToolResolver $ToolResolver -ToolInstaller $ToolInstaller -ProcessInvoker $ProcessInvoker
    $caseConcurrencyGroup = Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name ConcurrencyGroup
    $caseIsolationMode = Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name IsolationMode
    $caseFallbackModuleLock = Get-AvmBicepWorkflowTestCaseValueInternal -TestCase $TestCase -Name FallbackModuleLock -Optional
    $moduleKey = $ModulePath.Replace('\', '/').Trim('/').ToLowerInvariant()
    $fallbackGroup = "avm-deploy-$moduleKey-$($selected.Key)"
    $isolation = Get-AvmBicepWorkflowIsolationInternal -Root $Root -ModulePath $ModulePath -TestPath $path `
        -TenantId $identity.TenantId -SubscriptionId $selected.SubscriptionId -CompiledTemplate $compiled `
        -FallbackGroup $fallbackGroup
    if ($isolation.IsolationMode -cne $caseIsolationMode -or
        ($isolation.IsolationMode -ne 'isolated' -and $isolation.ConcurrencyGroup -cne $caseConcurrencyGroup) -or
        ($isolation.IsolationMode -eq 'fallback' -and $isolation.FallbackModuleLock -and $caseFallbackModuleLock -ne $true) -or
        ($isolation.IsolationMode -eq 'isolated' -and $caseConcurrencyGroup -cnotmatch '^avm-deploy-isolated-[0-9a-f]{32}$')) {
        throw [ArgumentException]::new('Isolation evidence or lifecycle lock changed after selection. Rerun selection before authentication.')
    }
    $prefix = Get-AvmBicepWorkflowNamePrefixInternal -IsolationMode $isolation.IsolationMode -Prefix $NamePrefix
    return [pscustomobject]@{
        SubscriptionId = $selected.SubscriptionId; TenantId = $identity.TenantId; ClientId = $identity.ClientId
        ModulePath = $selected.ModulePath; Example = $example; NamePrefix = $prefix
        ArtifactKey = "bicep-e2e-$($selected.Key)-$index"; IsolationMode = $isolation.IsolationMode
        ConcurrencyGroup = $isolation.ConcurrencyGroup; RequireResourceIsolation = $isolation.IsolationMode -ne 'fallback'
        SubscriptionCleanupManagementGroupId = $subscriptionCleanupManagementGroupId
    }
}
