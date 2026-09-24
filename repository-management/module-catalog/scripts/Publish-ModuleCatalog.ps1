#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string] $BundlePath,
    [switch] $Publish,
    [switch] $Force,
    [string] $DiagnosticsPath,
    [string] $GitHubOutputPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolsRoot = Join-Path $PSScriptRoot '..' '..' '..'
Import-Module -Name (Join-Path $toolsRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
. (Join-Path $PSScriptRoot 'ModuleCatalog.ps1')
. (Join-Path $PSScriptRoot 'ModuleCatalog.Collection.ps1')
. (Join-Path $PSScriptRoot 'ModuleCatalog.Publication.ps1')

$configuration = Read-AvmCatalogConfiguration
$docsJsonPath = 'docs/static/module-indexes/v1/modules.json'
Write-AvmCatalogProgress 'Validating the catalog publication bundle.'
$plan = Test-AvmCatalogPublicationBundle -Path $BundlePath -Configuration $configuration -Force:$Force -DiagnosticsPath $DiagnosticsPath
if (-not $Publish) {
    Write-Output 'Catalog publication plan validated; no remote changes requested.'
    return
}
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:GITHUB_REPOSITORY -cne $configuration.repositories.tools -or
    $env:GITHUB_REF -cne 'refs/heads/main' -or
    $env:GITHUB_RUN_ID -notmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[0-9]+$' -or
    $env:AVM_APP_SLUG -notmatch '^[a-z0-9-]+$' -or -not $env:GH_TOKEN) {
    throw [System.InvalidOperationException]::new('Publication requires the main-branch tools workflow and its scoped app token.')
}
if (-not $PSCmdlet.ShouldProcess($configuration.repositories.docs, 'Publish and merge catalog updates')) {
    return
}

