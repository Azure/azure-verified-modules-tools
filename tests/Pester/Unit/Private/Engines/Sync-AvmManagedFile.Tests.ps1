#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Sync-AvmManagedFile' {
    BeforeEach {
        $unique = [Guid]::NewGuid().ToString('N').Substring(0, 8)

        # Managed-files source: a base folder holding root/ (and optionally overlays).
        $script:base = Join-Path $TestDrive ("gov-" + $unique)
        $script:root = Join-Path $script:base 'root'
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null

        # Target module working tree.
        $script:moduleDir = Join-Path $TestDrive ("terraform-azurerm-avm-res-foo-" + $unique)
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }
    }

    It 'rejects a non-terraform context' {
        $bicepCtx = [pscustomobject][ordered]@{
            Kind = 'bicep-module'; Root = $TestDrive; Ecosystem = 'bicep'; Source = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bicepCtx } {
                param($C)
                Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath 'C:\nope'
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'adds missing managed files and returns a local-source envelope' {
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "*.tfstate`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'SECURITY.md') -Value "# Security`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B
        }

        $result.Engine         | Should -Be 'terraform'
        $result.Tool           | Should -Be 'managed-files'
        $result.ToolSource     | Should -Be 'local'
        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 2
        $result.Added          | Should -HaveCount 2
        $result.Updated        | Should -BeNullOrEmpty
        $result.Removed        | Should -BeNullOrEmpty
        $result.Issues         | Should -BeNullOrEmpty

        Test-Path (Join-Path $script:moduleDir '.gitignore') | Should -BeTrue
        Test-Path (Join-Path $script:moduleDir 'SECURITY.md') | Should -BeTrue
    }

    It 'is a no-op on a second run with no changes' {
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "*.tfstate`n" -NoNewline

        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B | Out-Null
        }

        $second = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B
        }

        $second.Status  | Should -Be 'pass'
        $second.Added   | Should -BeNullOrEmpty
        $second.Updated | Should -BeNullOrEmpty
        $second.Removed | Should -BeNullOrEmpty
    }

    It 'updates a stale managed file' {
        $gitignore = Join-Path $script:root '.gitignore'
        Set-Content -LiteralPath $gitignore -Value "*.tfstate`n" -NoNewline

        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B | Out-Null
        }

        # Mutate the source so the on-disk copy is now stale.
        Set-Content -LiteralPath $gitignore -Value "*.tfstate`n.terraform/`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B
        }

        $result.Status  | Should -Be 'pass'
        $result.Added   | Should -BeNullOrEmpty
        $result.Updated | Should -HaveCount 1

        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')
        $onDisk | Should -Match 'terraform'
    }

    It 'reports drift without writing when -CheckDrift is set' {
        $gitignore = Join-Path $script:root '.gitignore'
        Set-Content -LiteralPath $gitignore -Value "*.tfstate`n" -NoNewline

        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B | Out-Null
        }

        # Introduce drift in the source.
        Set-Content -LiteralPath $gitignore -Value "*.tfstate`n.terraform/`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -CheckDrift
        }

        $result.Status       | Should -Be 'fail'
        $result.Updated      | Should -HaveCount 1
        $result.Issues.Count | Should -BeGreaterThan 0

        # Nothing was written: the on-disk copy is still the old content.
        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')
        $onDisk | Should -Not -Match 'terraform'
    }

    It 'applies an overlay and honours exclusions from config.json' {
        $canary = Join-Path $script:base 'canary'
        New-Item -ItemType Directory -Path $canary -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "root-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'common.tf') -Value "# common`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'excludeme.txt') -Value "skip`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $canary '.gitignore') -Value "canary-version`n" -NoNewline

        $cfg = Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $cfg -Force | Out-Null
        $config = @{ repositoryGroups = @(
                @{ name = 'canary'; managedFilesAdditional = 'canary'; repositories = @('avm-res-foo'); excludedManagedFiles = @('excludeme.txt') }
            ) } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath (Join-Path $cfg 'config.json') -Value $config -NoNewline
        Set-Content -LiteralPath (Join-Path $cfg 'deprecated-files.json') -Value '[]' -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -RepoId 'avm-res-foo'
        }

        $result.Status  | Should -Be 'pass'
        $result.Added   | Should -HaveCount 2

        # Overlay wins for .gitignore.
        $gi = (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')).Trim()
        $gi | Should -Be 'canary-version'

        # Excluded file is never synced.
        Test-Path (Join-Path $script:moduleDir 'excludeme.txt') | Should -BeFalse
        # Root-only file still lands.
        Test-Path (Join-Path $script:moduleDir 'common.tf') | Should -BeTrue
    }

    It 'stacks multiple overlays in declaration order, last one winning' {
        $canary = Join-Path $script:base 'canary'
        $tooling = Join-Path $script:base 'canary-tooling'
        New-Item -ItemType Directory -Path $canary -Force | Out-Null
        New-Item -ItemType Directory -Path $tooling -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "root-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'pr-check.yml') -Value "root-check`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'common.tf') -Value "# common`n" -NoNewline

        Set-Content -LiteralPath (Join-Path $canary '.gitignore') -Value "canary-version`n" -NoNewline
        # Placeholder that keeps an otherwise-empty overlay tracked in git.
        Set-Content -LiteralPath (Join-Path $canary '.gitkeep') -Value '' -NoNewline

        Set-Content -LiteralPath (Join-Path $tooling '.gitignore') -Value "tooling-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $tooling 'pr-check.yml') -Value "tooling-check`n" -NoNewline

        $cfg = Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $cfg -Force | Out-Null
        $config = @{ repositoryGroups = @(
                @{ name = 'canary'; managedFilesAdditional = 'canary'; repositories = @('avm-res-foo') }
                @{ name = 'canary-tooling'; managedFilesAdditional = 'canary-tooling'; repositories = @('avm-res-foo') }
            ) } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath (Join-Path $cfg 'config.json') -Value $config -NoNewline
        Set-Content -LiteralPath (Join-Path $cfg 'deprecated-files.json') -Value '[]' -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -RepoId 'avm-res-foo'
        }

        $result.Status | Should -Be 'pass'
        $result.Added  | Should -HaveCount 3

        # Last overlay wins over both the earlier overlay and root.
        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')).Trim() | Should -Be 'tooling-version'
        # An overlay-only override of a root file wins.
        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir 'pr-check.yml')).Trim() | Should -Be 'tooling-check'
        # Root-only file still lands.
        Test-Path (Join-Path $script:moduleDir 'common.tf') | Should -BeTrue
        # '.gitkeep' placeholders are never synced into the target repo.
        Test-Path (Join-Path $script:moduleDir '.gitkeep') | Should -BeFalse
    }

    It 'removes deprecated files listed in deprecated-files.json' {
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "*.tfstate`n" -NoNewline

        $cfg = Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $cfg -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cfg 'config.json') -Value '{ "repositoryGroups": [] }' -NoNewline
        Set-Content -LiteralPath (Join-Path $cfg 'deprecated-files.json') -Value (@('old-thing.txt') | ConvertTo-Json) -NoNewline

        # Pre-seed the deprecated file into the working tree.
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'old-thing.txt') -Value "delete me`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -RepoId 'avm-res-foo'
        }

        $result.Status  | Should -Be 'pass'
        $result.Removed | Should -HaveCount 1

        Test-Path (Join-Path $script:moduleDir 'old-thing.txt') | Should -BeFalse
    }

    It 'returns a clean pass with FilesProcessed=0 when the source root is empty' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B
        }

        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 0
        $result.Added          | Should -BeNullOrEmpty
        $result.Issues         | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-AvmManagedFilesRepositorySetting overlay ordering' {
    BeforeAll {
        # Round-trip through JSON so the shape matches production exactly: the
        # function inspects PSObject.Properties, which behaves differently on a
        # raw hashtable than on the PSCustomObject ConvertFrom-Json produces.
        function script:New-TestConfig {
            param([object[]] $Groups)
            return (@{ repositoryGroups = $Groups } | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
        }

        function script:Resolve-Overlays {
            param([object] $Config, [string] $RepoId)
            $settings = InModuleScope 'Avm.Authoring' -Parameters @{ C = $Config; R = $RepoId } {
                param($C, $R)
                Resolve-AvmManagedFilesRepositorySetting -RepositoryConfig $C -RepoId $R
            }
            return @($settings.ManagedFilesAdditional)
        }
    }

    It 'falls back to declaration order when no managedFilesOrder is set' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'first'; managedFilesAdditional = 'alpha'; repositories = @('repo-x') }
            @{ name = 'second'; managedFilesAdditional = 'beta'; repositories = @('repo-x') }
        )

        script:Resolve-Overlays -Config $config -RepoId 'repo-x' | Should -Be @('alpha', 'beta')
    }

    It 'lets an explicit managedFilesOrder override declaration order' {
        # 'alpha' is declared FIRST but carries a higher order, so it must sort
        # last and therefore win. This is the whole point of the field.
        $config = script:New-TestConfig -Groups @(
            @{ name = 'first'; managedFilesAdditional = 'alpha'; managedFilesOrder = 99; repositories = @('repo-x') }
            @{ name = 'second'; managedFilesAdditional = 'beta'; managedFilesOrder = 1; repositories = @('repo-x') }
        )

        script:Resolve-Overlays -Config $config -RepoId 'repo-x' | Should -Be @('beta', 'alpha')
    }

    It 'treats a missing managedFilesOrder as 0' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'ordered'; managedFilesAdditional = 'alpha'; managedFilesOrder = 5; repositories = @('repo-x') }
            @{ name = 'unordered'; managedFilesAdditional = 'beta'; repositories = @('repo-x') }
        )

        script:Resolve-Overlays -Config $config -RepoId 'repo-x' | Should -Be @('beta', 'alpha')
    }

    It 'breaks ties on declaration order' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'first'; managedFilesAdditional = 'alpha'; managedFilesOrder = 10; repositories = @('repo-x') }
            @{ name = 'second'; managedFilesAdditional = 'beta'; managedFilesOrder = 10; repositories = @('repo-x') }
        )

        script:Resolve-Overlays -Config $config -RepoId 'repo-x' | Should -Be @('alpha', 'beta')
    }

    It 'ignores groups the repository does not belong to' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'other'; managedFilesAdditional = 'alpha'; managedFilesOrder = 1; repositories = @('repo-y') }
            @{ name = 'mine'; managedFilesAdditional = 'beta'; managedFilesOrder = 2; repositories = @('repo-x') }
        )

        script:Resolve-Overlays -Config $config -RepoId 'repo-x' | Should -Be @('beta')
    }

    It 'counts declaration index across groups that declare no overlay' {
        # The middle group contributes no overlay but must still advance the
        # tie-break index, so 'alpha' and 'beta' stay in declaration order.
        $config = script:New-TestConfig -Groups @(
            @{ name = 'first'; managedFilesAdditional = 'alpha'; repositories = @('repo-x') }
            @{ name = 'tier'; repositories = @('repo-x') }
            @{ name = 'third'; managedFilesAdditional = 'beta'; repositories = @('repo-x') }
        )

        script:Resolve-Overlays -Config $config -RepoId 'repo-x' | Should -Be @('alpha', 'beta')
    }

    It 'pins the canary cohort to canary then canary-tooling regardless of declaration order' {
        # Mirrors the real config.json, but with the groups declared in the
        # WRONG order on purpose. managedFilesOrder must still put
        # 'canary-tooling' last so its pr-check.yml / avm shims win.
        $config = script:New-TestConfig -Groups @(
            @{ name = 'canary-tooling'; managedFilesAdditional = 'canary-tooling'; managedFilesOrder = 20; repositories = @('avm-ptn-example-repo') }
            @{ name = 'canary'; managedFilesAdditional = 'canary'; managedFilesOrder = 10; repositories = @('avm-ptn-example-repo') }
            @{ name = 'azure-verified-modules-tier-1'; repositories = @('avm-ptn-example-repo') }
        )

        script:Resolve-Overlays -Config $config -RepoId 'avm-ptn-example-repo' |
            Should -Be @('canary', 'canary-tooling')
    }
}
