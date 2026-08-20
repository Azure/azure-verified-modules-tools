#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Integration: run the REAL Terraform pre-commit and pr-check chains, end to end,
# against the on-disk fixture modules using the actual pinned binaries
# (terraform, terraform-docs, tflint, conftest, mapotf) downloaded into an
# isolated AVM_HOME. This is the integration-grade proof that the wired
# Terraform engines compose correctly with real tools - not the stub
# launchers the Component tier uses.
#
# Tagged 'Integration' so the `integration` build task picks it up and so it stays out of
# the Unit / Component / pre-commit runs (it needs REAL NETWORK to download
# tools + Terraform providers).
#
# Skips cleanly (never fails red) when:
#   - $env:AVM_OFFLINE -eq '1' (no network to download tools/providers).
#   - mapotf is blocked by host antivirus. Windows Defender intermittently
#     flags the mapotf Go binary as a false positive ("virus or potentially
#     unwanted software") and quarantines it at exec time. On an un-elevated
#     dev box we cannot add a Defender exclusion, so the chain's `transform`
#     step would error. We detect that exact condition and Skip. The CI
#     workflow adds `Add-MpPreference -ExclusionPath` on its Windows leg so CI
#     gets a real pass instead of a skip.
#
# When AVM_HOME is not supplied, Windows state lives under
# %LOCALAPPDATA%\Avm\IntegrationTests rather than %TEMP% to reduce Defender ML
# false positives against unsigned mapotf; Linux and macOS continue using temp.
#
# The integration workflow provides Azure OIDC credentials because pr-check
# policy evaluation now creates a plan for every runnable example.

