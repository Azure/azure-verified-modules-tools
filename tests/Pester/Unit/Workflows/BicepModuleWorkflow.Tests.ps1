#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    . (Join-Path $script:root 'scripts' 'bicep-workflows' 'Common.ps1')
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    $script:workflows = @{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:root '.github' 'workflows') -Filter 'bicep-module*.yml') {
        $script:workflows[$file.BaseName] = ConvertFrom-Yaml (Get-Content -LiteralPath $file.FullName -Raw)
    }
    $script:entrypoints = @(Get-ChildItem -LiteralPath (Join-Path $script:root '.github' 'workflows') -Filter 'bicep-*.yml' |
            Where-Object BaseName -In @('bicep-pr-check', 'bicep-release') |
            ForEach-Object { ConvertFrom-Yaml (Get-Content -LiteralPath $_.FullName -Raw) })
    $script:actions = @{}
    foreach ($directory in Get-ChildItem -LiteralPath (Join-Path $script:root '.github' 'actions') -Directory -Filter 'bicep-*') {
        $script:actions[$directory.Name] = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $directory.FullName 'action.yml') -Raw)
    }
    $runtimeContext = $script:workflows['bicep-module-runtime-deployment'].jobs.deploy.steps |
        Where-Object { $_['id'] -ceq 'context' }
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($runtimeContext.run, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'The runtime deployment context script is invalid.' }
    $statements = @($ast.EndBlock.Statements)
    $start = @($statements | Where-Object { $_.Extent.Text -match '^\$capabilities\s*=' })[0].Extent.StartOffset
    $end = @($statements | Where-Object { $_.Extent.Text -match '^\$testCase\s*=' })[0].Extent.StartOffset
    $script:dependencyBootstrap = [scriptblock]::Create($runtimeContext.run.Substring($start, $end - $start))
    $resourceBootstrap = @($statements | Where-Object {
            $_.Extent.Text -match '^if \(-not \(Get-Module -ListAvailable -Name Microsoft\.PowerShell\.PSResourceGet\)\)'
        })[0]
    $script:resourceBootstrap = [scriptblock]::Create($resourceBootstrap.Extent.Text)
    function Get-AvmBicepAzureDependency {
        [CmdletBinding()]
        param([switch] $SkipModuleVersionCheck)
        throw 'Dependency inventory must be mocked.'
    }
    function Get-PSResourceRepository {
        [CmdletBinding()]
        param([string] $Name)
        throw 'Gallery lookup must be mocked.'
    }
    function Install-PSResource {
        [CmdletBinding()]
        param([string] $Name, [string] $Version, [string] $Repository, [string] $Scope, [switch] $TrustRepository, [switch] $Quiet)
        throw 'Dependency provisioning must be mocked.'
    }
    function Install-Module {
        [CmdletBinding()]
        param([string] $Name, [string] $Scope, [switch] $Force, [switch] $AllowClobber)
        throw 'Package manager provisioning must be mocked.'
    }
}

Describe 'Bicep prepared runtime package manager bootstrap' {
    BeforeEach {
        Mock Get-Module { [pscustomobject]@{ Name = 'Microsoft.PowerShell.PSResourceGet' } }
        Mock Install-Module {}
        Mock Start-Sleep {}
        Mock Write-Warning {}
    }

    It 'reuses an available package manager' {
        & $script:resourceBootstrap
        Should -Invoke Install-Module -Exactly 0
    }

    It 'retries provisioning when the prepared runtime has no package manager' {
        Mock Get-Module {}
        $script:attempts = 0
        Mock Install-Module {
            $script:attempts++
            if ($script:attempts -eq 1) { throw 'HTTP 503' }
        }
        & $script:resourceBootstrap
        Should -Invoke Install-Module -Exactly 2 -ParameterFilter {
            $Name -eq 'Microsoft.PowerShell.PSResourceGet' -and $Scope -eq 'CurrentUser' -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 5 }
    }

    It 'fails closed when the package manager cannot be provisioned' {
        Mock Get-Module {}
        Mock Install-Module { throw 'HTTP 503' }
        { & $script:resourceBootstrap } | Should -Throw '*503*'
        Should -Invoke Install-Module -Exactly 3
    }
}

