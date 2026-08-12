#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Integration: managed-files semver discovery against the real tag list on
# github.com, plus the on-disk pin round-trip.
#
# The version gate is network-bound by construction: Get-AvmLatestManagedFilesVersion
# shells out to `git ls-remote --tags https://github.com/<repo>.git`. That URL is
# built in the module, so a Component-tier test cannot substitute a local
# fixture repository - only the Integration tier can prove the regex, the semver
# sort and the peeled-tag filtering survive contact with the real tag list.
#
# Tagged 'Integration' so it stays out of the Unit and Component runs, and
# honours AVM_OFFLINE so an offline build is never blocked.

Describe 'Integration: managed-files version pin against the real repository' -Tag 'Integration' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module $script:moduleManifest -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    # Pester 5 evaluates -Skip: at discovery time, before BeforeAll runs, so the
    # offline probe has to be inline rather than a script variable.
    It 'discovers the newest release tag through git ls-remote' -Skip:((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1')) {
        $latest = InModuleScope 'Avm.Authoring' {
            $git = (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
                    Select-Object -First 1).Source
            if (-not $git) { throw 'git is required for the managed-files version integration test.' }
            Get-AvmLatestManagedFilesVersion `
                -Repo 'Azure/azure-verified-modules-managed-files' `
                -GitPath $git `
                -Refresh
        }

        $latest | Should -Not -BeNullOrEmpty
        $latest | Should -BeOfType ([semver])
        $latest | Should -BeGreaterOrEqual ([semver]'0.1.0')
    }

    It 'resolves an unpinned repository onto the newest tag and asks for a stamp' -Skip:((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1')) {
        $plan = InModuleScope 'Avm.Authoring' {
            $git = (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
                    Select-Object -First 1).Source
            if (-not $git) { throw 'git is required for the managed-files version integration test.' }
            Resolve-AvmManagedFilesVersionPlan `
                -Settings @{
                    ManagedFilesRepo      = 'Azure/azure-verified-modules-managed-files'
                    ManagedFilesRef       = 'main'
                    ManagedFilesRefSource = 'default'
                } `
                -GitPath $git
        }

        $plan.Status        | Should -Be 'unpinned'
        $plan.LatestVersion | Should -Not -BeNullOrEmpty
        $plan.ShouldStamp   | Should -BeTrue
        $plan.Ref           | Should -Be ("v{0}" -f $plan.LatestVersion)
        $plan.TargetVersion | Should -Be $plan.LatestVersion
    }

    It 'flags a superseded major without throwing so the caller decides the severity' -Skip:((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1')) {
        $plan = InModuleScope 'Avm.Authoring' {
            $git = (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
                    Select-Object -First 1).Source
            if (-not $git) { throw 'git is required for the managed-files version integration test.' }
            # 0.0.1 is guaranteed to be behind every published tag, so this
            # exercises the behind-branch without depending on a specific release.
            Resolve-AvmManagedFilesVersionPlan `
                -Settings @{
                    ManagedFilesRepo       = 'Azure/azure-verified-modules-managed-files'
                    ManagedFilesRef        = 'main'
                    ManagedFilesRefSource  = 'default'
                    ManagedFilesVersionPin = [pscustomobject]@{ Version = [semver]'0.0.1' }
                } `
                -GitPath $git
        }

        $plan.Status      | Should -BeIn @('major', 'minor', 'patch')
        $plan.Ref         | Should -Be 'v0.0.1'
        $plan.ShouldStamp | Should -BeFalse
        $plan.Message     | Should -Not -BeNullOrEmpty
    }

    It 'round-trips a pin file on disk as LF-terminated UTF-8 without a BOM' {
        $root = Join-Path $TestDrive ('pin-roundtrip-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $root -Force

        $written = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Set-AvmManagedFilesVersionPin `
                -Root $R `
                -Version ([semver]'1.2.3') `
                -Repo 'Azure/azure-verified-modules-managed-files' `
                -Commit '3f949ae3da0ead8bdb85d405659c9991a976b231' `
                -CommitDate '2026-08-11T21:52:43Z'
        }

        $written.Version | Should -Be ([semver]'1.2.3')

        $path = Join-Path (Join-Path $root '.avm') 'managed-files-version.json'
        Test-Path -LiteralPath $path | Should -BeTrue

        $bytes = [System.IO.File]::ReadAllBytes($path)
        # A BOM here would break every downstream JSON reader that assumes UTF-8.
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
        $raw | Should -Not -Match "`r"
        $raw.EndsWith("`n") | Should -BeTrue

        $read = InModuleScope 'Avm.Authoring' -Parameters @{ R = $root } {
            param($R)
            Get-AvmManagedFilesVersionPin -Root $R
        }

        $read.Version    | Should -Be ([semver]'1.2.3')
        $read.Repo       | Should -Be 'Azure/azure-verified-modules-managed-files'
        $read.Commit     | Should -Be '3f949ae3da0ead8bdb85d405659c9991a976b231'
        # ConvertFrom-Json coerces ISO 8601 strings to [datetime]; the reader has
        # to re-render them or a local-culture round-trip silently corrupts them.
        $read.CommitDate | Should -Be '2026-08-11T21:52:43Z'
        $read.UpdatedAt  | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }
}