$git = (Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$gh = (Get-Command -Name gh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$state = Join-Path ([System.IO.Path]::GetTempPath()) ('avm-catalog-publish-' + [guid]::NewGuid().ToString('N'))
$null = [System.IO.Directory]::CreateDirectory($state)
$hooks = Join-Path $state 'empty-hooks'
$null = [System.IO.Directory]::CreateDirectory($hooks)
$emptyConfig = Join-Path $state 'empty-gitconfig'
[System.IO.File]::WriteAllText($emptyConfig, '')
$authorEmail = '41898282+github-actions[bot]@users.noreply.github.com'
$botLogin = "$($env:AVM_APP_SLUG)[bot]"
$authorization = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("x-access-token:$($env:GH_TOKEN)"))
# Authentication stays in the child environment, never argv or a persisted git config.
$processEnvironment = @{
    GH_TOKEN = $env:GH_TOKEN; GITHUB_TOKEN = $null
    GH_DEBUG = $null; GIT_TRACE = $null; GIT_TRACE_CURL = $null; GIT_CURL_VERBOSE = $null
    GIT_ASKPASS = $null; SSH_ASKPASS = $null
    GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'Never'
    GIT_CONFIG_NOSYSTEM = '1'; GIT_CONFIG_GLOBAL = $emptyConfig
    GIT_CONFIG_COUNT = '7'
    GIT_CONFIG_KEY_0 = 'core.hooksPath'; GIT_CONFIG_VALUE_0 = $hooks
    GIT_CONFIG_KEY_1 = 'credential.helper'; GIT_CONFIG_VALUE_1 = ''
    GIT_CONFIG_KEY_2 = 'commit.gpgsign'; GIT_CONFIG_VALUE_2 = 'false'
    GIT_CONFIG_KEY_3 = 'http.https://github.com/.extraheader'; GIT_CONFIG_VALUE_3 = "AUTHORIZATION: basic $authorization"
    GIT_CONFIG_KEY_4 = 'user.name'; GIT_CONFIG_VALUE_4 = 'AVM metadata sync'
    GIT_CONFIG_KEY_5 = 'user.email'; GIT_CONFIG_VALUE_5 = $authorEmail
    GIT_CONFIG_KEY_6 = 'core.autocrlf'; GIT_CONFIG_VALUE_6 = 'false'
}
$prepared = [System.Collections.Generic.List[object]]::new()
$docsJsonPublished = $false
$heldBackSourceFiles = Get-AvmCatalogPublicationHeldBackSourceFile -BundlePath $BundlePath -Configuration $configuration
$heldBack = Get-AvmCatalogHeldBackOutput -Configuration $configuration -SourceFile $heldBackSourceFiles
if ($heldBack.Count -gt 0) {
    Write-AvmCatalogProgress ("Skipping {0} held-back output(s): {1}" -f $heldBack.Count, ($heldBack -join ', '))
}
try {
    $paths = Get-AvmCatalogPublicationPaths -Configuration $configuration
    foreach ($role in $paths.Keys) {
        $repository = $paths[$role].repository
        Write-AvmCatalogProgress ("Preparing publication branch for {0}." -f $repository)
        $publishable = @($paths[$role].files.Keys | Where-Object { $_ -cnotin $heldBack })
        $allowed = @($publishable | ForEach-Object { $paths[$role].files[$_] })
        $legacyReport = "$($configuration.destinations[$role].path)/v1/migration-report.json"
        $root = Join-Path $state $role
        $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('clone', '--filter=blob:none', '--no-checkout', '--branch', 'main', "https://github.com/$repository", $root) `
            -WorkingDirectory $state -EnvVars $processEnvironment
        $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('checkout', 'main') -WorkingDirectory $root -EnvVars $processEnvironment
        Assert-AvmCatalogPublicationBase -Root $root -BaseFiles $plan[$role].baseFiles
        $removals = Get-AvmCatalogPublicationRowRemovals -BundlePath $BundlePath -Configuration $configuration -SourceRoot $root
        Assert-AvmCatalogCsvRowRetention -Removals $removals -Force:$Force -DiagnosticsPath $DiagnosticsPath -HeldBackOutput $heldBackSourceFiles
        $response = Invoke-AvmCatalogProcess -FilePath $gh `
            -ArgumentList @('api', '--method', 'GET', '--paginate', '--slurp', "repos/$repository/pulls?state=open&base=main&per_page=100") `
            -WorkingDirectory $root -EnvVars $processEnvironment
        $pages = ConvertFrom-Json -InputObject $response.StdOut -AsHashtable -Depth 100 -NoEnumerate
        $open = @($pages | ForEach-Object { $_ } | Where-Object { $_.head.ref.StartsWith('automation/module-metadata-sync-', [StringComparison]::Ordinal) })
        if ($open.Count -gt 1) {
            throw [System.InvalidOperationException]::new("Multiple catalog branches are awaiting review in $repository; resolve them before publishing.")
        }
        $existing = if ($open.Count -eq 1) { $open[0] } else { $null }
        if ($null -ne $existing) {
            if ($existing.user.login -cne $botLogin -or $existing.head.repo.full_name -cne $repository -or $existing.base.ref -cne 'main') {
                throw [System.Security.SecurityException]::new("Refusing to update a catalog branch not owned by the configured app in $repository.")
            }
            $branch = $existing.head.ref
            if ($branch -cnotmatch '^automation/module-metadata-sync-[a-z0-9-]+$') {
                throw [System.Security.SecurityException]::new('Unexpected catalog branch name.')
            }
            $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('checkout', '-b', $branch, '--track', "origin/$branch") -WorkingDirectory $root -EnvVars $processEnvironment
            $authors = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('log', '--format=%ae', 'origin/main..HEAD') -WorkingDirectory $root -EnvVars $processEnvironment
            if (@($authors.StdOut -split '\r?\n' | Where-Object { $_ -and $_ -cne $authorEmail }).Count -gt 0) {
                throw [System.InvalidOperationException]::new("Catalog branch $branch contains human commits; refusing to overwrite review edits.")
            }
            $diff = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('diff', '--name-only', 'origin/main...HEAD') -WorkingDirectory $root -EnvVars $processEnvironment
            if (@($diff.StdOut -split '\r?\n' | Where-Object { $_ -and $_ -cnotin ($allowed + $legacyReport) }).Count -gt 0) {
                throw [System.Security.SecurityException]::new("Catalog branch $branch contains changes outside the publication allow-list.")
            }
            $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('merge', '--no-edit', 'origin/main') -WorkingDirectory $root -EnvVars $processEnvironment
            Assert-AvmCatalogSafePath -Root $root -RelativePath $legacyReport
            $baseReport = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('ls-tree', '--name-only', 'origin/main', '--', $legacyReport) `
                -WorkingDirectory $root -EnvVars $processEnvironment
            if ($baseReport.StdOut.Trim() -ceq $legacyReport) {
                $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('restore', '--source=origin/main', '--staged', '--worktree', '--', $legacyReport) `
                    -WorkingDirectory $root -EnvVars $processEnvironment
            }
            else {
                $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('rm', '--ignore-unmatch', '--', $legacyReport) `
                    -WorkingDirectory $root -EnvVars $processEnvironment
            }
        }
        else {
            $branch = "automation/module-metadata-sync-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
            $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('checkout', '-b', $branch, 'origin/main') -WorkingDirectory $root -EnvVars $processEnvironment
        }
        foreach ($relative in $publishable) {
            $target = $paths[$role].files[$relative]
            Assert-AvmCatalogSafePath -Root $root -RelativePath $target
            $file = Join-Path $root $target
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
            [System.IO.File]::Copy((Join-Path $BundlePath $relative), $file, $true)
        }
        $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList (@('add', '--') + $allowed) -WorkingDirectory $root -EnvVars $processEnvironment
        $diff = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('diff', '--cached', '--quiet') -WorkingDirectory $root -EnvVars $processEnvironment -IgnoreExitCode
        if ($diff.ExitCode -notin @(0, 1)) {
            throw [System.InvalidOperationException]::new("Could not determine staged catalog changes in $repository.")
        }
        if ($diff.ExitCode -eq 1) {
            $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('commit', '-m', 'chore: synchronize AVM module catalogs') -WorkingDirectory $root -EnvVars $processEnvironment
        }
        if ($diff.ExitCode -eq 1 -or $null -ne $existing) {
            $head = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('rev-parse', 'HEAD') -WorkingDirectory $root -EnvVars $processEnvironment
            $headSha = $head.StdOut.Trim()
            if ($headSha -cnotmatch '^[0-9a-f]{40}$') {
                throw [System.InvalidDataException]::new('Git did not return a valid catalog commit.')
            }
            $candidate = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('diff', '--name-only', 'origin/main', 'HEAD') `
                -WorkingDirectory $root -EnvVars $processEnvironment
            $candidatePaths = @($candidate.StdOut -split '\r?\n' | Where-Object { $_ })
            if (@($candidatePaths | Where-Object { $_ -cnotin $allowed }).Count -gt 0) {
                throw [System.Security.SecurityException]::new('Catalog merge candidate contains changes outside the publication allow-list.')
            }
            $prepared.Add([pscustomobject]@{
                    Repository = $repository; Root = $root; Branch = $branch; Existing = $existing; HeadSha = $headSha
                    DocsJsonChanged = $repository -ceq $configuration.repositories.docs -and
                        $candidatePaths -ccontains $docsJsonPath
                })
        }
    }
    foreach ($target in $prepared) {
        $null = Invoke-AvmCatalogProcess -FilePath $git -ArgumentList @('push', 'origin', "HEAD:refs/heads/$($target.Branch)") `
            -WorkingDirectory $target.Root -EnvVars $processEnvironment
        $bodyPath = Join-Path $state 'pull-request.json'
        $body = [ordered]@{
            title = 'chore: synchronize AVM module catalogs'
            body = "Generated AVM catalog update from module metadata. Migration diagnostics are retained in the module-metadata-catalog workflow artifact, not committed. CSV row-removal override: $([bool]$Force).`n`nSource run: https://github.com/$($configuration.repositories.tools)/actions/runs/$($env:GITHUB_RUN_ID)"
        }
        $endpoint = "repos/$($target.Repository)/pulls"
        $method = 'POST'
        if ($null -ne $target.Existing) {
            $endpoint += "/$($target.Existing.number)"
            $method = 'PATCH'
        }
        else {
            $body['head'] = $target.Branch
            $body['base'] = 'main'
        }
        [System.IO.File]::WriteAllText($bodyPath, (ConvertTo-AvmCatalogJson -Value $body), [System.Text.UTF8Encoding]::new($false))
        $response = Invoke-AvmCatalogProcess -FilePath $gh `
            -ArgumentList @('api', '--method', $method, $endpoint, '--input', $bodyPath) `
            -WorkingDirectory $target.Root -EnvVars $processEnvironment
        $pullRequest = ConvertFrom-Json -InputObject $response.StdOut
        Write-Output $pullRequest.html_url
        $null = Invoke-AvmCatalogProcess -FilePath $gh `
            -ArgumentList @('pr', 'merge', [string]$pullRequest.number, "--repo=$($target.Repository)", '--squash', '--admin',
                '--match-head-commit', $target.HeadSha, '--subject', $body.title, '--body=') `
            -WorkingDirectory $target.Root -EnvVars $processEnvironment
        $response = Invoke-AvmCatalogProcess -FilePath $gh `
            -ArgumentList @('api', '--method', 'GET', "repos/$($target.Repository)/pulls/$($pullRequest.number)") `
            -WorkingDirectory $target.Root -EnvVars $processEnvironment
        $merged = ConvertFrom-Json -InputObject $response.StdOut
        if ($merged.merged -ne $true -or $merged.head.sha -cne $target.HeadSha) {
            throw [System.InvalidOperationException]::new("Catalog update was not merged at the expected head: $($pullRequest.html_url)")
        }
        if ($target.DocsJsonChanged) {
            $mergeSha = [string]$merged.merge_commit_sha
            if ($mergeSha -cnotmatch '^[0-9a-f]{40}$') {
                throw [System.IO.InvalidDataException]::new("Catalog merge has no valid merged commit: $($pullRequest.html_url)")
            }
            $response = Invoke-AvmCatalogProcess -FilePath $gh `
                -ArgumentList @('api', '--method', 'GET', "repos/$($target.Repository)/commits/$mergeSha") `
                -WorkingDirectory $target.Root -EnvVars $processEnvironment
            $mergedCommit = ConvertFrom-Json -InputObject $response.StdOut -AsHashtable -Depth 100
            if ($mergedCommit -isnot [System.Collections.IDictionary] -or
                $mergedCommit['sha'] -cne $mergeSha -or $mergedCommit['files'] -isnot [array]) {
                throw [System.IO.InvalidDataException]::new("Catalog merge has invalid commit file evidence: $($pullRequest.html_url)")
            }
            $docsJsonPublished = @($mergedCommit['files'] | Where-Object {
                    $_ -is [System.Collections.IDictionary] -and $_['filename'] -ceq $docsJsonPath
                }).Count -gt 0
        }
        Write-AvmCatalogProgress ("Merged catalog update: {0}" -f $pullRequest.html_url)
    }
    if ($GitHubOutputPath) {
        $result = $docsJsonPublished.ToString().ToLowerInvariant()
        [System.IO.File]::AppendAllText($GitHubOutputPath, "docs_json_published=$result`n", [System.Text.UTF8Encoding]::new($false))
    }
}
finally {
    $processEnvironment.Clear()
    $authorization = $null
    if ([System.IO.Directory]::Exists($state)) {
        Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction Stop
    }
}