Describe 'Bicep runtime dependency bootstrap behavior' {
    BeforeEach {
        $script:savedOffline = [Environment]::GetEnvironmentVariable('AVM_OFFLINE')
        [Environment]::SetEnvironmentVariable('AVM_OFFLINE', [NullString]::Value)
        $script:runtimeCapability = 1
        $script:dependencyCapability = 1
        Mock Get-Module {
            [pscustomobject]@{ PrivateData = @{ AvmCapabilities = @{
                        BicepWorkflowE2eRuntime = $script:runtimeCapability
                        BicepAzureDependencyInventory = $script:dependencyCapability
                    } } }
        } -ParameterFilter { $Name -eq 'Avm.Authoring' }
        $global:AvmRuntimeDependencyFixture = @{}
        Mock Get-AvmBicepAzureDependency {
            [pscustomobject]@{ Name = 'Az.Accounts'; MinimumVersion = [version]'5.3.4' }
            [pscustomobject]@{ Name = 'Az.Subscription'; MinimumVersion = [version]'0.12.0' }
        }
        Mock Get-Module {
            $key = [string]$Name
            if ($global:AvmRuntimeDependencyFixture.ContainsKey($key)) {
                [pscustomobject]@{ Version = $global:AvmRuntimeDependencyFixture[$key] }
            }
        } -ParameterFilter { $ListAvailable }
        Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'UserFeed'; Priority = 10; Uri = 'https://example.invalid/gallery' } }
        Mock Install-PSResource { $global:AvmRuntimeDependencyFixture[$Name] = [version]$Version }
        Mock Start-Sleep {}
        Mock Write-Warning {}
    }

    AfterEach {
        $offline = if ($null -eq $script:savedOffline) { [NullString]::Value } else { $script:savedOffline }
        [Environment]::SetEnvironmentVariable('AVM_OFFLINE', $offline)
        Remove-Variable AvmRuntimeDependencyFixture -Scope Global -ErrorAction SilentlyContinue
    }

    It 'reuses compatible dependencies and provisions missing Subscription after qualification' {
        $global:AvmRuntimeDependencyFixture['Az.Accounts'] = [version]'6.0.0'
        & $script:dependencyBootstrap
        Should -Invoke Install-PSResource -Exactly 1 -ParameterFilter {
            $Name -ceq 'Az.Subscription' -and $Version -ceq '0.12.0' -and $Scope -ceq 'CurrentUser' -and $Repository -ceq 'UserFeed'
        }
    }

    It 'rejects <Label> bootstrap capability without provisioning' -ForEach @(
        @{ Label = 'missing'; Value = $null }
        @{ Label = 'string'; Value = '1' }
        @{ Label = 'boolean'; Value = $true }
        @{ Label = 'unsupported'; Value = 2 }
    ) {
        $script:dependencyCapability = $Value
        { & $script:dependencyBootstrap } | Should -Throw '*BicepAzureDependencyInventory*'
        Should -Invoke Install-PSResource -Exactly 0
    }

    It 'stops before provisioning when runtime capability is not an integer' {
        $script:runtimeCapability = '1'
        { & $script:dependencyBootstrap } | Should -Throw '*BicepWorkflowE2eRuntime*'
        Should -Invoke Install-PSResource -Exactly 0
    }

    It 'reconciles an installed dependency after a transient failure without repeating installation' {
        $global:AvmRuntimeDependencyFixture['Az.Accounts'] = [version]'5.3.4'
        Mock Install-PSResource {
            $global:AvmRuntimeDependencyFixture[$Name] = [version]$Version
            throw [Net.Http.HttpRequestException]::new('HTTP 504')
        }
        & $script:dependencyBootstrap
        Should -Invoke Install-PSResource -Exactly 1
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 5 }
    }

    It 'tries configured repositories in priority order when a dependency is missing' {
        Mock Get-PSResourceRepository {
            [pscustomobject]@{ Name = 'Backup'; Priority = 20 }
            [pscustomobject]@{ Name = 'Preferred'; Priority = 10 }
        }
        $script:repositoryAttemptOrder = [Collections.Generic.List[string]]::new()
        Mock Install-PSResource {
            $script:repositoryAttemptOrder.Add("$Name/$Repository")
            if ($Repository -eq 'Preferred') { throw [InvalidOperationException]::new('Package not found') }
            $global:AvmRuntimeDependencyFixture[$Name] = [version]$Version
        }
        & $script:dependencyBootstrap
        $script:repositoryAttemptOrder.ToArray() | Should -Be @(
            'Az.Accounts/Preferred', 'Az.Accounts/Backup',
            'Az.Subscription/Preferred', 'Az.Subscription/Backup'
        )
    }

    It 'fails explicitly without configured repositories' {
        Mock Get-PSResourceRepository {}
        { & $script:dependencyBootstrap } | Should -Throw '*No PowerShell repositories are configured*'
        Should -Invoke Install-PSResource -Exactly 0
    }

    It 'fails if the installer does not provide the required module' {
        Mock Install-PSResource {}
        { & $script:dependencyBootstrap } | Should -Throw '*did not provide Az.Accounts*'
    }

    It 'does not contact the gallery offline and fails when a dependency is missing' {
        $env:AVM_OFFLINE = '1'
        $global:AvmRuntimeDependencyFixture['Az.Accounts'] = [version]'5.3.4'
        { & $script:dependencyBootstrap } | Should -Throw '*AVM_OFFLINE=1*Az.Subscription*'
        Should -Invoke Get-PSResourceRepository -Exactly 0
        Should -Invoke Install-PSResource -Exactly 0
    }

    It 'bounds transient installation failures to three attempts' {
        Mock Install-PSResource { throw [Net.Http.HttpRequestException]::new('HTTP 503') }
        { & $script:dependencyBootstrap } | Should -Throw '*503*'
        Should -Invoke Install-PSResource -Exactly 3
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke Start-Sleep -Exactly 1 -ParameterFilter { $Seconds -eq 10 }
    }
}

