. (Join-Path $PSScriptRoot 'TerraformQualification.ps1')

function Get-TerraformAcceptanceFiles {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [hashtable] $Authored = @{},
        [string[]] $ConfigurationDirectories = @()
    )

    $files = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -Force -File) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        $parts = $relative -split '/'
        if ($parts[0] -ceq '.git' -or ($parts -ccontains '.terraform' -and -not $Authored.ContainsKey($relative))) { continue }
        $directory = [IO.Path]::GetDirectoryName($relative).Replace('\', '/')
        if ($file.Name -ceq '.terraform.lock.hcl' -and -not $Authored.ContainsKey($relative) -and
            $directory -cin $ConfigurationDirectories) { continue }
        $files[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $files
}

function Assert-TerraformAcceptanceFiles {
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [hashtable] $Expected
    )

    $actual = Get-TerraformAcceptanceFiles -Root $Context.Root -Authored $Expected `
        -ConfigurationDirectories $Context.ConfigurationDirectories
    $changes = @(
        foreach ($path in $Expected.Keys) {
            if (-not $actual.ContainsKey($path)) { "deleted: $path" }
            elseif ($actual[$path] -cne $Expected[$path]) { "modified: $path" }
        }
        foreach ($path in $actual.Keys) {
            if (-not $Expected.ContainsKey($path)) { "added: $path" }
        }
    )
    $details = $changes -join "`n"
    if ($changes.Count -gt 0) {
        $diff = Invoke-TerraformAcceptanceGit -Root $Context.Root -Arguments @('diff', '--no-ext-diff', '--no-color', '--')
        $details += "`n" + $diff.StdOut
    }
    $changes | Should -HaveCount 0 -Because $details
}

function Invoke-TerraformAcceptanceGit {
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] [string[]] $Arguments)
    & (Get-Module Avm.Authoring) {
        param($Root, $Arguments)
        $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        Invoke-AvmProcess -FilePath $git -ArgumentList (@(
                '-c', 'core.autocrlf=false', '-c', 'commit.gpgsign=false',
                '-c', 'user.name=AVM Acceptance', '-c', 'user.email=avm-tests@example.invalid',
                '-c', ('core.hooksPath=' + (Join-Path $Root '.git' 'no-hooks'))
            ) + $Arguments) -WorkingDirectory $Root
    } $Root $Arguments
}

