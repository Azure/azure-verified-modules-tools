#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Component-tier coverage for the Terraform engine wrappers. Exercises
# Invoke-AvmPreCommit, Invoke-AvmPrCheck, and Invoke-AvmCheckPolicy
# against a tiny fixture module via real subprocesses (pwsh-backed stub
# launchers on PATH) instead of cmdlet-level mocks. Proves the argv
# contracts for terraform, tflint, terraform-docs, conftest, and mapotf
# hold end-to-end without the real binaries.
#
# How the harness works:
#   1. The four PowerShell stubs under tests/fixtures/bin/ are wrapped
#      as launcher binaries (cmd shim on Windows, exec script on Unix)
#      into a TestDrive subdir via tests/helpers/Install-AvmStubLauncher.ps1.
#   2. That dir is prepended to $env:PATH for the test's duration.
#   3. $env:AVM_HOME is pointed at a fresh TestDrive subdir so the
#      managed-cache lookup inside Resolve-AvmTool misses, forcing
#      -AllowPathFallback to take effect and the launchers to be used.
#   4. A minimal terraform module (main.tf + tests/ + README.md with
#      terraform-docs markers) is materialised under TestDrive/module.
#   5. The pinned policy-library cache for avm-policy-aprl and
#      avm-policy-avmsec is pre-staged under $env:AVM_HOME/cache/assets/
#      (cache-hit fast-path) with AVM_POLICY_LIBRARY_REF/_SHA256 overriding
#      the shipped pin, so Invoke-AvmTerraformCheckPolicy resolves both
#      bundles without ever calling Invoke-AvmHttp.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module -Name $script:moduleManifest -Force

    $stubDir = Join-Path $script:repoRoot 'tests' 'fixtures' 'bin'
    $helper = Join-Path $script:repoRoot 'tests' 'helpers' 'Install-AvmStubLauncher.ps1'
    . $helper

    $script:launcherDir = Install-AvmStubLauncher `
        -StubDir $stubDir `
        -LauncherDir (Join-Path $TestDrive 'bin') `
        -PinsPath (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Resources' 'avm.pins.jsonc')

    $script:originalPath = $env:PATH
    $script:originalAvmHome = $env:AVM_HOME
    $script:originalManagedFilesLocalPath = $env:AVM_MANAGED_FILES_LOCAL_PATH
    $env:PATH = $script:launcherDir + [IO.Path]::PathSeparator + $env:PATH
    $env:AVM_HOME = Join-Path $TestDrive 'avm-home'

    # Point the managed-files sync engine at an empty local source so the
    # sync step (now first in the pre-commit chain) is a deterministic
    # offline no-op: an empty 'root/' yields zero desired files, so the
    # engine reports Status='pass' with FilesProcessed=0 and never fetches
    # the governance repo over the network.
    $script:managedFilesLocal = Join-Path $TestDrive 'managed-files-src'
    $null = New-Item -ItemType Directory -Path (Join-Path $script:managedFilesLocal 'root') -Force
    $env:AVM_MANAGED_FILES_LOCAL_PATH = $script:managedFilesLocal

    $script:fixtureRoot = Join-Path $TestDrive 'module'
    $null = New-Item -ItemType Directory -Path $script:fixtureRoot -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $script:fixtureRoot 'tests/unit') -Force

    # Pre-stage the pinned policy-library cache so
    # Invoke-AvmTerraformCheckPolicy's Resolve-AvmPinnedAsset short-circuits
    # via the cache-hit fast-path without ever calling Invoke-AvmHttp.
    # AVM_POLICY_LIBRARY_REF/_SHA256 override the shipped pin so the fixture
    # controls both the archive-root name and the content-addressed cache
    # segment. Resolve-AvmPinnedAsset content-addresses by a 12-hex prefix of
    # the SHA256 (spec section 6 line 220), not the full 64-char hash, so the
    # .verified marker must live under that same prefixed segment. Both
    # bundles come from one archive, hence one SHA but two asset names.
    $script:originalPolicyRef = $env:AVM_POLICY_LIBRARY_REF
    $script:originalPolicySha = $env:AVM_POLICY_LIBRARY_SHA256
    $script:policySha = 'a' * 64
    $env:AVM_POLICY_LIBRARY_REF = 'v0.0.0-fixture'
    $env:AVM_POLICY_LIBRARY_SHA256 = $script:policySha

    $archiveRoot = 'policy-library-avm-0.0.0-fixture'
    $cacheRoot = Join-Path $env:AVM_HOME 'cache'
    $bundles = @(
        @{ Name = 'avm-policy-aprl'; Sub = "$archiveRoot/policy/Azure-Proactive-Resiliency-Library-v2"; File = 'aprl-fixture.rego'; Package = 'aprl' }
        @{ Name = 'avm-policy-avmsec'; Sub = "$archiveRoot/policy/avmsec"; File = 'avmsec-fixture.rego'; Package = 'avmsec' }
    )
    foreach ($bundle in $bundles) {
        $versionDir = Join-Path (Join-Path (Join-Path $cacheRoot 'assets') $bundle.Name) $script:policySha.Substring(0, 12)
        $bundleDir = Join-Path $versionDir ($bundle.Sub -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $null = New-Item -ItemType Directory -Path $bundleDir -Force
        Set-Content -LiteralPath (Join-Path $versionDir '.verified') -Value '' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $bundleDir $bundle.File) -Value "package $($bundle.Package)`n" -Encoding utf8NoBOM
        if ($bundle.Name -eq 'avm-policy-avmsec') {
            Set-Content -LiteralPath (Join-Path $bundleDir 'avm_exceptions.rego.bak') -Value "package avmsec`n" -Encoding utf8NoBOM
        }
    }

    $mainTf = @(
        '# AVM integration fixture module',
        'terraform {',
        '  required_version = ">= 1.0"',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'main.tf') -Value $mainTf -Encoding utf8NoBOM

    $readme = @(
        '# Fixture',
        '',
        '<!-- BEGIN_TF_DOCS -->',
        '<!-- END_TF_DOCS -->'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'README.md') -Value $readme -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'tests/unit' 'main.tftest.hcl') -Value '# fixture' -Encoding utf8NoBOM

    # Per-example exception .rego fixture so the integration smoke also
    # exercises Invoke-AvmTerraformCheckPolicy's per-example exceptions
    # discovery path end-to-end. The stub conftest does not load the
    # file; this only proves the engine builds argv without throwing.
    $exDir = Join-Path $script:fixtureRoot 'examples' 'foo' 'exceptions'
    $null = New-Item -ItemType Directory -Path $exDir -Force
    Set-Content -LiteralPath (Join-Path $exDir 'example.rego') -Value "package example`n" -Encoding utf8NoBOM

    # Slice D: materialise the files required by the built-in
    # convention rules so Invoke-AvmCheckConvention still reports
    # Status=pass against the fixture. AppliesTo='all' rules
    # (terraform-tf-must-exist + header-md-must-exist) require these
    # files at root AND under each immediate examples/* subdir; the
    # other Slice D rules either fire at root only (examples/, tests/)
    # or trip only when the wrong filename exists
    # (output.tf / variable.tf) -- so absence here is the pass state.
    $terraformTf = @(
        'terraform {',
        '  required_version = ">= 1.0"',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'terraform.tf') -Value $terraformTf -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot '_header.md') -Value "# Fixture module`n" -Encoding utf8NoBOM

    $exampleDir = Join-Path $script:fixtureRoot 'examples' 'foo'
    Set-Content -LiteralPath (Join-Path $exampleDir 'terraform.tf') -Value $terraformTf -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $exampleDir '_header.md') -Value "# Fixture example`n" -Encoding utf8NoBOM
    $script:tflintHookMarker = Join-Path $env:AVM_HOME 'tflint-hook-ran'
    $tflintHook = @(
        "Set-Content -LiteralPath '$($script:tflintHookMarker.Replace("'", "''"))' -Value 'ran' -Encoding utf8NoBOM"
        'Set-Content -LiteralPath (Join-Path $PSScriptRoot ''hook-output.txt'') -Value ''staged'' -Encoding utf8NoBOM'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $exampleDir 'tflint-pre.ps1') -Value $tflintHook -Encoding utf8NoBOM

    & git -C $script:fixtureRoot init --quiet
    & git -C $script:fixtureRoot config user.name 'AVM Component Tests'
    & git -C $script:fixtureRoot config user.email 'avm-component-tests@example.invalid'
    & git -C $script:fixtureRoot add -A
    & git -C $script:fixtureRoot commit --quiet -m 'Initial fixture'
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize the component fixture Git repository (exit $LASTEXITCODE)."
    }
}