Describe 'Bicep reusable workflow ownership and syntax' {
    It 'exposes the same source selection on both entrypoints' {
        $script:entrypoints.Count | Should -Be 2
        foreach ($entrypoint in $script:entrypoints) {
            @($entrypoint.on.Keys) | Should -Be @('workflow_call')
            @($entrypoint.on.workflow_call.inputs.Keys | Sort-Object) | Should -Be @('authoringRef', 'authoringSource')
            $entrypoint.on.workflow_call.inputs.authoringSource.default | Should -BeExactly 'gallery'
            $entrypoint.permissions.Count | Should -Be 0
        }
    }

    It 'keeps legacy reusable workflows on their established tools contract' {
        $legacyNames = @(
            'bicep-module', 'bicep-module-deployment', 'bicep-module-preview',
            'bicep-module-publish', 'bicep-module-publish-only', 'bicep-module-static'
        )
        @($script:workflows.Keys | Where-Object { $_ -in $legacyNames }) | Should -HaveCount 6
        foreach ($workflow in $legacyNames | ForEach-Object { $script:workflows[$_] }) {
            @($workflow.on.Keys) | Should -Be @('workflow_call')
            $workflow.name | Should -Match '^Reusable: Bicep Module'
            $workflow.permissions.Count | Should -Be 0
            $workflow.on.workflow_call.inputs['tools-ref'].required | Should -BeTrue
            $workflow.on.workflow_call.inputs['tools-ref'].Contains('default') | Should -BeFalse
            $workflow.on.workflow_call.inputs.Contains('avm-authoring-version') | Should -BeFalse
        }
    }

    It 'uses tools-owned support at the explicit immutable revision in every legacy executable job' {
        $legacyNames = @(
            'bicep-module', 'bicep-module-deployment', 'bicep-module-preview',
            'bicep-module-publish', 'bicep-module-publish-only', 'bicep-module-static'
        )
        foreach ($workflow in $legacyNames | ForEach-Object { $script:workflows[$_] }) {
            foreach ($job in $workflow.jobs.Values) {
                if (-not $job.Contains('steps')) { continue }
                $usesSupport = @($job.steps | Where-Object { $_['uses'] -like './.avm-tools/*' })
                if ($usesSupport.Count -eq 0) { continue }
                foreach ($caller in $job.steps | Where-Object { $_['name'] -eq 'Check out caller' }) {
                    $caller.with.Contains('sparse-checkout') | Should -BeFalse
                }
                $checkout = @($job.steps | Where-Object { $_.Contains('with') -and $_.with['repository'] -eq 'Azure/azure-verified-modules-tools' })
                $checkout.Count | Should -Be 1
                $checkout[0].with.ref | Should -BeExactly '${{ inputs.tools-ref }}'
                $checkout[0].with.path | Should -BeExactly '.avm-tools'
                $checkout[0].with.'persist-credentials' | Should -BeFalse
                $checkout[0].with.'sparse-checkout' | Should -Match 'scripts/bicep-workflows'
                $checkout[0].with.'sparse-checkout' | Should -Match 'repository-management/shared'
                $checkout[0].with.'sparse-checkout' | Should -Not -Match '(?m)^src$|^tests$'
                foreach ($step in $usesSupport) {
                    $actionName = $step.uses.Split('/')[-1]
                    $script:actions.ContainsKey($actionName) | Should -BeTrue
                    foreach ($key in $step.with.Keys) {
                        $script:actions[$actionName].inputs.Contains($key) | Should -BeTrue
                    }
                }
            }
        }
    }

    It 'retains direct-call Gallery fallback and runtime capabilities' {
        $runtimeNames = @(
            'bicep-module-runtime', 'bicep-module-runtime-deployment',
            'bicep-module-runtime-e2e', 'bicep-module-runtime-release',
            'bicep-module-runtime-static'
        )
        @($script:workflows.Keys | Where-Object { $_ -in $runtimeNames }) | Should -HaveCount 5
        foreach ($workflow in $runtimeNames | ForEach-Object { $script:workflows[$_] }) {
            $text = $workflow | ConvertTo-Json -Depth 100
            $text | Should -Not -Match '\.avm-tools|\.avm-entrypoint|tools-ref|github\.workflow_sha'
            $text | Should -Match 'Install-PSResource -Name Avm\.Authoring'
            $text | Should -Match 'AvmCapabilities'
        }
        $release = $script:workflows['bicep-module-runtime-release'].jobs.release
        $tagging = $release.steps | Where-Object { $_.name -eq 'Create module release tags' }
        $tagging.run | Should -Match 'Set-AvmBicepReleaseTags'
        $tagging.run | Should -Match 'RequireChangelog'
        $tagging.run | Should -Match 'PendingRelease'
    }

    It 'keeps authoring checks secret-free and limits deployment credentials to E2E' {
        $prCheck = $script:entrypoints | Where-Object name -EQ 'Reusable: Bicep PR check'
        $prCheck.jobs.check.permissions.contents | Should -BeExactly 'read'
        $prCheck.jobs.check.permissions.Contains('id-token') | Should -BeFalse
        $prCheck.jobs.check.Contains('secrets') | Should -BeFalse

        $runtime = $script:workflows['bicep-module-runtime']
        $runtime.permissions.Count | Should -Be 0
        @($runtime.jobs.Keys | Sort-Object) | Should -Be @('pr-check', 'unit-test')
        foreach ($job in $runtime.jobs.Values) {
            $job.permissions.contents | Should -BeExactly 'read'
            $job.permissions.Contains('id-token') | Should -BeFalse
            ($job | ConvertTo-Json -Depth 20) | Should -Not -Match '\bsecrets\b|AVM_CI_|azure/login|environment:'
        }
        $runtime.jobs.'pr-check'.steps[-1].run | Should -Match '(?m)^\s*avm -SkipModuleVersionCheck pr-check\s*$'
        $runtime.jobs.'unit-test'.steps[-1].run | Should -Match 'avm -SkipModuleVersionCheck test unit --recurse --include-compliance'

        $e2e = $script:workflows['bicep-module-runtime-e2e']
        $deployment = $e2e.jobs.deploy
        $deployment.uses | Should -BeExactly './.github/workflows/bicep-module-runtime-deployment.yml'
        @($deployment.permissions.Keys | Sort-Object) | Should -Be @('contents', 'id-token')
        $deployment.permissions.contents | Should -BeExactly 'read'
        $deployment.permissions.'id-token' | Should -BeExactly 'write'
        $e2e.jobs.'select-deployments'.steps[-1].run | Should -Not -Match 'ConvertFrom-Json.*NoEnumerate'
    }

    It 'acquires each runtime case lock only in the executable lifecycle job, never its waiting caller' {
        $caller = $script:workflows['bicep-module-runtime-e2e'].jobs.deploy
        $caller.Contains('concurrency') | Should -BeFalse
        $caller.uses | Should -BeExactly './.github/workflows/bicep-module-runtime-deployment.yml'
        $caller.with.testCase | Should -BeExactly '${{ toJSON(matrix.testCase) }}'
        $leaf = $script:workflows['bicep-module-runtime-deployment'].jobs.deploy
        $leaf.Contains('uses') | Should -BeFalse
        $leaf.concurrency.group | Should -BeExactly '${{ fromJSON(inputs.testCase).ConcurrencyGroup }}'
        $leaf.concurrency.queue | Should -BeExactly 'max'
        $leaf.environment | Should -BeExactly 'avm-validation'
        foreach ($phase in @('Deploy native test case', 'Assert and complete native test case', 'Recover unfinished native cleanup')) {
            @($leaf.steps | Where-Object { $_['name'] -ceq $phase }).Count | Should -Be 1
        }
    }

    It 'keeps nested reusable calls relative and forwards the immutable tools contract' {
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish')) {
            $job = $script:workflows[$name].jobs.job_module_deploy_validation
            $job.uses | Should -BeExactly './.github/workflows/bicep-module-deployment.yml'
            $job.with.'tools-ref' | Should -BeExactly '${{ inputs.tools-ref }}'
            $job.with.Contains('avm-authoring-version') | Should -BeFalse
            $job.secrets | Should -BeExactly 'inherit'
        }
    }

    It 'runs packaged deployment phases through the CLI with renewable completion and recovery guards' {
        $steps = $script:workflows['bicep-module-runtime-deployment'].jobs.deploy.steps
        $deploy = $steps | Where-Object { $_['id'] -eq 'deploy' }
        $renew = $steps | Where-Object { $_['id'] -eq 'renew_oidc' }
        $complete = $steps | Where-Object { $_['name'] -eq 'Assert and complete native test case' }
        $recover = $steps | Where-Object { $_['name'] -eq 'Recover unfinished native cleanup' }

        $renew | Should -Not -BeNullOrEmpty
        $deploy.env.METADATA_LOCATION | Should -BeExactly 'WestEurope'
        $deploy.env.RESOURCE_GROUP_PREFIX | Should -BeExactly 'avm'
        $deploy.env.RESOURCE_LOCATION | Should -BeExactly '${{ fromJSON(inputs.workflowInput).customLocation }}'
        $deploy.run | Should -Match "'test', 'e2e'"
        $deploy.run | Should -Match ([regex]::Escape("'--location', `$env:METADATA_LOCATION"))
        $deploy.run | Should -Match ([regex]::Escape("'--resource-group-prefix', `$env:RESOURCE_GROUP_PREFIX"))
        $deploy.run | Should -Match ([regex]::Escape("'--resource-location', `$env:RESOURCE_LOCATION"))
        $deploy.run | Should -Not -Match 'Invoke-AvmTestE2e'
        $complete.run | Should -Match 'avm -SkipModuleVersionCheck test e2e'
        $complete.run | Should -Not -Match 'Invoke-AvmTestE2e'
        $recover.run | Should -Match 'avm -SkipModuleVersionCheck test cleanup'
        $recover.run | Should -Not -Match 'Invoke-AvmTestCleanup'
        $complete.if | Should -Match 'steps\.renew_oidc\.outcome == ''success'''
        $recover.if | Should -Match 'steps\.renew_oidc\.outcome == ''success'''
        $recover.if | Should -Match "removeDeployment == 'true'"
    }

    It 'keeps generic validation and nested deployment on the same explicit target commit' {
        foreach ($name in @('bicep-module-preview', 'bicep-module-publish', 'bicep-module-publish-only')) {
            foreach ($job in $script:workflows[$name].jobs.Values) {
                if (-not $job.Contains('steps')) { continue }
                foreach ($step in $job.steps | Where-Object { $_['name'] -eq 'Check out caller' }) {
                    $step.with.ref | Should -BeExactly '${{ inputs.targetCommit }}'
                    $step.with.'persist-credentials' | Should -BeFalse
                }
            }
        }
        foreach ($name in @('bicep-module-preview', 'bicep-module-publish')) {
            $script:workflows[$name].jobs.job_module_deploy_validation.with.targetCommit | Should -BeExactly '${{ inputs.targetCommit }}'
        }
        $inner = $script:workflows['bicep-module-deployment']
        $inner.on.workflow_call.inputs.targetCommit.required | Should -BeFalse
        ($inner.jobs.job_module_deploy_validation.steps | Where-Object { $_['name'] -eq 'Check out caller' }).with.ref |
            Should -BeExactly '${{ inputs.targetCommit || github.sha }}'
    }

    It 'resolves initializer implementations from the remote action checkout rather than the caller' {
        foreach ($name in @('bicep-workflow-input', 'bicep-module-test-files', 'bicep-workflow-matrix')) {
            $action = $script:actions[$name]
            foreach ($step in $action.runs.steps) {
                $step.env.AVM_ACTION_PATH | Should -BeExactly '${{ github.action_path }}'
                $step.run | Should -Match "Join-Path .env:AVM_ACTION_PATH '\.\.' '\.\.' '\.\.'"
                $step.run | Should -Match "Join-Path .root 'scripts' 'bicep-workflows'"
                $step.run | Should -Not -Match "Join-Path .env:GITHUB_WORKSPACE 'scripts'"
            }
        }
        @($script:actions['bicep-workflow-matrix'].outputs.Keys | Sort-Object) |
            Should -Be @('baseCommit', 'hasModules', 'includeAllVersionedModules', 'moduleMatrix', 'targetCommit', 'workflowInput')
    }

    It 'forwards the event pull request head as data without deriving a branch tip or mutable base' {
        $action = $script:actions['bicep-workflow-matrix']
        $action.inputs.pullRequestHeadCommit.required | Should -BeFalse
        $action.inputs.pullRequestHeadCommit.Contains('default') | Should -BeFalse
        $step = $action.runs.steps[0]
        $step.env.PULL_REQUEST_HEAD_COMMIT | Should -BeExactly '${{ inputs.pullRequestHeadCommit }}'
        $step.run | Should -Match 'PullRequestHeadCommit = \$env:PULL_REQUEST_HEAD_COMMIT'
        $step.run.IndexOf('Initialize-AvmWorkflowMatrix @parameters') |
            Should -BeLessThan $step.run.IndexOf('Write-AvmWorkflowOutput')
    }

    It 'prepares managed policy tools with the same validated caller path as native analysis' {
        $steps = $script:actions['bicep-validation'].runs.steps
        $setup = $steps | Where-Object { $_['id'] -eq 'setup' }
        $setup.env.MODULE_PATH | Should -BeExactly '${{ inputs.modulePath }}'
        $setup.run | Should -Match 'Resolve-AvmWorkflowPath -Root \$env:GITHUB_WORKSPACE -RelativePath \$env:MODULE_PATH'
        $setup.run | Should -Match 'Initialize-AvmWorkflow .* -Path \$modulePath '
        $validation = $steps | Where-Object { $_['name'] -eq 'Run package validation' }
        $validation.env.MODULE_PATH | Should -BeExactly '${{ inputs.modulePath }}'
        $validation.run | Should -Match 'ModulePath = \$env:MODULE_PATH'
        $validation.Contains('if') | Should -BeFalse
        $setup.Contains('continue-on-error') | Should -BeFalse
    }

    It 'exposes the shared mapped-identity resolver without package setup or Azure access' {
        $action = $script:actions['bicep-module-identity']
        @($action.inputs.Keys | Sort-Object) | Should -Be @('moduleClientIds', 'modulePath', 'tenantId')
        foreach ($inputName in $action.inputs.Keys) {
            $action.inputs[$inputName].required | Should -BeTrue
            $action.inputs[$inputName].Contains('default') | Should -BeFalse
        }
        @($action.outputs.Keys | Sort-Object) | Should -Be @('clientId', 'identityKey', 'moduleRoot', 'tenantId')
        $action.runs.steps.Count | Should -Be 1
        $step = $action.runs.steps[0]
        $step.env.AVM_ACTION_PATH | Should -BeExactly '${{ github.action_path }}'
        $step.env.MODULE_PATH | Should -BeExactly '${{ inputs.modulePath }}'
        $step.env.VALIDATE_MODULE_CLIENT_IDS | Should -BeExactly '${{ inputs.moduleClientIds }}'
        $step.env.VALIDATE_TENANT_ID | Should -BeExactly '${{ inputs.tenantId }}'
        $step.run | Should -Match 'Get-AvmWorkflowModuleIdentity -Root \$env:GITHUB_WORKSPACE'
        $step.run | Should -Match "Join-Path .root 'scripts' 'bicep-workflows' 'Deployment.ps1'"
        $step.run.IndexOf('Get-AvmWorkflowModuleIdentity') | Should -BeLessThan $step.run.IndexOf('Write-AvmWorkflowOutput')
        ($action | ConvertTo-Json -Depth 20) |
            Should -Not -Match 'VALIDATE_CLIENT_ID|AZURE_CREDENTIALS|azure/login|Initialize-AvmWorkflow|Import-AvmWorkflowPackage|ConvertFrom-Json'
    }

    It 'parses every embedded PowerShell script without interpolated workflow expressions' {
        $steps = @(
            foreach ($workflow in (@($script:workflows.Values) + $script:entrypoints)) {
                foreach ($job in $workflow.jobs.Values) {
                    if ($job.Contains('uses') -and -not $job.uses.StartsWith('./')) {
                        $job.uses | Should -Match '@[0-9a-f]{40}$'
                    }
                    if ($job.Contains('steps')) { $job.steps }
                }
            }
            foreach ($action in $script:actions.Values) { $action.runs.steps }
        )
        foreach ($step in $steps) {
            if ($step.Contains('run')) {
                $step.shell | Should -Be 'pwsh'
                $step.run | Should -Not -Match '\$\{\{'
                $tokens = $null
                $parseErrors = $null
                $null = [Management.Automation.Language.Parser]::ParseInput($step.run, [ref]$tokens, [ref]$parseErrors)
                @($parseErrors).Count | Should -Be 0 -Because $step.name
            }
            if ($step['uses'] -and -not $step.uses.StartsWith('./')) {
                $step.uses | Should -Match '@[0-9a-f]{40}$'
            }
        }
    }

    It 'never resolves shared implementations through registry utilities or caller-local templates' {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'scripts' 'bicep-workflows') -File)
        $files += @(Get-ChildItem -LiteralPath (Join-Path $script:root '.github' 'workflows') -Filter 'bicep-module*.yml')
        $files += @(Get-ChildItem -Path (Join-Path $script:root '.github' 'actions' 'bicep-*' 'action.yml') -File)
        foreach ($file in $files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $text | Should -Not -Match 'utilities[/\\]|\.github/actions/templates|bicep publish|avm publish|az deployment|Add-MpPreference'
        }
    }
}

