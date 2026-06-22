#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Smoke: run the REAL Terraform pre-commit and pr-check chains, end to end,
# against the on-disk fixture modules using the actual pinned binaries
# (terraform, terraform-docs, tflint, conftest, mapotf) downloaded into an
# isolated AVM_HOME. This is the integration-grade proof that the wired
# Terraform engines compose correctly with real tools - not the stub
# launchers the Integration tier uses.
#
# Tagged 'Smoke' so the `smoke` build task picks it up and so it stays out of
# the Unit / Integration / pre-commit runs (it needs REAL NETWORK to download
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
# No Azure credentials are required: the `test` step runs only
# `terraform init -backend=false` + `terraform validate -json` (no plan /
# apply), so even the azurerm fixture validates offline.

Describe 'Smoke: real-binary Terraform chains' -Tag 'Smoke' {

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
        function Get-AvmSmokeTreeDiff {
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

        $script:Offline = ((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1'))
        $script:SkipReason = $null

        # Respect an externally-provided AVM_HOME: the CI workflow sets it to a
        # known path so it can add a Defender exclusion to that exact directory
        # BEFORE this test installs tools into it. Otherwise own a temp dir.
        if ($env:AVM_HOME) {
            $script:AvmHome = $env:AVM_HOME
            $script:OwnsHome = $false
        }
        else {
            $script:AvmHome = Join-Path ([IO.Path]::GetTempPath()) ('avm-smoke-home-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
        $script:WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('avm-smoke-work-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $script:WorkRoot -Force

        if ($script:Offline) {
            $script:SkipReason = 'AVM_OFFLINE=1 - real-binary smoke needs network to download tools and providers.'
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
        if ($script:WorkRoot -and (Test-Path -LiteralPath $script:WorkRoot)) {
            Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:OwnsHome -and $script:AvmHome -and (Test-Path -LiteralPath $script:AvmHome)) {
            Remove-Item -LiteralPath $script:AvmHome -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Restore ambient env.
        if ($null -eq $script:OrigAvmHome) { Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue }
        else { $env:AVM_HOME = $script:OrigAvmHome }
        if ($null -eq $script:OrigPluginCache) { Remove-Item Env:\TF_PLUGIN_CACHE_DIR -ErrorAction SilentlyContinue }
        else { $env:TF_PLUGIN_CACHE_DIR = $script:OrigPluginCache }

        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    # One Context per test module. The set is filtered by $env:AVM_SMOKE_FIXTURE
    # so a CI matrix leg can target a single module (one job per fixture x OS)
    # while a local `./build.ps1 smoke` with the var unset still covers both in
    # one process.
    Context 'fixture <name>' -ForEach (@(
            @{ Name = 'terraform-azure-avm-res-mock' }
            @{ Name = 'terraform-azurerm-avm-res-mock' }
        ) | Where-Object { (-not $env:AVM_SMOKE_FIXTURE) -or ($_.Name -eq $env:AVM_SMOKE_FIXTURE) }) {
        BeforeAll {
            # Stage a fresh writable copy of this fixture. Guarded by SkipReason
            # so we do not waste a copy when the suite is going to skip.
            $script:OriginalModule = Join-Path $script:RepoRoot 'tests' 'fixtures' 'modules' $name
            $script:StagedModule = $null
            if (-not $script:SkipReason) {
                $dest = Join-Path $script:WorkRoot $name
                Copy-Item -LiteralPath $script:OriginalModule -Destination $dest -Recurse -Force
                $script:StagedModule = $dest
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

            Write-Host '----- DIAG: pre-commit steps -----'
            foreach ($s in $result.Steps) {
                Write-Host ("DIAG step={0} status={1} error={2}" -f $s.Step, $s.Status, $s.Error)
            }
            Write-Host '----- END DIAG -----'

            ($result.Steps.Step -join ',') | Should -BeExactly 'check convention,transform,format,docs'
            foreach ($step in $result.Steps) {
                $step.Status | Should -Be 'pass' -Because "pre-commit step '$($step.Step)' should pass (error: $($step.Error))"
            }
            $result.Status | Should -Be 'pass'

            # Fail the build if pre-commit changed anything: a canonical module
            # (synced from avm-terraform-governance) must survive pre-commit
            # untouched. Any add/remove/modify is real drift worth a red build.
            $drift = @(Get-AvmSmokeTreeDiff -Reference $script:OriginalModule -Difference $script:StagedModule)
            $drift.Count | Should -Be 0 -Because "pre-commit must be a no-op on a canonical module; drift:`n$($drift -join "`n")"
        }

        It 'pr-check reports pass with check policy skipped, and resolves tools from the AVM cache' {
            if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }

            $result = Invoke-AvmPrCheck -Path $script:StagedModule -Ecosystem terraform

            ($result.Steps.Step -join ',') | Should -BeExactly 'format,transform,lint,check policy,check convention,test,docs'

            foreach ($step in $result.Steps) {
                if ($step.Step -eq 'check policy') {
                    # No APRL/AVMSEC bundles declared in the fixture -> skipped by design.
                    $step.Status | Should -Be 'skipped' -Because 'check policy has no pinned bundles in the fixture'
                }
                else {
                    $step.Status | Should -Be 'pass' -Because "pr-check step '$($step.Step)' should pass (error: $($step.Error))"
                }
            }
            $result.Status | Should -Be 'pass'

            # Every managed-tool step must resolve its binary from the AVM
            # cache we just populated (not a stray PATH binary).
            $toolSteps = $result.Steps | Where-Object {
                ($_.Step -in @('format', 'transform', 'lint', 'test', 'docs')) -and
                $_.Result -and ($_.Result.PSObject.Properties.Name -contains 'ToolSource')
            }
            $toolSteps.Count | Should -BeGreaterThan 0
            foreach ($step in $toolSteps) {
                $step.Result.ToolSource | Should -Be 'cache' -Because "pr-check step '$($step.Step)' should use the managed cache"
            }
        }
    }
}
