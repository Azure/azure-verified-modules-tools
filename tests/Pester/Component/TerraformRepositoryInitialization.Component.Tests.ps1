#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
    $script:realApplicationPath = InModuleScope 'Avm.Authoring' { ${function:Get-AvmApplicationPath} }
    $script:realProcess = InModuleScope 'Avm.Authoring' { ${function:Invoke-AvmProcess} }
    $script:schemaId = (Get-Content -LiteralPath (Join-Path $moduleRoot 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json') -Raw |
            ConvertFrom-Json).'$id'
    $script:repositoryName = 'terraform-azure-avm-res-storage-storageaccount'
    $script:repository = "Azure/$($script:repositoryName)"
    $script:metadataInput = @{
        moduleDisplayName = 'Azure Storage Account'
        moduleDescription = 'Deploys an Azure Storage account.'
        canonicalType     = 'Microsoft.Storage/storageAccounts'
        owners            = @('module-owner')
    }
    $script:environmentVariables = @(
        'AVM_HOME', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0',
        'GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL'
    )
    $script:savedVariables = @{}
    foreach ($name in $script:environmentVariables) {
        $script:savedVariables[$name] = [System.Environment]::GetEnvironmentVariable($name)
    }
    $globalConfig = Join-Path $TestDrive 'gitconfig'
    [System.IO.File]::WriteAllText($globalConfig, '')
    $env:GIT_CONFIG_GLOBAL = $globalConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    # Ignore git configuration inherited from the calling environment, so tests run the same everywhere.
    $env:GIT_CONFIG_COUNT = $null
    $env:GIT_CONFIG_PARAMETERS = $null
    $env:GIT_AUTHOR_NAME = 'AVM Test'
    $env:GIT_AUTHOR_EMAIL = 'avm-test@example.invalid'
    $env:GIT_COMMITTER_NAME = 'AVM Test'
    $env:GIT_COMMITTER_EMAIL = 'avm-test@example.invalid'

    function Invoke-TestGit {
        param([string[]] $Arguments)
        $output = & git @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Arguments -join ' ') failed: $($output -join ' ')"
        }
        return @($output | ForEach-Object { [string]$_ })
    }

    function Add-TestRemoteCommit {
        param([string] $Bare, [hashtable] $Files, [string] $Message)
        $clone = Join-Path $TestDrive ('edit-' + [guid]::NewGuid().ToString('N'))
        $null = Invoke-TestGit @('init', '--quiet', $clone)
        $null = Invoke-TestGit @('-C', $clone, 'symbolic-ref', 'HEAD', 'refs/heads/main')
        $null = & git --git-dir $Bare rev-parse --verify --quiet main
        if ($LASTEXITCODE -eq 0) {
            $null = Invoke-TestGit @('-C', $clone, 'pull', '--quiet', $Bare, 'main')
        }
        foreach ($relative in $Files.Keys) {
            $target = Join-Path $clone $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $target -Parent) -Force
            [System.IO.File]::WriteAllText($target, $Files[$relative])
        }
        $null = Invoke-TestGit @('-C', $clone, 'add', '--all')
        $null = Invoke-TestGit @('-C', $clone, 'commit', '--quiet', '-m', $Message)
        $null = Invoke-TestGit @('-C', $clone, 'push', '--quiet', $Bare, 'HEAD:refs/heads/main')
    }

    function Get-TestRemoteLog {
        param([string] $Bare)
        return @(Invoke-TestGit @('--git-dir', $Bare, 'log', '--format=%s', 'main'))
    }

    function Get-TestRemoteFile {
        param([string] $Bare)
        return @(Invoke-TestGit @('--git-dir', $Bare, 'ls-tree', '-r', '--name-only', 'main'))
    }

    function Get-TestPublishedMetadata {
        ([ordered]@{
            '$schema'         = $script:schemaId
            moduleDisplayName = 'Azure Storage Account'
            moduleDescription = 'Deploys an Azure Storage account.'
            canonicalType     = 'Microsoft.Storage/storageAccounts'
            owners            = @('module-owner')
            telemetryIdPrefix = '46d3xtrf.res.abc1234'
        } | ConvertTo-Json) + "`n"
    }
}