Describe 'Bicep required checks and deployment guards' {
    It 'selects only the appropriate deployment steps when ignored is <Ignored>' -ForEach @(
        @{ Ignored = $true }
        @{ Ignored = $false }
    ) {
        $steps = $script:workflows['bicep-module-deployment'].jobs.job_module_deploy_validation.steps
        $selected = @(foreach ($step in $steps) {
                if ($step.name -eq 'Report skipped deployment') {
                    $step.if | Should -BeExactly 'fromJSON(inputs.testCase).e2eIgnore'
                    if ($Ignored) { $step }
                }
                else {
                    $step.if | Should -BeExactly '${{ !fromJSON(inputs.testCase).e2eIgnore }}'
                    if (-not $Ignored) { $step }
                }
            })
        if ($Ignored) {
            $selected.Count | Should -Be 1
            $selected[0].name | Should -BeExactly 'Report skipped deployment'
            $selected[0].run | Should -Match 'Deployment skipped'
            $selected[0].Contains('uses') | Should -BeFalse
            $selected[0].run | Should -Not -Match 'GITHUB_WORKSPACE|Initialize-AvmWorkflow|Import-Module'
        }
        else {
            $selected.Count | Should -Be 4
            $selected[-1].uses | Should -BeExactly './.avm-tools/.github/actions/bicep-deployment'
        }
    }

    It 'preserves stable jobs, required/advisory matrices, and skip/failure dependencies' {
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_module_static_validation.name | Should -BeExactly 'Static validation'
            $jobs.job_psrule_must.strategy.matrix.baseline.baselineName |
                Should -Be @('Azure.Pillar.Reliability', 'CB.AVM.WAF.Security')
            $jobs.job_psrule_opt.strategy.matrix.baseline.baselineName |
                Should -Be @('Azure.Default', 'Azure.Pillar.Security')
            foreach ($key in @('job_psrule_must', 'job_psrule_opt')) {
                $jobs[$key].strategy.'fail-fast' | Should -BeFalse
                $jobs[$key].if | Should -Match "!= '\[\]'"
                $jobs[$key].if | Should -Match "!= ''"
                $jobs[$key].Contains('continue-on-error') | Should -BeFalse
            }
            $jobs.job_module_deploy_validation.if | Should -Match '!cancelled\(\)'
            $jobs.job_module_deploy_validation.if | Should -Match "job_psrule_must.result != 'failure'"
            $jobs.job_module_deploy_validation.needs | Should -Not -Contain 'job_psrule_opt'
            $jobs.job_module_deploy_validation.if | Should -Match "moduleTestFilePaths != '\[\]'"
        }
    }

    It 'preserves environment-bound identity and one whole-lifecycle lock' {
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_initialize_subscription_selection.environment | Should -BeExactly 'avm-validation'
            $jobs.job_initialize_subscription_selection.permissions.Contains('id-token') | Should -BeFalse
        }
        $job = $script:workflows['bicep-module-deployment'].jobs.job_module_deploy_validation
        $job.environment | Should -BeExactly 'avm-validation'
        $job.permissions.'id-token' | Should -Be 'write'
        $job.concurrency.group | Should -BeExactly '${{ fromJSON(inputs.testCase).concurrencyGroup }}'
        foreach ($step in $job.steps | Where-Object name -NE 'Report skipped deployment') {
            $step.if | Should -Match '!fromJSON\(inputs.testCase\).e2eIgnore'
        }
    }

    It 'keeps fork static validation free of secrets, environments, login and publication' {
        $workflow = $script:workflows['bicep-module-runtime-static']
        @($workflow.jobs.Keys) | Should -Be @('static')
        $text = Get-Content -LiteralPath (Join-Path $script:root '.github' 'workflows' 'bicep-module-runtime-static.yml') -Raw
        $text | Should -Not -Match '\bsecrets\b|id-token|azure/login|environment:|bicep-release-tags'
        $workflow.jobs.static.env.AVM_CI_VARIABLES | Should -BeExactly '{}'
        $workflow.jobs.static.env.AVM_CI_SECRETS | Should -BeExactly '{}'
        $workflow.jobs.static.steps[-1].run | Should -Match 'Invoke-AvmTestUnit'
    }

    It 'selects only the published module client mapping while preserving tenant and subscription precedence' {
        $pool = '${{ vars.VALIDATE_SUBSCRIPTION_IDS || vars.TEST_SUBSCRIPTION_IDS || secrets.VALIDATE_SUBSCRIPTION_IDS || secrets.TEST_SUBSCRIPTION_IDS }}'
        $managementGroup = '${{ vars.VALIDATE_MANAGEMENT_GROUP_ID || vars.ARM_MGMTGROUP_ID || secrets.VALIDATE_MANAGEMENT_GROUP_ID || secrets.ARM_MGMTGROUP_ID }}'
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_initialize_subscription_selection.steps[-1].env.TEST_SUBSCRIPTION_IDS | Should -BeExactly $pool
            $jobs.job_initialize_subscription_selection.steps[-1].env.VALIDATE_MODULE_CLIENT_IDS |
                Should -BeExactly '${{ vars.VALIDATE_MODULE_CLIENT_IDS }}'
            $jobs.job_initialize_subscription_selection.steps[-1].env.VALIDATE_TENANT_ID |
                Should -BeExactly '${{ vars.VALIDATE_TENANT_ID || secrets.VALIDATE_TENANT_ID }}'
            foreach ($jobName in @('job_psrule_must', 'job_psrule_opt')) {
                $jobs[$jobName].steps[-1].env.TEST_SUBSCRIPTION_IDS | Should -BeExactly $pool
                $jobs[$jobName].steps[-1].env.ARM_MGMTGROUP_ID | Should -BeExactly $managementGroup
                $jobs[$jobName].steps[-1].env.Contains('AZURE_CREDENTIALS') | Should -BeFalse
            }
        }
        $deployment = $script:workflows['bicep-module-deployment'].jobs.job_module_deploy_validation.steps[-1].with
        $deployment.subscriptionPool | Should -BeExactly $pool
        $deployment.managementGroupId | Should -BeExactly $managementGroup
        $deployment.fallbackSubscriptionId | Should -BeExactly '${{ vars.VALIDATE_SUBSCRIPTION_ID || secrets.VALIDATE_SUBSCRIPTION_ID }}'
        $deployment.moduleClientIds | Should -BeExactly '${{ vars.VALIDATE_MODULE_CLIENT_IDS }}'
        $deployment.tenantId | Should -BeExactly '${{ vars.VALIDATE_TENANT_ID || secrets.VALIDATE_TENANT_ID }}'
        $deployment.Contains('clientId') | Should -BeFalse
        $deployment.Contains('azureCredentials') | Should -BeFalse
        $selection = $script:actions['bicep-subscription-selection'].runs.steps[-1].run
        $selection | Should -Match 'ModuleClientIds = \$env:VALIDATE_MODULE_CLIENT_IDS'
        $selection | Should -Match 'PoolJson = \$env:TEST_SUBSCRIPTION_IDS'
        foreach ($name in @('bicep-module-preview', 'bicep-module-publish')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_module_deploy_validation.with.tokenNamePrefix | Should -BeExactly 'gci'
            $jobs.job_psrule_must.steps[-1].env.TOKEN_NAMEPREFIX | Should -BeExactly 'gci'
            $jobs.job_psrule_opt.steps[-1].env.TOKEN_NAMEPREFIX | Should -BeExactly 'gci'
        }
    }

    It 'confines CI contexts to input validation and deployment and preserves cleanup order' {
        $steps = $script:actions['bicep-deployment'].runs.steps
        $ids = @($steps | Where-Object { $_['id'] } | ForEach-Object id)
        $ids | Should -Be @('auth', 'setup', 'login_oidc', 'context', 'deploy', 'renew_oidc', 'complete')
        foreach ($step in $steps) {
            if ($step.Contains('env') -and ($step.env['AVM_CI_SECRETS'] -or $step.env['AVM_CI_VARIABLES'])) { $step.id | Should -BeIn @('auth', 'deploy') }
            if ($step['id'] -in @('renew_oidc', 'complete') -or $step.name -eq 'Recover unfinished native cleanup') {
                $step.if | Should -Match '!cancelled\(\)'
            }
        }
        $steps[-1].if | Should -Match 'always\(\)'
        $steps[-1].with.path | Should -Match 'avm-bicep-state'
        ($steps | Where-Object { $_['id'] -eq 'login_oidc' }).with.'subscription-id' |
            Should -BeExactly ($steps | Where-Object { $_['id'] -eq 'renew_oidc' }).with.'subscription-id'
        ($steps | Where-Object name -EQ 'Recover unfinished native cleanup').if | Should -Match "removeDeployment == 'true'"
    }

    It 'pins both login clients and every native phase to the same checked module identity' {
        $action = $script:actions['bicep-deployment']
        $action.inputs.moduleClientIds.required | Should -BeTrue
        $action.inputs.Contains('clientId') | Should -BeFalse
        $action.inputs.Contains('azureCredentials') | Should -BeFalse
        $action.inputs.Contains('avm-authoring-version') | Should -BeFalse
        $auth = $action.runs.steps | Where-Object { $_['id'] -eq 'auth' }
        $auth.env.Contains('AVM_AUTHORING_VERSION') | Should -BeFalse
        $auth.env.VALIDATE_MODULE_CLIENT_IDS | Should -BeExactly '${{ inputs.moduleClientIds }}'
        $auth.run | Should -Match 'ModuleClientIds = \$env:VALIDATE_MODULE_CLIENT_IDS'
        $auth.run | Should -Match 'Initialize-AvmWorkflow -Profile Matrix '
        $auth.run.IndexOf('Initialize-AvmWorkflow') | Should -BeLessThan $auth.run.IndexOf('Get-AvmWorkflowAuthentication')
        $logins = @($action.runs.steps | Where-Object { $_['uses'] -like 'azure/login@*' })
        $logins.Count | Should -Be 2
        foreach ($login in $logins) {
            $login.with.'client-id' | Should -BeExactly '${{ steps.auth.outputs.clientId }}'
            $login.with.'tenant-id' | Should -BeExactly '${{ steps.auth.outputs.tenantId }}'
            $login.with.'subscription-id' | Should -BeExactly '${{ steps.auth.outputs.subscriptionId }}'
            $login.with.'enable-AzPSSession' | Should -BeTrue
            $login.with.Contains('creds') | Should -BeFalse
        }

        foreach ($step in $action.runs.steps | Where-Object {
                $_['id'] -in @('deploy', 'complete') -or $_.name -eq 'Recover unfinished native cleanup'
            }) {
            $step.env.ARM_CLIENT_ID | Should -BeExactly '${{ steps.auth.outputs.clientId }}'
            $step.env.ARM_TENANT_ID | Should -BeExactly '${{ steps.context.outputs.tenantId }}'
            $step.env.ARM_SUBSCRIPTION_ID | Should -BeExactly '${{ steps.auth.outputs.subscriptionId }}'
            $step.run | Should -Match 'ClientId[ =]+\$env:ARM_CLIENT_ID'
        }
        foreach ($path in @(
                '.github/actions/bicep-deployment/action.yml',
                '.github/workflows/bicep-module-deployment.yml',
                'scripts/bicep-workflows/Deployment.ps1'
            )) {
            (Get-Content -LiteralPath (Join-Path $script:root $path) -Raw) |
                Should -Not -Match 'VALIDATE_CLIENT_ID|AZURE_CREDENTIALS|oidc-exceptions|useSecret'
        }
    }

    It 'keeps prerequisite discovery native and package qualification ahead of Azure login' {
        $action = $script:actions['bicep-deployment']
        $steps = @($action.runs.steps)
        $setup = $steps | Where-Object { $_['id'] -eq 'setup' }
        $login = $steps | Where-Object { $_['id'] -eq 'login_oidc' }
        [array]::IndexOf($steps, $setup) | Should -BeLessThan ([array]::IndexOf($steps, $login))
        $setup.run | Should -Match 'Initialize-AvmWorkflow.*-Profile Deployment'
        $setup.env.MODULE_PATH | Should -BeExactly '${{ steps.auth.outputs.modulePath }}'
        $setup.run | Should -Match 'Initialize-AvmWorkflow .* -Path \$modulePath '
        $setup.Contains('continue-on-error') | Should -BeFalse
        $login.Contains('if') | Should -BeFalse
        $action.inputs.modulePath.description | Should -Match '\.required-features\.json'
        $action.inputs.modulePath.description | Should -Match '\.required-resource-providers\.json'
        $action.inputs.modulePath.description | Should -Match 'exact.*path'
        ($steps | ConvertTo-Json -Depth 20) | Should -Not -Match 'Register-.*(Feature|Provider)|required-resource-providers'
    }

    It 'uses the authenticated owning module for exact native prerequisites and completion' {
        $steps = $script:actions['bicep-deployment'].runs.steps
        foreach ($step in $steps | Where-Object { $_['id'] -in @('deploy', 'complete') }) {
            $step.env.MODULE_PATH | Should -BeExactly '${{ steps.auth.outputs.modulePath }}'
            $step.run | Should -Match 'ModulePath = \$env:MODULE_PATH'
        }
        $deploy = $steps | Where-Object { $_['id'] -eq 'deploy' }
        $deploy.env.SELECTED_EXAMPLE | Should -BeExactly '${{ steps.auth.outputs.example }}'
        $deploy.env.Contains('TEST_CASE') | Should -BeFalse
        $deploy.run | Should -Match 'Example = \$env:SELECTED_EXAMPLE'
        $deploy.run | Should -Not -Match 'Example = \$case.path'
        ($steps | Where-Object { $_['id'] -eq 'auth' }).env.MODULE_PATH | Should -BeExactly '${{ inputs.modulePath }}'
    }

    It 'selects completion for deploy <Deploy>, renewal <Renew> and cancellation <Cancelled>' -ForEach @(
        @{ Deploy = 'success'; Renew = 'success'; Cancelled = $false; Expected = $true }
        @{ Deploy = 'failure'; Renew = 'success'; Cancelled = $false; Expected = $true }
        @{ Deploy = 'skipped'; Renew = 'success'; Cancelled = $false; Expected = $false }
        @{ Deploy = 'cancelled'; Renew = 'success'; Cancelled = $false; Expected = $false }
        @{ Deploy = 'success'; Renew = 'failure'; Cancelled = $false; Expected = $false }
        @{ Deploy = 'failure'; Renew = 'failure'; Cancelled = $false; Expected = $false }
        @{ Deploy = 'failure'; Renew = 'skipped'; Cancelled = $false; Expected = $false }
        @{ Deploy = 'failure'; Renew = 'cancelled'; Cancelled = $false; Expected = $false }
        @{ Deploy = 'success'; Renew = 'success'; Cancelled = $true; Expected = $false }
        @{ Deploy = 'failure'; Renew = 'success'; Cancelled = $true; Expected = $false }
    ) {
        $steps = $script:actions['bicep-deployment'].runs.steps
        $complete = $steps | Where-Object { $_['id'] -eq 'complete' }
        $condition = $complete.if.Replace('${{', '').Replace('}}', '').
            Replace('cancelled()', '$Cancelled').Replace('success()', '$Succeeded').Replace('failure()', '$Failed').
            Replace('steps.deploy.outcome', '$Deploy').Replace('steps.renew_oidc.outcome', '$Renew').
            Replace('&&', '-and').Replace('||', '-or').Replace('==', '-eq').Replace('!', '-not ')
        $Succeeded = $Deploy -eq 'success' -and $Renew -eq 'success'
        $Failed = -not $Succeeded
        & ([scriptblock]::Create($condition)) | Should -Be $Expected
        ($steps | Where-Object { $_['id'] -eq 'deploy' }).Contains('continue-on-error') | Should -BeFalse
        $complete.Contains('continue-on-error') | Should -BeFalse
    }

    It 'executes renewal and recovery guards for <Scenario>' -ForEach @(
        @{ Scenario = 'success'; Deploy = 'success'; Renew = 'success'; Complete = 'success'; Remove = 'true'; Cancelled = $false; Expected = @($true, $true, $false) }
        @{ Scenario = 'failed deployment'; Deploy = 'failure'; Renew = 'success'; Complete = 'failure'; Remove = 'true'; Cancelled = $false; Expected = @($true, $true, $true) }
        @{ Scenario = 'failed retained deployment'; Deploy = 'failure'; Renew = 'success'; Complete = 'failure'; Remove = 'false'; Cancelled = $false; Expected = @($true, $true, $false) }
        @{ Scenario = 'skipped deployment'; Deploy = 'skipped'; Renew = 'skipped'; Complete = 'skipped'; Remove = 'true'; Cancelled = $false; Expected = @($false, $false, $false) }
        @{ Scenario = 'failed renewal'; Deploy = 'failure'; Renew = 'failure'; Complete = 'skipped'; Remove = 'true'; Cancelled = $false; Expected = @($true, $false, $false) }
        @{ Scenario = 'failed completion'; Deploy = 'success'; Renew = 'success'; Complete = 'failure'; Remove = 'true'; Cancelled = $false; Expected = @($true, $true, $true) }
        @{ Scenario = 'cancelled deployment'; Deploy = 'cancelled'; Renew = 'skipped'; Complete = 'skipped'; Remove = 'true'; Cancelled = $true; Expected = @($false, $false, $false) }
        @{ Scenario = 'cancellation after deployment'; Deploy = 'success'; Renew = 'skipped'; Complete = 'skipped'; Remove = 'true'; Cancelled = $true; Expected = @($false, $false, $false) }
    ) {
        $steps = $script:actions['bicep-deployment'].runs.steps
        $selected = @(
            $steps | Where-Object { $_['id'] -eq 'renew_oidc' }
            $steps | Where-Object { $_['id'] -eq 'complete' }
            $steps | Where-Object name -EQ 'Recover unfinished native cleanup'
        )
        $priorOutcomes = [Collections.Generic.List[string]]::new()
        $priorOutcomes.Add($Deploy)
        for ($index = 0; $index -lt $selected.Count; $index++) {
            $Succeeded = -not $Cancelled -and -not $priorOutcomes.Contains('failure')
            $Failed = -not $Cancelled -and $priorOutcomes.Contains('failure')
            $condition = $selected[$index].if.Replace('${{', '').Replace('}}', '').
                Replace('cancelled()', '$Cancelled').Replace('success()', '$Succeeded').Replace('failure()', '$Failed').
                Replace('steps.deploy.outcome', '$Deploy').Replace('steps.renew_oidc.outcome', '$Renew').
                Replace('fromJSON(inputs.workflowInput).removeDeployment', '$Remove').
                Replace('!=', '-ne').Replace('&&', '-and').Replace('||', '-or').Replace('==', '-eq').Replace('!', '-not ')
            & ([scriptblock]::Create($condition)) | Should -Be $Expected[$index]
            $selected[$index].Contains('continue-on-error') | Should -BeFalse
            if ($index -eq 0) { $priorOutcomes.Add($Renew) }
            if ($index -eq 1) { $priorOutcomes.Add($Complete) }
        }
    }

    It 'requires mapping selection only for requested Azure tests, never static, preview or tag-only work' {
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_initialize_subscription_selection.if |
                Should -Match "deploymentValidation == 'true'"
            $jobs.job_module_deploy_validation.if |
                Should -Match "deploymentValidation == 'true'"
            $jobs.job_module_deploy_validation.if |
                Should -Match "inputs.moduleTestFilePaths != '\[\]'"
            foreach ($jobName in @('job_module_static_validation', 'job_psrule_must', 'job_psrule_opt', 'job_preview_module', 'job_publish_module')) {
                if (-not $jobs.Contains($jobName)) { continue }
                $job = $jobs[$jobName] | ConvertTo-Json -Depth 30
                $job | Should -Not -Match 'VALIDATE_MODULE_CLIENT_IDS|moduleClientIds|azure/login@|id-token'
            }
        }
        foreach ($name in @('bicep-module-static', 'bicep-module-publish-only')) {
            $script:workflows.ContainsKey($name) | Should -BeTrue
            ($script:workflows[$name] | ConvertTo-Json -Depth 30) |
                Should -Not -Match 'VALIDATE_MODULE_CLIENT_IDS|moduleClientIds|azure/login@|id-token'
        }
    }

    It 'skips protected generic selection for <Scenario>' -ForEach @(
        @{ Scenario = 'empty tests'; Files = '[]'; Enabled = 'true'; Expected = $false }
        @{ Scenario = 'missing tests'; Files = ''; Enabled = 'true'; Expected = $false }
        @{ Scenario = 'disabled deployment'; Files = '[{"path":"tests/e2e/defaults/main.test.bicep","e2eIgnore":false}]'; Enabled = 'false'; Expected = $false }
        @{ Scenario = 'active tests'; Files = '[{"path":"tests/e2e/defaults/main.test.bicep","e2eIgnore":false}]'; Enabled = 'true'; Expected = $true }
        @{ Scenario = 'ignored test records'; Files = '[{"path":"tests/e2e/defaults/main.test.bicep","e2eIgnore":true}]'; Enabled = 'true'; Expected = $true }
    ) {
        foreach ($name in @('bicep-module-preview', 'bicep-module-publish')) {
            $expression = $script:workflows[$name].jobs.job_initialize_subscription_selection.if.
                Replace('fromJSON(inputs.workflowInput).deploymentValidation', '$Enabled').
                Replace('inputs.moduleTestFilePaths', '$Files').
                Replace('!=', '-cne').Replace('==', '-ceq').Replace('&&', '-and')
            & ([scriptblock]::Create($expression)) | Should -Be $Expected
        }
    }

    It 'preserves deployment defaults when a custom location is supplied: <Provided>' -ForEach @(
        @{ Provided = $false }
        @{ Provided = $true }
    ) {
        $deploy = $script:actions['bicep-deployment'].runs.steps | Where-Object { $_['id'] -eq 'deploy' }
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($deploy.run, [ref]$tokens, [ref]$errors)
        $assignment = @($ast.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $_.Left.VariablePath.UserPath -eq 'parameters'
            })
        $assignment.Count | Should -Be 1
        $workflowInput = @{ removeDeployment = 'true' }
        if ($Provided) { $workflowInput.customLocation = 'northeurope' }
        $savedTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP')
        $savedExample = [Environment]::GetEnvironmentVariable('SELECTED_EXAMPLE')
        try {
            $env:RUNNER_TEMP = $TestDrive
            $env:SELECTED_EXAMPLE = 'tests/e2e/defaults/main.test.bicep'
            $parameters = & ([scriptblock]::Create($assignment[0].Extent.Text + "`n" + '$parameters'))
            $parameters.RemoveDeployment | Should -BeTrue
            $parameters.Example | Should -BeExactly $env:SELECTED_EXAMPLE
            if ($Provided) { $parameters.CustomLocation | Should -BeExactly 'northeurope' }
            else { $parameters.CustomLocation | Should -BeNullOrEmpty }
        }
        finally {
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $(if ($null -eq $savedTemp) { [NullString]::Value } else { $savedTemp }))
            [Environment]::SetEnvironmentVariable('SELECTED_EXAMPLE', $(if ($null -eq $savedExample) { [NullString]::Value } else { $savedExample }))
        }
    }
}