AfterAll {
    if ($null -ne $script:originalPath) { $env:PATH = $script:originalPath }
    if ($null -eq $script:originalAvmHome) {
        Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
    }
    else {
        $env:AVM_HOME = $script:originalAvmHome
    }
    if ($null -eq $script:originalManagedFilesLocalPath) {
        Remove-Item Env:\AVM_MANAGED_FILES_LOCAL_PATH -ErrorAction SilentlyContinue
    }
    else {
        $env:AVM_MANAGED_FILES_LOCAL_PATH = $script:originalManagedFilesLocalPath
    }
    if ($null -eq $script:originalPolicyRef) {
        Remove-Item Env:\AVM_POLICY_LIBRARY_REF -ErrorAction SilentlyContinue
    }
    else {
        $env:AVM_POLICY_LIBRARY_REF = $script:originalPolicyRef
    }
    if ($null -eq $script:originalPolicySha) {
        Remove-Item Env:\AVM_POLICY_LIBRARY_SHA256 -ErrorAction SilentlyContinue
    }
    else {
        $env:AVM_POLICY_LIBRARY_SHA256 = $script:originalPolicySha
    }
    $fixtureGitDir = Join-Path $script:fixtureRoot '.git'
    if (Test-Path -LiteralPath $fixtureGitDir -PathType Container) {
        Get-ChildItem -LiteralPath $fixtureGitDir -File -Recurse -Force |
            ForEach-Object { $_.IsReadOnly = $false }
        Remove-Item -LiteralPath $fixtureGitDir -Recurse -Force
    }
    Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Invoke-AvmPreCommit + Invoke-AvmPrCheck (terraform engine end-to-end)' -Tag 'Component' {
    It 'uses the released AVM ruleset config and omits empty replacement triggers' {
        $pins = InModuleScope 'Avm.Authoring' { Read-AvmPins }
        $configDir = InModuleScope 'Avm.Authoring' { Resolve-AvmTflintConfigDir }
        $config = Get-Content -LiteralPath (Join-Path $configDir 'avm.tflint.hcl') -Raw
        $tflint = Get-Command tflint -CommandType Application -ErrorAction Stop |
            Select-Object -First 1

        $pins.tflintPlugins.avm | Should -Be '1.0.0'
        $config | Should -Match 'version\s*=\s*"1\.0\.0"'
        $config | Should -Not -Match 'replace_triggers_refs\s*='
        (& $tflint.Source --version) | Should -Contain 'ruleset.avm (1.0.0)'
    }

    It 'pre-commit composes the five-step terraform chain end-to-end (sync first) via launcher-resolved stubs and the in-module check-convention rules' {
        $result = Invoke-AvmPreCommit -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Ecosystem'].Value | Should -Be 'terraform'
        $result.PSObject.Properties['Status'].Value | Should -Be 'pass'

        $steps = $result.PSObject.Properties['Steps'].Value
        $steps.Count | Should -Be 5
        $expected = @('sync', 'check convention', 'transform', 'format', 'docs')
        ($steps | ForEach-Object { $_.PSObject.Properties['Step'].Value }) | Should -Be $expected

        $byName = @{}
        foreach ($s in $steps) { $byName[$s.PSObject.Properties['Step'].Value] = $s }

        # sync runs FIRST against an empty local managed-files source
        # (AVM_MANAGED_FILES_LOCAL_PATH -> TestDrive/managed-files-src with an
        # empty root/), so it is an offline no-op: zero desired files, nothing
        # added/updated/removed, Status='pass', ToolSource='local'.
        $byName['sync'].PSObject.Properties['Status'].Value | Should -Be 'pass'
        $syncResult = $byName['sync'].PSObject.Properties['Result'].Value
        $syncResult.PSObject.Properties['Engine'].Value         | Should -Be 'terraform'
        $syncResult.PSObject.Properties['Tool'].Value           | Should -Be 'managed-files'
        $syncResult.PSObject.Properties['ToolSource'].Value     | Should -Be 'local'
        $syncResult.PSObject.Properties['FilesProcessed'].Value | Should -Be 0
        @($syncResult.PSObject.Properties['Added'].Value).Count   | Should -Be 0
        @($syncResult.PSObject.Properties['Updated'].Value).Count | Should -Be 0
        @($syncResult.PSObject.Properties['Removed'].Value).Count | Should -Be 0

        # check convention runs the in-module rule framework; reports
        # ToolSource='builtin' rather than 'path'. Fixture pre-stages
        # every file the seven Slice D rules require.
        $byName['check convention'].PSObject.Properties['Status'].Value | Should -Be 'pass'
        $ccResult = $byName['check convention'].PSObject.Properties['Result'].Value
        $ccResult.PSObject.Properties['Engine'].Value     | Should -Be 'terraform'
        $ccResult.PSObject.Properties['Tool'].Value       | Should -Match '^avm-rules/'
        $ccResult.PSObject.Properties['ToolSource'].Value | Should -Be 'builtin'
        @($ccResult.PSObject.Properties['Issues'].Value).Count | Should -Be 0

        # transform now wraps the mapotf stub via the launcher PATH-fallback.
        # The stub is a no-op, so the engine's before/after hash snapshot
        # finds no changes and reports pass (fix mode, no -CheckDrift here).
        # lint + test are pr-check-only on the terraform chain (they need
        # `terraform init`); pre-commit stays offline. Each passing step
        # below shells out via Invoke-AvmProcess.
        foreach ($passing in @('transform', 'format', 'docs')) {
            $byName[$passing].PSObject.Properties['Status'].Value | Should -Be 'pass'
            $byName[$passing].PSObject.Properties['Error'].Value | Should -BeNullOrEmpty
            $engineResult = $byName[$passing].PSObject.Properties['Result'].Value
            $engineResult | Should -Not -BeNullOrEmpty
            $engineResult.PSObject.Properties['ToolSource'].Value | Should -Be 'path'
            $engineResult.PSObject.Properties['Engine'].Value | Should -Be 'terraform'
        }

        $byName['transform'].PSObject.Properties['Result'].Value.PSObject.Properties['Tool'].Value | Should -Match '^mapotf/'
    }

    It 'pre-commit repairs fixable convention violations without enforcing strict-only rules' {
        $nestedModule = Join-Path $script:fixtureRoot 'modules' 'azure-identity'
        $null = New-Item -ItemType Directory -Path $nestedModule -Force
        Set-Content -LiteralPath (Join-Path $nestedModule 'output.tf') -Value '# output' -Encoding utf8NoBOM

        try {
            $result = Invoke-AvmPreCommit -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

            $result.Status | Should -Be 'pass'
            Join-Path $nestedModule 'output.tf' | Should -Not -Exist
            Join-Path $nestedModule 'outputs.tf' | Should -Exist
            $headerPath = Join-Path $nestedModule '_header.md'
            $headerPath | Should -Exist
            [System.IO.File]::ReadAllText($headerPath) | Should -Be "# Azure Identity`n"
            Join-Path $nestedModule 'terraform.tf' | Should -Not -Exist
        }
        finally {
            Remove-Item -LiteralPath (Join-Path $script:fixtureRoot 'modules') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'pre-commit bootstraps tests/.gitkeep when explicit Terraform context has no tests directory' {
        $bootstrapRoot = Join-Path $TestDrive 'module-without-tests'
        $exampleDir = Join-Path $bootstrapRoot 'examples/default'
        $null = New-Item -ItemType Directory -Path $exampleDir -Force
        Set-Content -LiteralPath (Join-Path $bootstrapRoot 'terraform.tf') -Value $terraformTf -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $bootstrapRoot 'main.tf') -Value $mainTf -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $exampleDir 'main.tf') -Value '# example' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $bootstrapRoot 'README.md') -Value $readme -Encoding utf8NoBOM

        $result = Invoke-AvmPreCommit -Path $bootstrapRoot -Ecosystem terraform -AllowPathFallback

        $result.Status | Should -Be 'pass'
        $result.Path | Should -Be (Resolve-Path -LiteralPath $bootstrapRoot).ProviderPath
        Join-Path $bootstrapRoot 'tests/.gitkeep' | Should -Exist
        @($result.Steps | Where-Object Step -eq 'check convention')[0].Status | Should -Be 'pass'
    }

    It 'pr-check composes eight steps (sync drift-check first) with the transform engine running a mapotf drift-check' {
        $result = Invoke-AvmPrCheck -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Ecosystem'].Value | Should -Be 'terraform'
        $result.PSObject.Properties['Status'].Value | Should -Be 'pass'

        $steps = $result.PSObject.Properties['Steps'].Value
        $steps.Count | Should -Be 8
        $expected = @('sync', 'format', 'transform', 'lint', 'check policy', 'check convention', 'validate', 'docs')
        ($steps | ForEach-Object { $_.PSObject.Properties['Step'].Value }) | Should -Be $expected

        $byName = @{}
        foreach ($s in $steps) { $byName[$s.PSObject.Properties['Step'].Value] = $s }

        # sync runs FIRST under -CheckDrift (drift-check mode) against the empty
        # local managed-files source (AVM_MANAGED_FILES_LOCAL_PATH -> an empty
        # root/), so it writes nothing and finds no drift: Status='pass',
        # ToolSource='local', zero files processed and no add/update/remove.
        $byName['sync'].PSObject.Properties['Status'].Value | Should -Be 'pass'
        $syncResult = $byName['sync'].PSObject.Properties['Result'].Value
        $syncResult.PSObject.Properties['Engine'].Value         | Should -Be 'terraform'
        $syncResult.PSObject.Properties['Tool'].Value           | Should -Be 'managed-files'
        $syncResult.PSObject.Properties['ToolSource'].Value     | Should -Be 'local'
        $syncResult.PSObject.Properties['FilesProcessed'].Value | Should -Be 0
        @($syncResult.PSObject.Properties['Added'].Value).Count   | Should -Be 0
        @($syncResult.PSObject.Properties['Updated'].Value).Count | Should -Be 0
        @($syncResult.PSObject.Properties['Removed'].Value).Count | Should -Be 0
        @($syncResult.PSObject.Properties['Issues'].Value).Count  | Should -Be 0

        # transform runs under -CheckDrift in pr-check; the no-op mapotf stub
        # leaves the tree untouched so the drift-check finds nothing and passes.
        # External-tool passing steps (each shells out via Invoke-AvmProcess).
        foreach ($passing in @('format', 'transform', 'lint', 'validate', 'docs')) {
            $byName[$passing].PSObject.Properties['Status'].Value | Should -Be 'pass'
            $engineResult = $byName[$passing].PSObject.Properties['Result'].Value
            $engineResult.PSObject.Properties['ToolSource'].Value | Should -Be 'path'
            $engineResult.PSObject.Properties['Engine'].Value | Should -Be 'terraform'
        }

        # check convention is pure-PowerShell, so it reports ToolSource='builtin'
        # rather than 'path'. The fixture writes all the files required by the
        # built-in rules in BeforeAll, so every rule passes with zero issues
        # end-to-end.
        $byName['check convention'].PSObject.Properties['Status'].Value | Should -Be 'pass'
        $ccResult = $byName['check convention'].PSObject.Properties['Result'].Value
        $ccResult.PSObject.Properties['Engine'].Value     | Should -Be 'terraform'
        $ccResult.PSObject.Properties['Tool'].Value       | Should -Match '^avm-rules/'
        $ccResult.PSObject.Properties['ToolSource'].Value | Should -Be 'builtin'
        @($ccResult.PSObject.Properties['Issues'].Value).Count | Should -Be 0

        # F59: policy evaluation now plans each example and evaluates the JSON
        # plan independently against APRL and AVMSEC.
        $byName['check policy'].PSObject.Properties['Status'].Value | Should -Be 'pass'
        $policyResult = $byName['check policy'].PSObject.Properties['Result'].Value
        $policyResult.PSObject.Properties['Engine'].Value    | Should -Be 'terraform'
        $policyResult.PSObject.Properties['ToolSource'].Value | Should -Be 'path'
        $policyResult.PSObject.Properties['Evaluated'].Value | Should -Be 260
        @($policyResult.PSObject.Properties['Issues'].Value).Count | Should -Be 0
        $policyResult.PSObject.Properties['Tool'].Value | Should -Match '^conftest/'
        $script:tflintHookMarker | Should -Exist
        Join-Path $script:fixtureRoot 'examples' 'foo' 'hook-output.txt' | Should -Not -Exist
    }

    It 'pr-check rejects a shell hook with PowerShell migration guidance' {
        $shellHook = Join-Path $script:fixtureRoot 'examples' 'foo' 'tflint-pre.sh'
        Set-Content -LiteralPath $shellHook -Value '#!/bin/sh' -Encoding utf8NoBOM
        & git -C $script:fixtureRoot add -- 'examples/foo/tflint-pre.sh'
        & git -C $script:fixtureRoot commit --quiet -m 'Add shell hook fixture'
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to commit the shell-hook fixture (exit $LASTEXITCODE)."
        }

        try {
            $result = Invoke-AvmPrCheck -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
            $result.Status | Should -Be 'fail'

            $lintStep = @($result.Steps | Where-Object Step -eq 'lint')
            $lintStep.Count | Should -Be 1
            $lintStep[0].Status | Should -Be 'fail'
            $lintStep[0].Error | Should -Match 'Refactor'
            $lintStep[0].Error | Should -Match '\.ps1'
        }
        finally {
            Remove-Item -LiteralPath $shellHook -Force -ErrorAction SilentlyContinue
            & git -C $script:fixtureRoot add -A
            & git -C $script:fixtureRoot commit --quiet -m 'Remove shell hook fixture'
        }
    }

    It 'pr-check rejects a dirty worktree before running its tool chain' {
        $dirtyFile = Join-Path $script:fixtureRoot 'uncommitted.txt'
        Set-Content -LiteralPath $dirtyFile -Value 'dirty' -Encoding utf8NoBOM

        try {
            $errorName = ''
            $message = ''
            try {
                $null = Invoke-AvmPrCheck -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
            }
            catch {
                $errorName = $_.Exception.GetType().Name
                $message = $_.Exception.Message
            }

            $errorName | Should -Be 'AvmConfigurationException'
            $message | Should -Match 'clean working tree'
            $message | Should -Match 'uncommitted\.txt'
        }
        finally {
            Remove-Item -LiteralPath $dirtyFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'F59: Invoke-AvmCheckPolicy evaluates both policy bundles against plan JSON' {
        $result = Invoke-AvmCheckPolicy -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback

        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Engine'].Value | Should -Be 'terraform'
        $result.PSObject.Properties['Status'].Value | Should -Be 'pass'
        $result.PSObject.Properties['Tool'].Value | Should -Match '^conftest/'
        $result.PSObject.Properties['ToolSource'].Value | Should -Be 'path'
        $result.PSObject.Properties['ToolPath'].Value | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties['Evaluated'].Value | Should -Be 260
        @($result.PSObject.Properties['Issues'].Value).Count | Should -Be 0
    }

    It 'F59: Invoke-AvmCheckPolicy fails and surfaces a real plan-JSON violation' {
        # Proves the gate can go red end-to-end. Without this the suite only
        # ever proves it does nothing quietly.
        $env:AVM_STUB_CONFTEST_OUTPUT = @'
[{"filename":"main.tf","namespace":"avmsec","successes":259,"failures":[{"msg":"AVM_SEC_1: storage account must disable public network access"}]}]
'@
        try {
            $result = Invoke-AvmCheckPolicy -Path $script:fixtureRoot -Ecosystem terraform -AllowPathFallback
        }
        finally {
            Remove-Item Env:\AVM_STUB_CONFTEST_OUTPUT -ErrorAction SilentlyContinue
        }

        $result.PSObject.Properties['Status'].Value    | Should -Be 'fail'
        $result.PSObject.Properties['Evaluated'].Value | Should -Be 260

        $issues = @($result.PSObject.Properties['Issues'].Value)
        $issues.Count | Should -Be 1
        $issues[0].Severity | Should -Be 'error'
        $issues[0].Code     | Should -Be 'avmsec'
        $issues[0].File     | Should -Be 'examples/foo/tfplan.json'
        $issues[0].Message  | Should -Match 'public network access'
    }
}