function New-TerraformAcceptanceContext {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Name,
        [string] $Overlay,
        [switch] $InitializeLock
    )

    $work = Join-Path ([IO.Path]::GetTempPath()) ('avm-accept-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $root = Join-Path $work $Name
    $null = New-Item -ItemType Directory -Path $work
    Copy-Item -LiteralPath $Source -Destination $root -Recurse -Force
    if ($Overlay) {
        foreach ($file in Get-ChildItem -LiteralPath $Overlay -Recurse -Force -File) {
            $destination = Join-Path $root ([IO.Path]::GetRelativePath($Overlay, $file.FullName))
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        }
    }
    $managed = Join-Path $work 'managed' 'root'
    $null = New-Item -ItemType Directory -Path $managed -Force
    Copy-Item -LiteralPath (Join-Path $Source '.gitignore') -Destination $managed
    $environment = @{}
    foreach ($key in @('AVM_MANAGED_FILES_LOCAL_PATH', 'TF_DATA_DIR', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init',
            'TF_CLI_ARGS_plan', 'TF_CLI_ARGS_test', 'TF_CLI_ARGS_validate', 'MODTM_ENDPOINT')) {
        $environment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [NullString]::Value, 'Process')
    }
    $env:AVM_MANAGED_FILES_LOCAL_PATH = Split-Path $managed -Parent
    $env:MODTM_ENDPOINT = 'http://127.0.0.1:1'
    $context = [pscustomobject]@{
        Root = $root
        Work = $work
        Authored = @{}
        ConfigurationDirectories = @()
        Environment = $environment
    }
    try {
        if ($InitializeLock) {
            if ($IsWindows) {
                # Terraform 1.16.5 reuses downloads with Mkdir on Windows test-file module keys.
                $null = [IO.Directory]::CreateDirectory((Join-Path $root '.terraform' 'modules' 'test.tests' 'unit'))
            }
            $null = & (Get-Module Avm.Authoring) {
                param($Root)
                $tool = Resolve-AvmTool -Name terraform
                Invoke-AvmProcess -FilePath $tool.Path -WorkingDirectory $Root -ArgumentList @(
                    'init', '-backend=false', '-input=false', '-no-color', '-test-directory=tests/unit'
                )
            } $root
        }
        $context.Authored = Get-TerraformAcceptanceFiles -Root $root
        $context.ConfigurationDirectories = @(
            foreach ($relative in $context.Authored.Keys | Where-Object { $_.EndsWith('.tf', [StringComparison]::Ordinal) }) {
                [IO.Path]::GetDirectoryName($relative).Replace('\', '/')
            }
        ) | Sort-Object -Unique
        $null = Invoke-TerraformAcceptanceGit -Root $root -Arguments @('init', '--quiet', '--initial-branch=acceptance')
        $null = Invoke-TerraformAcceptanceGit -Root $root -Arguments @('remote', 'add', 'origin', "https://github.com/Azure/$Name")
        $null = Invoke-TerraformAcceptanceGit -Root $root -Arguments (@('add', '--force', '--') + @($context.Authored.Keys))
        $null = Invoke-TerraformAcceptanceGit -Root $root -Arguments @('commit', '--quiet', '-m', 'test: canonical acceptance input')
        return $context
    }
    catch {
        Remove-TerraformAcceptanceContext -Context $context
        throw
    }
}

function Remove-TerraformAcceptanceContext {
    param([Parameter(Mandatory)] [object] $Context)
    foreach ($key in $Context.Environment.Keys) {
        $value = $Context.Environment[$key]
        [Environment]::SetEnvironmentVariable($key, $(if ($null -eq $value) { [NullString]::Value } else { $value }), 'Process')
    }
    Remove-Item -LiteralPath $Context.Work -Recurse -Force -ErrorAction Stop
}

function Assert-TerraformAcceptanceSteps {
    param([Parameter(Mandatory)] [object] $Result, [Parameter(Mandatory)] [string[]] $Names)
    $Result.Status | Should -BeExactly 'pass'
    @($Result.Steps.Step) | Should -Be $Names
    foreach ($step in $Result.Steps) {
        $step.Status | Should -BeExactly 'pass' -Because "$($step.Step): $($step.Error)"
    }
}

function Assert-TerraformAcceptanceCredentials {
    $env:ARM_USE_OIDC | Should -BeExactly 'true' -Because 'full public pr-check requires the authorized CI OIDC policy-plan identity; no policy exclusion or CLI fallback is allowed'
    foreach ($name in @('ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID')) {
        [Environment]::GetEnvironmentVariable($name) | Should -Not -BeNullOrEmpty -Because "$name is required for the full policy check"
    }
}

function Invoke-TerraformAcceptancePreCommit {
    param([Parameter(Mandatory)] [object] $Context)
    $result = avm pre-commit --path $Context.Root --ecosystem terraform --passthru -SkipModuleVersionCheck
    Assert-TerraformAcceptanceSteps -Result $result -Names @('metadata', 'initialize', 'sync', 'check convention', 'transform', 'format', 'docs')
    return $result
}

function Invoke-TerraformAcceptancePrCheck {
    param([Parameter(Mandatory)] [object] $Context)
    Assert-TerraformAcceptanceCredentials
    $result = avm pr-check --path $Context.Root --ecosystem terraform --passthru -SkipModuleVersionCheck
    Assert-TerraformAcceptanceSteps -Result $result -Names @('metadata', 'initialize', 'sync', 'format', 'transform', 'lint', 'check policy', 'check convention', 'validate', 'docs')
    $policy = $result.Steps | Where-Object Step -eq 'check policy'
    $policy.Result.Evaluated | Should -BeGreaterThan 0
    @($policy.Result.Issues) | Should -HaveCount 0
    return $result
}