AfterAll {
    foreach ($name in $script:environmentVariables) {
        if ($null -eq $script:savedVariables[$name]) {
            [System.Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        }
        else {
            [System.Environment]::SetEnvironmentVariable($name, $script:savedVariables[$name], 'Process')
        }
    }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: resumable Terraform avm init' -Tag Component {
    BeforeEach {
        $env:AVM_HOME = Join-Path $TestDrive ('home-' + [guid]::NewGuid().ToString('N'))
        $recordPath = InModuleScope 'Avm.Authoring' -Parameters @{ Repository = $script:repository } {
            param($Repository)
            Get-AvmRulesetOptOutRecordPath -Repository $Repository
        }
        $bare = Join-Path $TestDrive ('remote-' + [guid]::NewGuid().ToString('N'))
        $env:GIT_CONFIG_KEY_0 = "url.$([uri]::new($bare).AbsoluteUri).insteadOf"
        $env:GIT_CONFIG_VALUE_0 = "https://github.com/$($script:repository).git"
        $env:GIT_CONFIG_COUNT = '1'
        $null = Invoke-TestGit @('init', '--quiet', '--bare', $bare)
        $null = Invoke-TestGit @('--git-dir', $bare, 'symbolic-ref', 'HEAD', 'refs/heads/main')
        Add-TestRemoteCommit -Bare $bare -Files @{ 'README.md' = "# Repository setup required`n" } -Message 'README.md: Setup instructions'

        $work = Join-Path $TestDrive ('work-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $work
        $path = Join-Path $work $script:repositoryName
        $fake = @{
            Name           = $script:repositoryName
            Id             = 123
            Bare           = $bare
            Exists         = $false
            PortalComplete = $false
            Admin          = $false
            Interactive    = $false
            OptOut         = 'false'
            FailRestore    = $false
            Rulesets       = @()
            Teams          = @{}
            PreCommitFails = $false
            FlipOptOut     = $false
            AppInstalled   = $false
            Prompts        = 0
            AppRequests    = 0
            Calls          = [System.Collections.Generic.List[string]]::new()
            OptOutWrites   = [System.Collections.Generic.List[object]]::new()
        }
        $gitHubError = InModuleScope 'Avm.Authoring' { [AvmGitHubException] }

        Mock -ModuleName Avm.Authoring Invoke-AvmGitHubApi -MockWith ({
                param($Endpoint, $Method, $Body, $AllowNotFound, $Accept)
                $verb = if ($Method) { [string]$Method } else { 'GET' }
                $fake.Calls.Add("$verb $Endpoint")
                $repository = "repos/Azure/$($fake.Name)"
                if ($Endpoint -eq $repository) {
                    if ($fake.Exists -and $fake.PortalComplete) {
                        return @{ id = $fake.Id; name = $fake.Name; visibility = 'public'; permissions = @{ admin = $fake.Admin; push = $true } }
                    }
                    if ($AllowNotFound) { return $null }
                    throw $gitHubError::new('Not Found', 404)
                }
                if ($verb -eq 'POST' -and $Endpoint -eq 'orgs/Azure/repos') {
                    if ($fake.Exists) {
                        throw $gitHubError::new('Repository creation failed. name already exists on this account', 422)
                    }
                    $fake.Exists = $true
                    return @{ name = $Body.name }
                }
                if ($Endpoint -eq "$repository/contents/metadata.json?ref=main") {
                    $json = @(& git --git-dir $fake.Bare show 'main:metadata.json' 2>$null)
                    if ($LASTEXITCODE -ne 0) {
                        if ($AllowNotFound) { return $null }
                        throw $gitHubError::new('Not Found', 404)
                    }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes((($json -join "`n") + "`n"))
                    return @{ content = [System.Convert]::ToBase64String($bytes) }
                }
                $treeMatch = [regex]::Match($Endpoint, "^$([regex]::Escape($repository))/git/trees/(?<ref>[0-9A-Za-z]+)$")
                if ($treeMatch.Success) {
                    $entries = @(& git --git-dir $fake.Bare ls-tree -l $treeMatch.Groups['ref'].Value 2>$null)
                    return @{
                        truncated = $false
                        tree      = @($entries | ForEach-Object {
                                $entry = [regex]::Match([string]$_, '^\d+ (?<type>\w+) (?<sha>[0-9a-f]+) +(?<size>\d+|-)\t(?<path>.+)$')
                                $item = @{ path = $entry.Groups['path'].Value; type = $entry.Groups['type'].Value; sha = $entry.Groups['sha'].Value }
                                if ($entry.Groups['size'].Value -ne '-') {
                                    $item.size = [long]$entry.Groups['size'].Value
                                }
                                $item
                            })
                    }
                }
                $teamMatch = [regex]::Match($Endpoint, "^orgs/Azure/teams/(?<slug>[^/]+)/repos/Azure/$($fake.Name)$")
                if ($teamMatch.Success) {
                    $slug = $teamMatch.Groups['slug'].Value
                    if ($verb -eq 'PUT') {
                        $fake.Teams[$slug] = $Body.permission
                        return $null
                    }
                    if (-not $fake.Teams.ContainsKey($slug)) {
                        if ($AllowNotFound) { return $null }
                        throw $gitHubError::new('Not Found', 404)
                    }
                    $level = @{ pull = 1; triage = 2; push = 3; maintain = 4; admin = 5 }[$fake.Teams[$slug]]
                    return @{ permissions = @{ pull = $level -ge 1; triage = $level -ge 2; push = $level -ge 3; maintain = $level -ge 4; admin = $level -ge 5 } }
                }
                if ($Endpoint -eq "$repository/properties/values") {
                    if ($verb -eq 'PATCH') {
                        $value = $Body.properties[0].value
                        if ($fake.FailRestore -and $value -cne 'true') {
                            $fake.FailRestore = $false
                            throw $gitHubError::new('Server Error', 500)
                        }
                        $fake.OptOutWrites.Add([pscustomobject]@{ Value = $value; RemoteMain = [string](& git --git-dir $fake.Bare rev-parse main) })
                        $fake.OptOut = $value
                        return $null
                    }
                    return @(
                        @{ property_name = 'activeRepoStatus'; value = 'true' }
                        @{ property_name = 'global-rulesets-opt-out'; value = $fake.OptOut }
                    )
                }
                if ($Endpoint -eq "$repository/rulesets?includes_parents=false&per_page=100") {
                    return @($fake.Rulesets | ForEach-Object { @{ name = $_ } })
                }
                throw "Unexpected GitHub call: $verb $Endpoint"
            }.GetNewClosure())
        Mock -ModuleName Avm.Authoring Invoke-AvmPreCommit -MockWith ({
                param($Path)
                if ($fake.FlipOptOut) {
                    $fake.OptOut = 'true'
                }
                if ($fake.PreCommitFails) {
                    return [pscustomobject]@{ Status = 'fail'; Issues = @([pscustomobject]@{ Severity = 'error'; Message = 'format failed' }) }
                }
                [System.IO.File]::WriteAllText((Join-Path $Path 'LICENSE'), "MIT License`n")
                [System.IO.File]::WriteAllText((Join-Path $Path 'README.md'), "# Azure Storage Account`n")
                [pscustomobject]@{ Status = 'pass'; Issues = @() }
            }.GetNewClosure())
        Mock -ModuleName Avm.Authoring Request-AvmAppInstallation -MockWith ({
                $fake.AppRequests++
                if ($fake.AppInstalled) {
                    return [pscustomobject]@{ Status = 'installed'; PullRequest = $null; Files = @() }
                }
                $status = if ($fake.AppRequests -eq 1) { 'requested' } else { 'pending' }
                [pscustomobject]@{ Status = $status; PullRequest = 'https://github.com/microsoft/github-operations/pull/1'; Files = @('x') }
            }.GetNewClosure())
        Mock -ModuleName Avm.Authoring Test-AvmInteractiveHost -MockWith ({ $fake.Interactive }.GetNewClosure())
        Mock -ModuleName Avm.Authoring Read-Host -MockWith ({
                $fake.Prompts++
                $fake.PortalComplete = $true
                $fake.Admin = $true
                'yes'
            }.GetNewClosure())
        Mock -ModuleName Avm.Authoring Get-AvmCatalogTelemetryPrefix { @() }
        Mock -ModuleName Avm.Authoring New-AvmTelemetryIdPrefix { '46d3xtrf.res.abc1234' }
        # Pester 6 does not fall back to the real command, so unmatched calls are forwarded explicitly.
        $realApplicationPath = $script:realApplicationPath
        $realProcess = $script:realProcess
        Mock -ModuleName Avm.Authoring Get-AvmApplicationPath -MockWith ({
                param($Name)
                if ($Name -eq 'gh') {
                    return 'fake-gh'
                }
                & $realApplicationPath -Name $Name
            }.GetNewClosure())
        Mock -ModuleName Avm.Authoring Invoke-AvmProcess -MockWith ({
                param(
                    [string] $FilePath, [string[]] $ArgumentList, [string] $WorkingDirectory, [hashtable] $EnvVars, [int] $TimeoutSec,
                    [switch] $IgnoreExitCode, [switch] $StreamOutput, [string] $Label, [scriptblock] $OnStdOutLine, [int[]] $SuccessExitCode
                )
                & $realProcess @PSBoundParameters
            }.GetNewClosure())
        Mock -ModuleName Avm.Authoring Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } } -ParameterFilter {
            $FilePath -eq 'fake-gh'
        }
        $init = @{ Ecosystem = 'terraform'; ModuleType = 'resource'; Path = $path; SkipModuleVersionCheck = $true }
        $ready = {
            $fake.Exists = $true
            $fake.PortalComplete = $true
            $fake.Admin = $true
        }
        $publishModule = {
            Add-TestRemoteCommit -Bare $bare -Message 'chore: initialize module repository' -Files @{
                'metadata.json'            = (Get-TestPublishedMetadata)
                'terraform.tf'             = "terraform {}`n"
                '_header.md'               = "# Azure Storage Account`n"
                'examples/default/main.tf' = "# example`n"
                'tests/.gitkeep'           = ''
            }
        }
    }

    It 'creates, sets up, and publishes a new repository in one interactive run' {
        $fake.Interactive = $true
        Mock -ModuleName Avm.Authoring Write-AvmLog {}

        $result = Initialize-AvmModule @init -InputObject $script:metadataInput

        $result.Status | Should -Be 'pass'
        $result.Changed | Should -BeTrue
        $result.Repository | Should -BeExactly $script:repository
        @($result.Steps | ForEach-Object { ($_.Step -split ':')[0] }) | Should -Be @(
            'metadata', 'repository', 'open source portal setup', 'team access', 'initial content', 'app installation', 'local clone',
            'just-in-time rule', 'direct owners')
        @($result.Steps.Status) | Should -Be @('pass', 'pass', 'pass', 'pass', 'pass', 'pending', 'pass', 'manual', 'manual')
        $result.Steps[-2].Step | Should -BeExactly ('just-in-time rule: if not already done, tie the repository to ' +
            'service-AVM-azure-verified-modules-module-owners in the open source portal')
        $result.Steps[-1].Step | Should -BeExactly ('direct owners: last, make jaredholgate and jatracey the only individual ' +
            'Direct Owners in the open source portal')
        Should -Invoke Write-AvmLog -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $Message -eq ("Finish the setup of Azure/$($script:repositoryName) in the open source portal: " +
                "https://repos.opensource.microsoft.com/orgs/Azure/repos/$($script:repositoryName)") -and $Level -eq 'Info'
        }
        Should -Invoke Write-AvmLog -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $Message -like '*enter the rule ID service-AVM-azure-verified-modules-module-owners*' -and $Level -eq 'Info'
        }
        Should -Invoke Write-AvmLog -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $Message -like '*email avm@microsoft.com*' -and $Level -eq 'Info'
        }
        Should -Invoke Write-AvmLog -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $Message -like '*Last, once everything else is done, make jaredholgate and jatracey the only individual Direct Owners.' -and
            $Level -eq 'Info'
        }
        $result.AppInstallationPullRequest | Should -Be 'https://github.com/microsoft/github-operations/pull/1'
        $result.Metadata.telemetryIdPrefix | Should -BeExactly '46d3xtrf.res.abc1234'
        $fake.Prompts | Should -Be 1
        $fake.Teams['azure-verified-modules-module-contributors'] | Should -Be 'push'
        $fake.Teams['azure-verified-modules-module-readers'] | Should -Be 'triage'

        Get-TestRemoteLog -Bare $bare | Should -Be @('chore: initialize module repository', 'README.md: Setup instructions')
        $published = Get-TestRemoteFile -Bare $bare
        foreach ($file in @('metadata.json', '_header.md', 'main.tf', 'variables.tf', 'outputs.tf', 'terraform.tf',
                'examples/default/main.tf', 'examples/default/_header.md', 'tests/.gitkeep', 'LICENSE', 'README.md')) {
            $published | Should -Contain $file
        }
        (Invoke-TestGit @('--git-dir', $bare, 'show', 'main:_header.md')) -join "`n" |
            Should -BeExactly "# Azure Storage Account`n`nDeploys an Azure Storage account."
        (Invoke-TestGit @('--git-dir', $bare, 'show', 'main:README.md')) -join "`n" | Should -BeExactly '# Azure Storage Account'
        $seed = @(Invoke-TestGit @('--git-dir', $bare, 'rev-parse', 'main~1'))[0]
        $commit = @(Invoke-TestGit @('--git-dir', $bare, 'rev-parse', 'main'))[0]
        @($fake.OptOutWrites.Value) | Should -Be @('true', 'false')
        $fake.OptOutWrites[0].RemoteMain | Should -Be $seed
        $fake.OptOutWrites[1].RemoteMain | Should -Be $commit
        Test-Path -LiteralPath $recordPath | Should -BeFalse
        @(Invoke-TestGit @('-C', $path, 'rev-parse', 'HEAD'))[0] | Should -Be $commit
        @(Invoke-TestGit @('-C', $path, 'status', '--porcelain')) | Should -BeNullOrEmpty
    }

    It 'resumes after each interruption and changes nothing once setup is complete' {
        $first = Initialize-AvmModule @init -InputObject $script:metadataInput
        $first.Status | Should -Be 'fail'
        $failed = @($first.Steps | Where-Object { $_.Status -eq 'fail' })
        $failed.Step | Should -Be 'open source portal setup'
        $failed.Error | Should -Match "Complete the open source portal setup for $([regex]::Escape($script:repository))"
        $fake.Exists | Should -BeTrue
        @(Get-ChildItem -LiteralPath $path -Force).Name | Should -Be @('metadata.json')
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 1

        $fake.PortalComplete = $true
        $callsBefore = $fake.Calls.Count
        $second = Initialize-AvmModule @init
        $second.Status | Should -Be 'fail'
        @($second.Steps | Where-Object { $_.Status -eq 'fail' }).Step | Should -Be 'administrator access'
        @($fake.Calls | Select-Object -Skip $callsBefore) | Should -Not -Contain 'POST orgs/Azure/repos' -Because 'the repository already exists'
        $fake.Teams.Count | Should -Be 0

        $fake.Admin = $true
        $third = Initialize-AvmModule @init
        $third.Status | Should -Be 'pass'
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 2
        ((Invoke-TestGit @('--git-dir', $bare, 'show', 'main:metadata.json')) -join "`n" | ConvertFrom-Json).telemetryIdPrefix |
            Should -BeExactly '46d3xtrf.res.abc1234'
        (Invoke-TestGit @('--git-dir', $bare, 'show', 'main:_header.md')) -join "`n" |
            Should -BeExactly "# Azure Storage Account`n`nDeploys an Azure Storage account." -Because 'a re-run reads the name and description from metadata.json'
        Should -Invoke New-AvmTelemetryIdPrefix -ModuleName Avm.Authoring -Exactly 1
        Should -Invoke Read-Host -ModuleName Avm.Authoring -Exactly 0

        $callsBefore = $fake.Calls.Count
        $fourth = Initialize-AvmModule @init
        $fourth.Status | Should -Be 'pass'
        $fourth.Changed | Should -BeFalse
        @($fourth.Steps.Status) | Should -Be @('pass', 'pass', 'pass', 'pass', 'pending', 'pass', 'manual', 'manual')
        $fourth.Steps[2].Step | Should -Match 'already granted'
        $fourth.Steps[3].Step | Should -Be 'initial content: metadata.json and module files are on main'
        $fourth.Steps[5].Step | Should -Match 'existing clone'
        @($fake.Calls | Select-Object -Skip $callsBefore | Where-Object { $_ -match '^(POST|PUT|PATCH) ' }) | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmPreCommit -ModuleName Avm.Authoring -Exactly 1
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 2
    }

    It 'restores the opt-out when GitHub rejects the push and publishes on the next run' {
        & $ready
        $hook = Join-Path $bare 'hooks' 'pre-receive'
        [System.IO.File]::WriteAllText($hook, "#!/bin/sh`necho 'GH013: Repository rule violations found for refs/heads/main.' >&2`nexit 1`n")
        if (-not $IsWindows) {
            & chmod +x $hook
        }

        $first = Initialize-AvmModule @init -InputObject $script:metadataInput

        $first.Status | Should -Be 'fail'
        $failed = @($first.Steps | Where-Object { $_.Status -eq 'fail' })
        $failed.Step | Should -Be 'initial content'
        $failed.Error | Should -Match 'GH013'
        @($fake.OptOutWrites.Value) | Should -Be @('true', 'false')
        Test-Path -LiteralPath $recordPath | Should -BeFalse
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 1
        @(Get-ChildItem -LiteralPath $path -Force).Name | Should -Be @('metadata.json')

        Remove-Item -LiteralPath $hook
        $second = Initialize-AvmModule @init
        $second.Status | Should -Be 'pass'
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 2
        @($fake.OptOutWrites.Value) | Should -Be @('true', 'false', 'true', 'false')
    }

    It 'restores the recorded opt-out on the next run when restoring it failed after the push' {
        & $ready
        $fake.FailRestore = $true

        $first = Initialize-AvmModule @init -InputObject $script:metadataInput

        $first.Status | Should -Be 'fail'
        $failed = @($first.Steps | Where-Object { $_.Status -eq 'fail' })
        $failed.Step | Should -Be 'initial content'
        $failed.Error | Should -Match 'Could not restore global-rulesets-opt-out to false'
        $fake.OptOut | Should -Be 'true'
        (Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json).value | Should -Be 'false'
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 2

        $second = Initialize-AvmModule @init

        $second.Status | Should -Be 'pass'
        $restoreStep = @($second.Steps | Where-Object { $_.Step -like 'organization rulesets*' })
        $restoreStep.Step | Should -Be 'organization rulesets: restored global-rulesets-opt-out to false'
        $fake.OptOut | Should -Be 'false'
        Test-Path -LiteralPath $recordPath | Should -BeFalse
        Should -Invoke Invoke-AvmPreCommit -ModuleName Avm.Authoring -Exactly 1
    }

    It 'removes the opt-out record without undoing repository sync' {
        & $ready
        & $publishModule
        $fake.OptOut = 'true'
        $fake.Rulesets = @('Azure Verified Modules')
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $recordPath -Parent) -Force
        [System.IO.File]::WriteAllText($recordPath, (@{
                    repository = $script:repository; repositoryId = $fake.Id; propertyName = 'global-rulesets-opt-out'; value = 'false'
                } | ConvertTo-Json))

        $result = Initialize-AvmModule @init

        $result.Status | Should -Be 'pass'
        @($result.Steps | Where-Object { $_.Step -like 'organization rulesets*' }).Step |
            Should -Be 'organization rulesets: no earlier change to restore'
        $fake.OptOut | Should -Be 'true'
        $fake.OptOutWrites | Should -HaveCount 0
        Test-Path -LiteralPath $recordPath | Should -BeFalse
    }

    It 'discards a record left for an earlier repository with the same name and publishes' {
        & $ready
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $recordPath -Parent) -Force
        [System.IO.File]::WriteAllText($recordPath, (@{
                    repository = $script:repository; repositoryId = 99; propertyName = 'global-rulesets-opt-out'; value = $null
                } | ConvertTo-Json))

        $result = Initialize-AvmModule @init -InputObject $script:metadataInput

        $result.Status | Should -Be 'pass'
        @($result.Steps | Where-Object { $_.Step -like 'organization rulesets*' }).Step |
            Should -Be 'organization rulesets: removed a record for an earlier repository with this name'
        @($fake.OptOutWrites.Value) | Should -Be @('true', 'false')
        $fake.OptOut | Should -Be 'false'
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 2
        Test-Path -LiteralPath $recordPath | Should -BeFalse
    }

    It 'stops when global-rulesets-opt-out is already true on <Case> without a record or repository sync' -TestCases @(
        @{ Case = 'a new repository'; Published = $false }
        @{ Case = 'a published repository'; Published = $true }
    ) {
        param($Case, $Published)
        & $ready
        if ($Published) {
            & $publishModule
        }
        $fake.OptOut = 'true'

        $result = Initialize-AvmModule @init -InputObject $script:metadataInput

        $result.Status | Should -Be 'fail'
        $failed = @($result.Steps | Where-Object { $_.Status -eq 'fail' })
        $failed.Step | Should -Be 'organization rulesets'
        $failed.Error | Should -Match ('^global-rulesets-opt-out is true, but repository sync does not manage the repository and ' +
            'this machine has no record of avm init changing it\. If avm init was interrupted on another machine')
        $result.Steps[-1].Step | Should -Be 'organization rulesets'
        $fake.OptOut | Should -Be 'true'
        $fake.OptOutWrites | Should -HaveCount 0
        $fake.Teams.Count | Should -Be 0
        Get-TestRemoteLog -Bare $bare | Should -HaveCount ($Published ? 2 : 1)
        Should -Invoke Invoke-AvmPreCommit -ModuleName Avm.Authoring -Exactly 0
        Should -Invoke Request-AvmAppInstallation -ModuleName Avm.Authoring -Exactly 0
    }

    It 'stops before publishing when repository sync already protects main' {
        & $ready
        $fake.OptOut = 'true'
        $fake.Rulesets = @('Azure Verified Modules')

        $result = Initialize-AvmModule @init -InputObject $script:metadataInput

        $result.Status | Should -Be 'fail'
        $failed = @($result.Steps | Where-Object { $_.Status -eq 'fail' })
        $failed.Step | Should -Be 'initial content'
        $failed.Error | Should -BeExactly ("Repository sync already protects main on $($script:repository), so avm init cannot push " +
            'the first commit. Add metadata.json and the module files with a pull request, then run avm init again.')
        $fake.OptOutWrites | Should -HaveCount 0
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 1
        Should -Invoke Invoke-AvmPreCommit -ModuleName Avm.Authoring -Exactly 0
    }

    It 'pushes nothing when global-rulesets-opt-out changes to true during the run' {
        & $ready
        $fake.FlipOptOut = $true

        $result = Initialize-AvmModule @init -InputObject $script:metadataInput

        $result.Status | Should -Be 'fail'
        $failed = @($result.Steps | Where-Object { $_.Status -eq 'fail' })
        $failed.Step | Should -Be 'initial content'
        $failed.Error | Should -Match 'global-rulesets-opt-out is already true on .+, so its original value is unknown'
        $fake.OptOutWrites | Should -HaveCount 0
        Test-Path -LiteralPath $recordPath | Should -BeFalse
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 1
    }

    It 'stops before pushing when avm pre-commit fails and publishes on the next run' {
        & $ready
        $fake.PreCommitFails = $true

        $first = Initialize-AvmModule @init -InputObject $script:metadataInput

        $first.Status | Should -Be 'fail'
        $failed = @($first.Steps | Where-Object { $_.Status -eq 'fail' })
        $failed.Step | Should -Be 'initial content'
        $failed.Error | Should -Match 'avm pre-commit failed'
        $failed.Result.Issues.Message | Should -Be 'format failed'
        $fake.OptOutWrites | Should -HaveCount 0
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 1

        $fake.PreCommitFails = $false
        (Initialize-AvmModule @init).Status | Should -Be 'pass'
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 2
    }

    It 'refuses to publish over existing module content that has no metadata' {
        Add-TestRemoteCommit -Bare $bare -Files @{ 'main.tf' = "# existing`n" } -Message 'existing content'
        & $ready

        $result = Initialize-AvmModule @init -InputObject $script:metadataInput

        $result.Status | Should -Be 'fail'
        $failed = @($result.Steps | Where-Object { $_.Status -eq 'fail' })
        $failed.Step | Should -Be 'initial content'
        $failed.Error | Should -Match 'main already contains files without metadata.json \(main\.tf\)'
        $fake.OptOutWrites | Should -HaveCount 0
        Should -Invoke Invoke-AvmPreCommit -ModuleName Avm.Authoring -Exactly 0
        Get-TestRemoteLog -Bare $bare | Should -HaveCount 2
    }

    It 'publishes only generated content and leaves other local files in place' {
        & $ready
        $null = New-Item -ItemType Directory -Path $path
        [System.IO.File]::WriteAllText((Join-Path $path 'main.tf'), "# local work`n")
        [System.IO.File]::WriteAllText((Join-Path $path 'secrets.auto.tfvars'), "token = `"x`"`n")

        $result = Initialize-AvmModule @init -InputObject $script:metadataInput

        $result.Status | Should -Be 'pass'
        $published = Get-TestRemoteFile -Bare $bare
        $published | Should -Not -Contain 'secrets.auto.tfvars'
        (Invoke-TestGit @('--git-dir', $bare, 'show', 'main:main.tf')) -join "`n" | Should -Match 'azapi_resource'
        $clone = @($result.Steps | Where-Object { $_.Step -like 'local clone*' })
        $clone.Status | Should -Be 'skipped'
        $clone.Step | Should -Match 'holds other files'
        [System.IO.File]::ReadAllText((Join-Path $path 'main.tf')) | Should -BeExactly "# local work`n"
        Test-Path -LiteralPath (Join-Path $path '.git') | Should -BeFalse
    }

    It 'clones a set-up repository into <Case>' -TestCases @(
        @{ Case = 'a missing folder'; Create = $false }
        @{ Case = 'an empty folder'; Create = $true }
    ) {
        param($Case, $Create)
        & $ready
        & $publishModule
        $fake.Teams = @{ 'azure-verified-modules-module-contributors' = 'push'; 'azure-verified-modules-module-readers' = 'admin' }
        $fake.AppInstalled = $true
        if ($Create) {
            $null = New-Item -ItemType Directory -Path $path
        }

        $result = Initialize-AvmModule @init

        $result.Status | Should -Be 'pass'
        $result.Changed | Should -BeFalse
        $result.Metadata.moduleDisplayName | Should -Be 'Azure Storage Account'
        @($result.Steps.Status) | Should -Be @('pass', 'pass', 'pass', 'pass', 'pass', 'pass', 'manual', 'manual')
        $result.Steps[-3].Step | Should -Be "local clone: cloned to $path"
        $fake.Teams['azure-verified-modules-module-readers'] | Should -Be 'admin'
        Test-Path -LiteralPath (Join-Path $path 'terraform.tf') | Should -BeTrue
        Should -Invoke Invoke-AvmPreCommit -ModuleName Avm.Authoring -Exactly 0
    }

    It 'reports a published repository whose main has metadata but no module files' {
        & $ready
        Add-TestRemoteCommit -Bare $bare -Files @{ 'metadata.json' = (Get-TestPublishedMetadata); 'terraform.tf' = '' } -Message 'metadata only'

        $result = Initialize-AvmModule @init

        $result.Status | Should -Be 'fail'
        $failed = @($result.Steps | Where-Object { $_.Status -eq 'fail' })
        $failed.Step | Should -Be 'initial content'
        $failed.Error | Should -BeExactly ('main has metadata.json but is missing terraform.tf, _header.md, examples/<name>/, tests/. ' +
            'Add the module files with a pull request, then run avm init again.')
        Should -Invoke Invoke-AvmPreCommit -ModuleName Avm.Authoring -Exactly 0
        Should -Invoke Request-AvmAppInstallation -ModuleName Avm.Authoring -Exactly 0
    }

    It 'stops at <Stage> when its confirmation is declined' -TestCases @(
        @{ Stage = 'team access' }
        @{ Stage = 'initial content' }
        @{ Stage = 'app installation' }
    ) {
        param($Stage)
        & $ready
        switch ($Stage) {
            'team access' {
                Mock -ModuleName Avm.Authoring Sync-AvmRepositoryTeamAccess {
                    [pscustomobject]@{ Team = 'azure-verified-modules-module-contributors'; Permission = 'push'; Status = 'planned' }
                }
            }
            'initial content' {
                Mock -ModuleName Avm.Authoring Publish-AvmTerraformRepositoryContent {
                    [pscustomobject]@{ Status = 'planned'; Commit = $null; PreCommit = $null; Files = @() }
                }
            }
            'app installation' {
                Mock -ModuleName Avm.Authoring Request-AvmAppInstallation {
                    [pscustomobject]@{ Status = 'planned'; PullRequest = $null; Files = @('apps/azure/azure-verified-modules.yaml') }
                }
            }
        }

        $result = Initialize-AvmModule @init -InputObject $script:metadataInput

        $result.Status | Should -Be 'pass'
        $result.Steps[-1].Step | Should -BeLike "$Stage*"
        $result.Steps[-1].Status | Should -Be 'planned'
        @($result.Steps | Where-Object { $_.Step -like 'local clone*' }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $path '.git') | Should -BeFalse
    }

    It 'plans a new repository under WhatIf without local or remote writes' {
        $result = Initialize-AvmModule @init -InputObject $script:metadataInput -WhatIf

        $result.Status | Should -Be 'pass'
        @($result.Steps.Status) | Should -Be @('planned', 'planned')
        Test-Path -LiteralPath $path | Should -BeFalse
        $fake.Exists | Should -BeFalse
        @($fake.Calls | Where-Object { $_ -match '^(POST|PUT|PATCH) ' }) | Should -BeNullOrEmpty
    }

    It 'dispatches avm init for Terraform to repository setup' {
        $result = avm -SkipModuleVersionCheck init -Ecosystem terraform -ModuleType resource -Path $path `
            -InputObject $script:metadataInput -WhatIf --passthru

        $result.Repository | Should -BeExactly $script:repository
        @($result.Steps.Status) | Should -Be @('planned', 'planned')
    }

    It 'stops before any change when the GitHub CLI token lacks required scopes' {
        Mock -ModuleName Avm.Authoring Invoke-AvmProcess {
            [pscustomobject]@{ ExitCode = 0; StdOut = "github.com`n  - Token scopes: 'gist', 'repo'`n"; StdErr = '' }
        } -ParameterFilter { $FilePath -eq 'fake-gh' }

        { Initialize-AvmModule @init -InputObject $script:metadataInput } |
            Should -Throw '*missing the read:org, workflow scope(s)*gh auth refresh --hostname github.com --scopes read:org,workflow*'
        Test-Path -LiteralPath $path | Should -BeFalse
        $fake.Calls.Count | Should -Be 0
    }

    It 'accepts a token whose organization scope implies read:org' {
        Mock -ModuleName Avm.Authoring Invoke-AvmProcess {
            [pscustomobject]@{ ExitCode = 0; StdOut = "  - Token scopes: 'admin:org', 'repo', 'workflow'`n"; StdErr = '' }
        } -ParameterFilter { $FilePath -eq 'fake-gh' }

        $result = Initialize-AvmModule @init -InputObject $script:metadataInput -WhatIf

        @($result.Steps.Status) | Should -Be @('planned', 'planned')
    }
}