Describe 'Bicep release-tag safety contracts' {
    It 'serializes every release variant and limits writes to actual publishing jobs' {
        foreach ($name in @('bicep-module', 'bicep-module-preview', 'bicep-module-publish', 'bicep-module-publish-only')) {
            $jobName = if ($name -eq 'bicep-module-preview') { 'job_preview_module' } else { 'job_publish_module' }
            $job = $script:workflows[$name].jobs[$jobName]
            $job.concurrency.group | Should -BeExactly 'avm-publish-${{ inputs.modulePath }}'
            $job.concurrency.queue | Should -Be 'max'
            $job.if | Should -Match "github.repository == 'Azure/bicep-registry-modules'"
            $job.if | Should -Match "github.ref == 'refs/heads/main'"
            $job.permissions.Contains('id-token') | Should -BeFalse
            $job.permissions.contents | Should -Be $(if ($name -eq 'bicep-module-preview') { 'read' } else { 'write' })
        }
    }

    It 'passes pending-release semantics through the tag-only publication path' {
        $release = $script:entrypoints | Where-Object name -EQ 'Reusable: Bicep release'
        $release.jobs.release.permissions.contents | Should -BeExactly 'write'
        $release.jobs.release.with.pendingRelease | Should -BeTrue
        $release.jobs.release.with.requireChangelog | Should -BeTrue
        $release.jobs.release.with.requirePublishApproval | Should -BeTrue
        $release.jobs.release.with.Contains('baseCommit') | Should -BeFalse
        $runtime = $script:workflows['bicep-module-runtime-release']
        $runtime.on.workflow_call.inputs.pendingRelease.default | Should -BeFalse
        $runtime.on.workflow_call.inputs.requireChangelog.default | Should -BeFalse
        $tagging = $runtime.jobs.release.steps | Where-Object { $_.name -eq 'Create module release tags' }
        $tagging.env.PENDING_RELEASE | Should -BeExactly '${{ inputs.pendingRelease }}'
        $tagging.env.REQUIRE_CHANGELOG | Should -BeExactly '${{ inputs.requireChangelog }}'
        $tagging.run | Should -Match 'Set-AvmBicepReleaseTags'
    }

    It 'preserves preview-only push behavior and explicit release approval' {
        $preview = $script:workflows['bicep-module-preview'].jobs.job_preview_module
        $preview.if | Should -Match "github.event_name == 'push'"
        $preview.if | Should -Match 'includeAllVersionedModules'
        $preview.steps[-1].with.preview | Should -Be 'true'
        foreach ($name in @('bicep-module-publish', 'bicep-module-publish-only')) {
            $jobs = $script:workflows[$name].jobs
            $jobs.job_publish_approval.environment | Should -BeExactly 'publish-approval'
            $jobs.job_publish_module.if | Should -Match "job_publish_approval.result == 'success'"
        }
        $script:workflows['bicep-module-publish'].jobs.job_publish_module.if | Should -Match 'inputs.publishReleaseTag'
        @($script:workflows['bicep-module-publish-only'].jobs.Keys).Count | Should -Be 2
    }
}