function Invoke-TerraformAcceptanceUnit {
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [int] $Runs
    )

    $environment = @{}
    try {
        foreach ($name in @('ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_CLIENT_CERTIFICATE_PATH',
                'ARM_CLIENT_CERTIFICATE_PASSWORD', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID',
                'ARM_OIDC_TOKEN', 'ARM_OIDC_TOKEN_FILE_PATH', 'ARM_OIDC_REQUEST_TOKEN',
                'ARM_OIDC_REQUEST_URL', 'ARM_USE_OIDC', 'ARM_USE_CLI', 'ARM_USE_MSI')) {
            $environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        }
        $env:ARM_USE_OIDC = 'false'
        $env:ARM_USE_CLI = 'false'
        $env:ARM_USE_MSI = 'false'
        $result = InModuleScope Avm.Authoring -Parameters @{
            Root = $Context.Root
            Guard = ${function:Invoke-MockedTerraformQualification}
        } {
            param($Root, $Guard)
            $script:qualificationOriginalProcess = (Get-Command Invoke-AvmProcess).ScriptBlock
            $script:qualificationGuard = $Guard
            $script:qualificationTerraform = (Resolve-AvmTool -Name terraform -ModuleRoot $Root).Path
            $script:qualificationMapotf = (Resolve-AvmTool -Name mapotf -ModuleRoot $Root).Path
            $script:qualificationProfiles = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Resources' 'mapotf'
            $script:qualificationRuntimeCount = 0
            $paths = @($Root) + @(Get-AvmTerraformFile -Root $Root |
                    Where-Object Extension -CEQ '.tf' | ForEach-Object DirectoryName)
            $script:qualificationTargets = @(
                foreach ($path in @($paths | Sort-Object -Unique)) {
                    [pscustomobject]@{ Path = $path; Scope = if ($path -ceq $Root) { 'root' } else { 'test' } }
                }
            )
            Mock Invoke-AvmProcess {
                if ([IO.Path]::GetFileNameWithoutExtension($FilePath) -ceq 'terraform' -and
                    $ArgumentList[0] -cin @('test', 'apply', 'destroy', 'import')) {
                    throw [InvalidOperationException]::new('Acceptance refuses an unguarded Terraform execution path.')
                }
                & $script:qualificationOriginalProcess @PesterBoundParameters
            }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -cin @('apply', 'destroy', 'import')) {
                    throw [InvalidOperationException]::new('Acceptance forbids direct real-provider mutation commands.')
                }
                $forward = @{} + $PesterBoundParameters
                if ($ArgumentList[0] -ceq 'test') {
                    $forward.EnvVars = & $script:qualificationGuard -TerraformPath $FilePath `
                        -MapotfPath $script:qualificationMapotf -ProfilesRoot $script:qualificationProfiles `
                        -Root $WorkingDirectory -ArgumentList $ArgumentList -Environment (@{} + $EnvVars) `
                        -ModuleTargets $script:qualificationTargets -InspectOnly
                    $script:qualificationRuntimeCount++
                }
                & $script:qualificationOriginalProcess @forward
            } -ParameterFilter { $FilePath -ceq $script:qualificationTerraform }
            $unit = avm test unit --path $Root --ecosystem terraform --passthru -SkipModuleVersionCheck
            $script:qualificationRuntimeCount | Should -BeGreaterThan 0
            return $unit
        }
        $result.Status | Should -BeExactly 'pass'
        $result.RunsTotal | Should -Be $Runs
        $result.RunsPassed | Should -Be $Runs
        $result.RunsFailed | Should -Be 0
        return $result
    }
    finally {
        foreach ($name in $environment.Keys) {
            $value = $environment[$name]
            [Environment]::SetEnvironmentVariable($name,
                $(if ($null -eq $value) { [NullString]::Value } else { $value }), 'Process')
        }
    }
}