Describe 'Integration: real-binary Terraform chains' -Tag 'Integration' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $script:Manifest = Join-Path $script:RepoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module $script:Manifest -Force

        # Compare two on-disk trees and return a list of human-readable differences
        # (added / removed / modified relative paths). Text content is compared with
        # line endings normalised to LF so a tool that emits CRLF on a Windows runner
        # is not reported as drift - the repo standard is LF and `.gitattributes`
        # enforces it on the committed fixture. An empty result means the trees are
        # identical for our purposes.
        #
        # Defined here in BeforeAll (not at file scope) so it lives in the run-phase
        # scope where the `It` blocks execute. A file-scope `function` only exists
        # during Pester's discovery phase and is NOT visible inside `It`, which would
        # raise CommandNotFoundException at the drift assertion below.
        function Get-AvmIntegrationTreeDiff {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)] [string] $Reference,
                [Parameter(Mandatory)] [string] $Difference
            )

            $relativeFiles = {
                param([string] $Root)
                Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
                    ForEach-Object {
                        $_.FullName.Substring($Root.Length).TrimStart([char]'\', [char]'/').Replace('\', '/')
                    }
            }

            $refFiles = @(& $relativeFiles $Reference)
            $diffFiles = @(& $relativeFiles $Difference)

            $changes = [System.Collections.Generic.List[string]]::new()

            foreach ($rel in ($refFiles | Where-Object { $_ -notin $diffFiles })) {
                $changes.Add("removed: $rel")
            }
            foreach ($rel in ($diffFiles | Where-Object { $_ -notin $refFiles })) {
                $changes.Add("added: $rel")
            }
            foreach ($rel in ($refFiles | Where-Object { $_ -in $diffFiles })) {
                $a = ([System.IO.File]::ReadAllText((Join-Path $Reference $rel))) -replace "`r`n", "`n" -replace "`r", "`n"
                $b = ([System.IO.File]::ReadAllText((Join-Path $Difference $rel))) -replace "`r`n", "`n" -replace "`r", "`n"
                if ($a -ne $b) { $changes.Add("modified: $rel") }
            }

            return $changes
        }

        # Preserve ambient env so we can restore it in AfterAll.
        $script:OrigAvmHome = $env:AVM_HOME
        $script:OrigPluginCache = $env:TF_PLUGIN_CACHE_DIR
        $script:OrigManagedFilesLocal = $env:AVM_MANAGED_FILES_LOCAL_PATH
        $pinsPath = Join-Path $script:RepoRoot 'src' 'Avm.Authoring' 'Resources' 'avm.pins.jsonc'
        $pins = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json
        $script:RequiresV020RulesetRelease = (
            [version]$pins.tflintPlugins.avm -lt [version]'0.20.0'
        )

        $script:Offline = ((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1'))
        $script:SkipReason = $null

        $runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:RunRoot = if ($IsWindows) {
            Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Avm' 'IntegrationTests' $runId
        }
        else {
            Join-Path ([IO.Path]::GetTempPath()) "avm-integration-$runId"
        }

        # Respect an externally-provided AVM_HOME: the CI workflow sets it to a
        # known path so it can add a Defender exclusion to that exact directory
        # BEFORE this test installs tools into it. Otherwise own the run home.
        if ($env:AVM_HOME) {
            $script:AvmHome = $env:AVM_HOME
            $script:OwnsHome = $false
        }
        else {
            $script:AvmHome = Join-Path $script:RunRoot 'home'
            $env:AVM_HOME = $script:AvmHome
            $script:OwnsHome = $true
        }
        $null = New-Item -ItemType Directory -Path $script:AvmHome -Force

        # Shared provider cache so the two fixtures' `terraform init` reuse
        # downloads. Honour an externally-set value (CI).
        if (-not $env:TF_PLUGIN_CACHE_DIR) {
            $env:TF_PLUGIN_CACHE_DIR = Join-Path $script:AvmHome 'tf-plugin-cache'
            $script:OwnsPluginCache = $true
        }
        else {
            $script:OwnsPluginCache = $false
        }
        $null = New-Item -ItemType Directory -Path $env:TF_PLUGIN_CACHE_DIR -Force

        # Writable staging area for fixture copies (transform/format/docs mutate
        # files in place, so we never touch the checked-in fixtures).
        $script:WorkRoot = Join-Path $script:RunRoot 'work'
        $null = New-Item -ItemType Directory -Path $script:WorkRoot -Force

        if ($script:Offline) {
            $script:SkipReason = 'AVM_OFFLINE=1 - real-binary integration needs network to download tools and providers.'
        }
        else {
            # Best-effort: exclude the tools dir from Windows Defender so the
            # mapotf Go binary is not quarantined as a false positive. Silently
            # ignored when not elevated (local dev) - the mapotf probe below
            # then trips the graceful skip instead. CI runs this as the elevated
            # runner user so the exclusion actually takes.
            if ($IsWindows) {
                try { Add-MpPreference -ExclusionPath $script:AvmHome -ErrorAction Stop } catch { }
                try { Add-MpPreference -ExclusionProcess 'mapotf.exe' -ErrorAction Stop } catch { }
            }

            try {
                Install-AvmTool -Name terraform, terraform-docs, tflint, conftest, mapotf -InformationAction Continue -ErrorAction Stop
            }
            catch {
                $script:SkipReason = if ($_.Exception.Message -match 'virus|potentially unwanted') {
                    'mapotf blocked by host antivirus at install (Defender false positive); CI excludes the tools dir.'
                }
                else {
                    "Tool install failed: $($_.Exception.Message)"
                }
            }
        }

        # Probe mapotf by actually executing it the same way the transform
        # engine does (Resolve-AvmTool + Invoke-AvmProcess, both private, hence
        # InModuleScope). On an un-elevated Windows dev box Defender quarantines
        # the binary and the exec throws 'virus or potentially unwanted'; detect
        # that exact condition and convert it into a clean skip rather than
        # letting the chain's transform step error out red.
        if (-not $script:SkipReason) {
            $probe = InModuleScope 'Avm.Authoring' {
                try {
                    $tool = Resolve-AvmTool -Name 'mapotf'
                    $r = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('--help') -IgnoreExitCode
                    [pscustomobject]@{ Ok = $true; Text = "$($r.StdOut) $($r.StdErr)" }
                }
                catch {
                    [pscustomobject]@{ Ok = $false; Text = $_.Exception.Message }
                }
            }
            if (-not $probe.Ok) {
                $script:SkipReason = if ($probe.Text -match 'virus|potentially unwanted') {
                    'mapotf blocked by host antivirus (Defender false positive); CI excludes the tools dir.'
                }
                else {
                    "mapotf probe failed: $($probe.Text)"
                }
            }
        }
    }

    AfterAll {
        if ($script:RunRoot -and (Test-Path -LiteralPath $script:RunRoot)) {
            Remove-Item -LiteralPath $script:RunRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Restore ambient env.
        if ($null -eq $script:OrigAvmHome) { Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue }
        else { $env:AVM_HOME = $script:OrigAvmHome }
        if ($null -eq $script:OrigPluginCache) { Remove-Item Env:\TF_PLUGIN_CACHE_DIR -ErrorAction SilentlyContinue }
        else { $env:TF_PLUGIN_CACHE_DIR = $script:OrigPluginCache }
        if ($null -eq $script:OrigManagedFilesLocal) { Remove-Item Env:\AVM_MANAGED_FILES_LOCAL_PATH -ErrorAction SilentlyContinue }
        else { $env:AVM_MANAGED_FILES_LOCAL_PATH = $script:OrigManagedFilesLocal }

        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    # One Context per test module. The set is filtered by $env:AVM_INTEGRATION_FIXTURE
    # so a CI matrix leg can target a single module (one job per fixture x OS)
    # while a local `./build.ps1 integration` with the var unset still covers both in
    # one process.
    Context 'fixture <name>' -ForEach (@(
            @{ Name = 'terraform-azure-avm-res-mock' }
            @{ Name = 'terraform-azurerm-avm-res-mock' }
        ) | Where-Object { (-not $env:AVM_INTEGRATION_FIXTURE) -or ($_.Name -eq $env:AVM_INTEGRATION_FIXTURE) }) {
        BeforeAll {
            # Stage a fresh writable copy of this fixture. Guarded by SkipReason
            # so we do not waste a copy when the suite is going to skip.
            $script:OriginalModule = Join-Path $script:RepoRoot 'tests' 'fixtures' 'modules' $name
            $script:StagedModule = $null
            if (-not $script:SkipReason) {
                $dest = Join-Path $script:WorkRoot $name
                Copy-Item -LiteralPath $script:OriginalModule -Destination $dest -Recurse -Force
                $script:StagedModule = $dest

                # Both chains run `sync` first. Point it at a local governance
                # source seeded from this fixture so the chain never reaches the
                # network and the module is already in sync (no drift).
                $managedRoot = Join-Path (Join-Path $script:WorkRoot "$name-managed-files") 'root'
                $null = New-Item -ItemType Directory -Path $managedRoot -Force
                Copy-Item -LiteralPath (Join-Path $script:OriginalModule '.gitignore') -Destination $managedRoot -Force
                $env:AVM_MANAGED_FILES_LOCAL_PATH = Split-Path -Parent $managedRoot
            }
        }

        # NOTE: declaration order matters. pre-commit runs first and must leave
        # the (already canonical) module byte-identical; the diff assertion below
        # fails the build on any drift. pr-check then runs on the same unchanged
        # copy, so its drift-checking transform step also stays clean. This
        # mirrors the real contributor flow: run pre-commit, commit the result,
        # CI runs pr-check on the committed tree.
        It 'pre-commit passes every step and leaves the module unchanged (no drift)' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }

            $result = Invoke-AvmPreCommit -Path $script:StagedModule -Ecosystem terraform

            foreach ($step in $result.Steps) {
                $step.Status | Should -Be 'pass' -Because "pre-commit step '$($step.Step)' should pass (error: $($step.Error))"
            }
            ($result.Steps.Step -join ',') | Should -BeExactly 'sync,check convention,transform,format,docs'
            $result.Status | Should -Be 'pass'

            # Fail the build if pre-commit changed anything: a canonical module
            # (synced from legacy Terraform governance) must survive pre-commit
            # untouched. Any add/remove/modify is real drift worth a red build.
            $drift = @(Get-AvmIntegrationTreeDiff -Reference $script:OriginalModule -Difference $script:StagedModule)
            $drift.Count | Should -Be 0 -Because "pre-commit must be a no-op on a canonical module; drift:`n$($drift -join "`n")"
        }

        It 'pr-check runs every step, evaluates plan policies, and resolves tools from the AVM cache' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            if ($script:RequiresV020RulesetRelease) {
                Set-ItResult -Skipped -Because (
                    'pr-check invokes real TFLint; wait for the attested v0.20.0 AVM ruleset release before ' +
                    'validating the renamed packaged rules.')
                return
            }

            $policyViolation = Join-Path $script:StagedModule 'examples' 'second_example' 'policy-violation.tf'
            if (Test-Path -LiteralPath $policyViolation -PathType Leaf) {
                $compliantPolicyFixture = (Get-Content -LiteralPath $policyViolation -Raw).
                    Replace('isAutoInflateEnabled = false', 'isAutoInflateEnabled = true').
                    Replace('minimumTlsVersion    = "1.0"', 'minimumTlsVersion    = "1.2"').
                    Replace('zoneRedundant        = false', 'zoneRedundant        = true')
                Set-Content -LiteralPath $policyViolation -Value $compliantPolicyFixture -Encoding utf8NoBOM -NoNewline
            }

            & git -C $script:StagedModule init --quiet
            if ($LASTEXITCODE -ne 0) { throw "git init failed with exit code $LASTEXITCODE." }
            & git -C $script:StagedModule config user.name 'AVM Integration Tests'
            if ($LASTEXITCODE -ne 0) { throw "git config user.name failed with exit code $LASTEXITCODE." }
            & git -C $script:StagedModule config user.email 'avm-integration-tests@example.invalid'
            if ($LASTEXITCODE -ne 0) { throw "git config user.email failed with exit code $LASTEXITCODE." }
            & git -C $script:StagedModule add -A
            if ($LASTEXITCODE -ne 0) { throw "git add failed with exit code $LASTEXITCODE." }
            & git -C $script:StagedModule commit --quiet -m 'Initial fixture'
            if ($LASTEXITCODE -ne 0) { throw "git commit failed with exit code $LASTEXITCODE." }

            $result = Invoke-AvmPrCheck -Path $script:StagedModule -Ecosystem terraform

            # F59: genuine Terraform and Conftest must complete plan-JSON policy
            # evaluation. Pin both the status and a positive evaluation count so
            # an empty/vacuous result cannot satisfy the test.
            $policyStep = $result.Steps | Where-Object { $_.Step -eq 'check policy' }
            $policyStep | Should -Not -BeNullOrEmpty
            $policyStep.Status | Should -Be 'pass'
            $policyStep.Result.Evaluated | Should -BeGreaterThan 0
            @($policyStep.Result.Issues).Count | Should -Be 0

            foreach ($step in $result.Steps | Where-Object { $_.Step -ne 'check policy' }) {
                $step.Status | Should -Be 'pass' -Because "pr-check step '$($step.Step)' should pass (error: $($step.Error))"
            }
            ($result.Steps.Step -join ',') | Should -BeExactly 'sync,format,transform,lint,check policy,check convention,validate,docs'
            $result.Status | Should -Be 'pass'

            # F07: no verb may create a repo-local .avm/ folder. Persistent state
            # belongs under $AVM_HOME.
            (Test-Path -LiteralPath (Join-Path $script:StagedModule '.avm')) |
                Should -BeFalse -Because 'pr-check must never create a repo-local .avm/ folder'

            # Every managed-tool step must resolve its binary from the AVM
            # cache we just populated (not a stray PATH binary).
            $toolSteps = $result.Steps | Where-Object {
                ($_.Step -in @('format', 'transform', 'lint', 'validate', 'docs')) -and
                $_.Result -and ($_.Result.PSObject.Properties.Name -contains 'ToolSource')
            }
            $toolSteps.Count | Should -BeGreaterThan 0
            foreach ($step in $toolSteps) {
                $step.Result.ToolSource | Should -Be 'cache' -Because "pr-check step '$($step.Step)' should use the managed cache"
            }
        }

        It 'keeps a real policy exception scoped to its own example' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            if ($name -ne 'terraform-azure-avm-res-mock') {
                Set-ItResult -Skipped -Because 'only the Azure fixture carries the adversarial policy isolation case'
                return
            }

            $policyModule = Join-Path $script:WorkRoot "$name-policy-isolation"
            Copy-Item -LiteralPath $script:OriginalModule -Destination $policyModule -Recurse -Force

            $unscoped = Invoke-AvmCheckPolicy -Path $policyModule -Ecosystem terraform
            $unscoped.Status | Should -Be 'fail'
            $unscoped.Evaluated | Should -BeGreaterThan 0

            $tlsIssues = @($unscoped.Issues | Where-Object {
                    $_.File -eq 'examples/second_example/tfplan.json' -and
                    $_.Code -eq 'avmsec' -and
                    $_.Message -match 'AVM_SEC_223'
                })
            $tlsIssues.Count | Should -BeGreaterThan 0 -Because 'the default example exception must not leak into second_example'

            $secondExceptions = Join-Path $policyModule 'examples' 'second_example' 'exceptions'
            $null = New-Item -ItemType Directory -Path $secondExceptions -Force
            Copy-Item -LiteralPath (Join-Path $policyModule 'examples' 'default' 'exceptions' 'avmsec.rego') `
                -Destination (Join-Path $secondExceptions 'avmsec.rego') -Force

            $scoped = Invoke-AvmCheckPolicy -Path $policyModule -Ecosystem terraform
            $scoped.Evaluated | Should -BeGreaterThan 0
            @($scoped.Issues | Where-Object {
                    $_.File -eq 'examples/second_example/tfplan.json' -and
                    $_.Code -eq 'avmsec' -and
                    $_.Message -match 'AVM_SEC_223'
                }).Count | Should -Be 0 -Because 'the exception must suppress AVM_SEC_223 when it belongs to second_example'
        }

        # F34: terraform init only scans the *default* test directory when
        # resolving modules declared inside .tftest.hcl run blocks. AVM tiers
        # live in tests/<tier>/, so without '-test-directory' on init the
        # helper module is never installed and terraform test dies with
        # 'Module not installed'. Runs from a cold copy (no .terraform/) so it
        # is a genuine guard rather than a beneficiary of an earlier init.
        It 'unit tier installs modules referenced by run blocks from a cold working directory' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
            if ($name -ne 'terraform-azurerm-avm-res-mock') {
                Set-ItResult -Skipped -Because 'only the azurerm fixture carries a run-block helper module'
                return
            }

            $cold = Join-Path $script:WorkRoot "$name-f34"
            Copy-Item -LiteralPath $script:OriginalModule -Destination $cold -Recurse -Force
            (Test-Path -LiteralPath (Join-Path $cold '.terraform')) |
                Should -BeFalse -Because 'the guard is only meaningful from a cold working directory'

            $result = Invoke-AvmTestUnit -Path $cold -Ecosystem terraform

            $result.Status | Should -Be 'pass' -Because "issues: $($result.Issues | ConvertTo-Json -Depth 4 -Compress)"
            $result.RunsTotal | Should -BeGreaterOrEqual 2
            $result.RunsFailed | Should -Be 0

            $modules = Join-Path $cold '.terraform' 'modules' 'modules.json'
            (Test-Path -LiteralPath $modules) | Should -BeTrue
            (Get-Content -LiteralPath $modules -Raw) |
                Should -Match 'tests/unit/setup' -Because 'init must record the run-block helper module'
        }
    }
}
