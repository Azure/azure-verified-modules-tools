. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-AvmWorkflowInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $WorkflowPath,
        [Parameter(Mandatory)] [string] $EventName,
        [string] $EventInputs = '{}'
    )

    $path = Resolve-AvmWorkflowPath -Root $Root -RelativePath $WorkflowPath
    $parameters = @{}
    if ($EventName -eq 'workflow_dispatch') {
        $parameters = ConvertFrom-Json -InputObject $EventInputs -AsHashtable -NoEnumerate
        if ($parameters -isnot [Collections.IDictionary]) {
            throw [ArgumentException]::new('Workflow dispatch inputs must be a JSON object.')
        }
    }
    else {
        Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
        $workflow = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $path -Raw)
        foreach ($entry in $workflow.on.workflow_dispatch.inputs.GetEnumerator()) {
            $parameters[$entry.Key] = $entry.Value['default']
        }
    }
    $result = [ordered]@{}
    foreach ($key in $parameters.Keys) {
        $value = $parameters[$key]
        if ($null -eq $value -or [string]$value -ceq '') { continue }
        $result[$key] = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } else { [string]$value }
    }
    return ConvertTo-Json -InputObject $result -Compress
}

function Get-AvmWorkflowTestFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $ModulePath,
        [string] $PsRuleFilterRegex = '(defaults|waf-aligned)'
    )

    $module = Resolve-AvmWorkflowPath -Root $Root -RelativePath $ModulePath
    $filter = [regex]::new($PsRuleFilterRegex, [Text.RegularExpressions.RegexOptions]::None,
        [TimeSpan]::FromSeconds(1))
    $files = @(Get-ChildItem -LiteralPath $module -Recurse -File -Filter 'main.test.bicep' |
            Sort-Object FullName | ForEach-Object {
                $relative = [IO.Path]::GetRelativePath($module, $_.FullName).Replace('\', '/')
                $null = Resolve-AvmWorkflowPath -Root $module -RelativePath $relative
                @{
                    path = $relative
                    name = $_.Directory.Name
                    e2eIgnore = Test-Path -LiteralPath (Join-Path $_.Directory.FullName '.e2eignore')
                }
            })
    $policyFiles = @($files | Where-Object { $filter.IsMatch($_.path) } |
            ForEach-Object { @{ path = $_.path; name = $_.name } })
    return @{
        moduleTestFilePaths = ConvertTo-Json -InputObject $files -Compress
        psRuleModuleTestFilePaths = ConvertTo-Json -InputObject $policyFiles -Compress
    }
}

function Get-AvmWorkflowModuleMatrix {
    [CmdletBinding(DefaultParameterSetName = 'Changed')]
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
        $source = Resolve-AvmWorkflowPath -Root $Root -RelativePath "$modulePath/main.bicep" -AllowMissing
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
            $entry = Get-AvmWorkflowTestFiles -Root $Root -ModulePath $modulePath
            $entry.modulePath = $modulePath
            $entry
        })
    return @{ include = $entries }
}

function Initialize-AvmWorkflowMatrix {
    [CmdletBinding()]
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
    $head = (Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('rev-parse', 'HEAD')).StdOut.Trim()
    if ($head -cne $TargetCommit) {
        throw [InvalidOperationException]::new('Module discovery requires the checkout to match targetCommit exactly.')
    }
    $includeAll = $false
    if ($EventName -eq 'workflow_dispatch') {
        $matrix = Get-AvmWorkflowModuleMatrix -Root $Root -ModulePaths $ModulePaths
        $BaseCommit = ''
    }
    else {
        if ($EventName -eq 'pull_request') {
            $history = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('rev-list', '--parents', '-n', '1', $TargetCommit, '--') -AllowFailure
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
            $available = (Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('cat-file', '-e', "${BaseCommit}^{commit}") -AllowFailure).ExitCode -eq 0
            if (-not $available) {
                $fetch = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('fetch', '--no-tags', 'origin', $BaseCommit) -Remote -AllowFailure
                if ($fetch.ExitCode -eq 0) {
                    $available = (Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('cat-file', '-e', "${BaseCommit}^{commit}") -AllowFailure).ExitCode -eq 0
                }
            }
        }
        if (-not $available -and $EventName -eq 'pull_request') {
            throw [InvalidOperationException]::new('The pull request base commit is unavailable.')
        }
        if ($available) {
            $git = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @(
                'diff', '--no-renames', '--name-only', '--diff-filter=ACMRTD', $BaseCommit, $TargetCommit, '--', 'avm')
        }
        else {
            Write-Warning 'The push base is unavailable. Selecting all current modules for static validation and release preview only.'
            $git = Invoke-AvmWorkflowGitRead -Root $Root -Arguments @('ls-tree', '-r', '--name-only', $TargetCommit, '--', 'avm')
            $BaseCommit = ''
            $includeAll = $true
            $DeploymentValidation = $false
        }
        $changedFiles = @($git.StdOut -split '\r?\n' | Where-Object { $_ -cne '' })
        $matrix = Get-AvmWorkflowModuleMatrix -Root $Root -ChangedFiles $changedFiles `
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
