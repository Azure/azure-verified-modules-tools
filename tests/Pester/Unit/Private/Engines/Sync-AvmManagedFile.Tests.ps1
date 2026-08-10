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

    It 'creates a line-managed file when it is missing and classifies it as Added' {
        $spec = '{ ".gitignore": { "required": ["*.tfstate", ".terraform/"], "removed": [] } }'
        Set-Content -LiteralPath (Join-Path $script:root '.avm-managed-lines.json') -Value $spec -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B
        }

        $result.Status | Should -Be 'pass'
        $result.Added  | Should -Contain '.gitignore'

        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')
        $onDisk | Should -Match '\*\.tfstate'
        $onDisk | Should -Match '\.terraform/'
        # The spec sentinel is tooling metadata and must never be synced.
        Test-Path (Join-Path $script:moduleDir '.avm-managed-lines.json') | Should -BeFalse
    }

    It 'merges required lines into an existing file, preserving the user additions' {
        $spec = '{ ".gitignore": { "required": ["*.tfstate"], "removed": [] } }'
        Set-Content -LiteralPath (Join-Path $script:root '.avm-managed-lines.json') -Value $spec -NoNewline

        # The consumer already has a hand-authored entry that must survive.
        Set-Content -LiteralPath (Join-Path $script:moduleDir '.gitignore') -Value "my-custom-secret.txt`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B
        }

        $result.Status  | Should -Be 'pass'
        $result.Updated | Should -Contain '.gitignore'
        $result.Added   | Should -Not -Contain '.gitignore'

        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')
        $onDisk | Should -Match 'my-custom-secret\.txt'
        $onDisk | Should -Match '\*\.tfstate'
    }

    It 'removes a deprecated line while preserving the rest' {
        $spec = '{ ".gitignore": { "required": [], "removed": ["obsolete-entry"] } }'
        Set-Content -LiteralPath (Join-Path $script:root '.avm-managed-lines.json') -Value $spec -NoNewline

        Set-Content -LiteralPath (Join-Path $script:moduleDir '.gitignore') -Value "keep-me`nobsolete-entry`nkeep-me-too`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B
        }

        $result.Status  | Should -Be 'pass'
        $result.Updated | Should -Contain '.gitignore'

        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')
        $onDisk | Should -Match 'keep-me'
        $onDisk | Should -Match 'keep-me-too'
        $onDisk | Should -Not -Match 'obsolete-entry'
    }

    It 'reports drift for a line-managed file under -CheckDrift and writes nothing' {
        $spec = '{ ".gitignore": { "required": [".terraform/"], "removed": [] } }'
        Set-Content -LiteralPath (Join-Path $script:root '.avm-managed-lines.json') -Value $spec -NoNewline

        Set-Content -LiteralPath (Join-Path $script:moduleDir '.gitignore') -Value "existing`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -CheckDrift
        }

        $result.Status       | Should -Be 'fail'
        $result.Issues.Count | Should -BeGreaterThan 0

        # Nothing was written: the missing required line is still absent.
        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')
        $onDisk | Should -Not -Match '\.terraform/'
    }

    It 'lets a line spec take over a path that also exists as a whole-file managed file' {
        # Root ships .gitignore as a whole file, but the line spec claims the same
        # path: the line merge must win so the consumer keeps its own additions.
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "whole-file-version`n" -NoNewline
        $spec = '{ ".gitignore": { "required": ["line-managed-entry"], "removed": [] } }'
        Set-Content -LiteralPath (Join-Path $script:root '.avm-managed-lines.json') -Value $spec -NoNewline

        Set-Content -LiteralPath (Join-Path $script:moduleDir '.gitignore') -Value "user-line`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B
        }

        $result.Status | Should -Be 'pass'

        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')
        $onDisk | Should -Match 'user-line'
        $onDisk | Should -Match 'line-managed-entry'
        $onDisk | Should -Not -Match 'whole-file-version'
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

    It 'returns no overlays when the repository belongs to no group' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'other'; managedFilesAdditional = 'alpha'; repositories = @('repo-y') }
        )

        script:Resolve-Overlays -Config $config -RepoId 'repo-x' | Should -HaveCount 0
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

Describe 'Managed-file repository id resolution (helpers)' {
    It 'normalises repository names by stripping the terraform provider prefix (F11)' {
        InModuleScope 'Avm.Authoring' {
            ConvertTo-AvmManagedFilesRepoId 'terraform-azurerm-avm-res-foo' | Should -Be 'avm-res-foo'
            ConvertTo-AvmManagedFilesRepoId 'terraform-azapi-avm-res-bar'   | Should -Be 'avm-res-bar'
            ConvertTo-AvmManagedFilesRepoId 'avm-ptn-example-repo'          | Should -Be 'avm-ptn-example-repo'
            ConvertTo-AvmManagedFilesRepoId '  terraform-azurerm-avm-x  '   | Should -Be 'avm-x'
            ConvertTo-AvmManagedFilesRepoId ''                              | Should -Be ''
            ConvertTo-AvmManagedFilesRepoId $null                           | Should -Be ''
        }
    }

    It 'extracts the repository leaf from every remote URL shape (F11)' {
        InModuleScope 'Avm.Authoring' {
            Get-AvmRepoLeafFromUrl 'https://github.com/Azure/terraform-azurerm-avm-res-foo'       | Should -Be 'terraform-azurerm-avm-res-foo'
            Get-AvmRepoLeafFromUrl 'https://github.com/Azure/terraform-azurerm-avm-res-foo.git'   | Should -Be 'terraform-azurerm-avm-res-foo'
            Get-AvmRepoLeafFromUrl 'git@github.com:Azure/terraform-azurerm-avm-res-foo.git'       | Should -Be 'terraform-azurerm-avm-res-foo'
            Get-AvmRepoLeafFromUrl 'ssh://git@github.com/Azure/terraform-azurerm-avm-res-foo.git' | Should -Be 'terraform-azurerm-avm-res-foo'
            Get-AvmRepoLeafFromUrl 'https://github.com/Azure/terraform-azurerm-avm-res-foo/'      | Should -Be 'terraform-azurerm-avm-res-foo'
            Get-AvmRepoLeafFromUrl ''                                                             | Should -Be ''
        }
    }

    It 'collects and de-duplicates repository ids across governance groups (F11)' {
        InModuleScope 'Avm.Authoring' {
            $cfg = '{ "repositoryGroups": [
                { "name": "a", "repositories": ["repo-x", "repo-y"] },
                { "name": "b", "repositories": ["repo-y", "repo-z"] },
                { "name": "c" }
            ] }' | ConvertFrom-Json
            $ids = Get-AvmManagedFilesKnownRepoId -RepositoryConfig $cfg
            $ids | Should -Contain 'repo-x'
            $ids | Should -Contain 'repo-z'
            @($ids | Where-Object { $_ -eq 'repo-y' }).Count | Should -Be 1
        }
    }

    It 'returns an empty set for a null or group-less config (F11)' {
        InModuleScope 'Avm.Authoring' {
            @(Get-AvmManagedFilesKnownRepoId -RepositoryConfig $null).Count | Should -Be 0
            @(Get-AvmManagedFilesKnownRepoId -RepositoryConfig ([pscustomobject]@{ other = 1 })).Count | Should -Be 0
        }
    }

    It 'returns an explicit id verbatim and never inspects the origin (F11)' {
        $root = Join-Path $TestDrive 'terraform-azurerm-avm-res-bar'
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { 'avm-res-should-not-win' }
            Resolve-AvmManagedFilesRepoId -Root $Root -ExplicitRepoId '  avm-res-foo  ' -KnownRepoIds @('avm-res-other') |
                Should -Be 'avm-res-foo'
            Should -Invoke Get-AvmManagedFilesOriginRepoId -Times 0 -Exactly
        }
    }

    It 'accepts a validated git-origin candidate over the folder leaf (F11)' {
        $root = Join-Path $TestDrive 'renamed-worktree'
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { 'avm-ptn-example-repo' }
            Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-ptn-example-repo') |
                Should -Be 'avm-ptn-example-repo'
        }
    }

    It 'falls back to a validated folder leaf when there is no origin (F11)' {
        $root = Join-Path $TestDrive 'terraform-azurerm-avm-res-foo'
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { '' }
            Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-res-foo') |
                Should -Be 'avm-res-foo'
        }
    }

    It 'returns an unmatched origin candidate for root-only sync (F99)' {
        $root = Join-Path $TestDrive 'some-worktree'
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { 'avm-res-fromorigin' }
            Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-res-other') |
                Should -Be 'avm-res-fromorigin'
        }
    }

    It 'returns an unmatched folder candidate for root-only sync (F99)' {
        $root = Join-Path $TestDrive 'terraform-azurerm-avm-res-anything'
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { '' }
            Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-res-other') |
                Should -Be 'avm-res-anything'
        }
    }

    It 'prompts interactively and accepts an id when automatic inference fails (F99)' {
        $root = [System.IO.Path]::GetPathRoot($TestDrive)
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { '' }
            Mock Read-Host { 'avm-res-ungrouped' }
            Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-res-other') -Interactive $true |
                Should -Be 'avm-res-ungrouped'
            Should -Invoke Read-Host -Times 1 -Exactly
        }
    }

    It 'normalises an interactive answer before returning it (F99)' {
        $root = [System.IO.Path]::GetPathRoot($TestDrive)
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { '' }
            Mock Read-Host { 'terraform-azurerm-avm-res-ungrouped' }
            Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-res-other') -Interactive $true |
                Should -Be 'avm-res-ungrouped'
        }
    }

    It 'throws a configuration error when no repository id can be found (F99)' {
        $root = [System.IO.Path]::GetPathRoot($TestDrive)
        $err = {
            InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
                param($Root)
                Mock Get-AvmManagedFilesOriginRepoId { '' }
                Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-ptn-example-repo') -Interactive $false
            }
        } | Should -Throw -PassThru
        $err.Exception.Code | Should -Be 'AVM1001'
        $err.Exception.Message | Should -Match 'Could not resolve a managed-files repository id'
    }

    It 'throws when interactive resolution returns no repository id (F99)' {
        $root = [System.IO.Path]::GetPathRoot($TestDrive)
        $err = {
            InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
                param($Root)
                Mock Get-AvmManagedFilesOriginRepoId { '' }
                Mock Read-Host { ' ' }
                Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-ptn-example-repo') -Interactive $true
            }
        } | Should -Throw -PassThru
        $err.Exception.Code | Should -Be 'AVM1001'
    }
}

Describe 'Sync-AvmManagedFile repository identity (git origin)' {
    BeforeAll {
        $script:git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

        function script:New-AvmTargetRepo {
            param(
                [Parameter(Mandatory)][string] $Dir,
                [string] $OriginUrl
            )
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            & $script:git -C $Dir init -q | Out-Null
            if ($OriginUrl) { & $script:git -C $Dir remote add origin $OriginUrl | Out-Null }
            return $Dir
        }
    }

    BeforeEach {
        $unique = [Guid]::NewGuid().ToString('N').Substring(0, 8)

        # Managed source: root + two stacked overlays (canary order 10, tooling order 20).
        $script:base = Join-Path $TestDrive ("gov-" + $unique)
        $script:root = Join-Path $script:base 'root'
        $canary = Join-Path $script:base 'canary'
        $tooling = Join-Path $script:base 'canary-tooling'
        New-Item -ItemType Directory -Path $script:root, $canary, $tooling -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "root-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'common.tf') -Value "# common`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $canary '.gitignore') -Value "canary-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $tooling '.gitignore') -Value "tooling-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $tooling 'pr-check.yml') -Value "tooling-check`n" -NoNewline

        # Governance config: avm-ptn-example-repo is in both groups.
        $script:cfg = Join-Path $TestDrive ("cfg-" + $unique)
        New-Item -ItemType Directory -Path $script:cfg -Force | Out-Null
        $config = @{ repositoryGroups = @(
                @{ name = 'canary'; managedFilesAdditional = 'canary'; managedFilesOrder = 10; repositories = @('avm-ptn-example-repo') }
                @{ name = 'canary-tooling'; managedFilesAdditional = 'canary-tooling'; managedFilesOrder = 20; repositories = @('avm-ptn-example-repo') }
            ) } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath (Join-Path $script:cfg 'config.json') -Value $config -NoNewline
        Set-Content -LiteralPath (Join-Path $script:cfg 'deprecated-files.json') -Value '[]' -NoNewline
    }

    It 'infers the repo id from the git origin when the worktree leaf does not match, and stacks overlays (F11/F01/F12)' {
        $target = script:New-AvmTargetRepo `
            -Dir (Join-Path $TestDrive ("jaredfholgate-jubilant-potato-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))) `
            -OriginUrl 'https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo.git'
        $ctx = [pscustomobject][ordered]@{ Kind = 'terraform-module-repo'; Root = $target; Ecosystem = 'terraform'; Source = 'path-heuristic' }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; B = $script:base; Cfg = $script:cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status | Should -Be 'pass'
        # Origin resolved to avm-ptn-example-repo, so BOTH overlays land (not a root-only revert).
        (Get-Content -Raw -LiteralPath (Join-Path $target '.gitignore')).Trim() | Should -Be 'tooling-version'
        (Get-Content -Raw -LiteralPath (Join-Path $target 'pr-check.yml')).Trim() | Should -Be 'tooling-check'
        Test-Path (Join-Path $target 'common.tf') | Should -BeTrue
    }

    It 'resolves an SCP-style SSH origin (F11)' {
        $target = script:New-AvmTargetRepo `
            -Dir (Join-Path $TestDrive ("ssh-clone-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))) `
            -OriginUrl 'git@github.com:Azure/terraform-azurerm-avm-ptn-example-repo.git'
        $ctx = [pscustomobject][ordered]@{ Kind = 'terraform-module-repo'; Root = $target; Ecosystem = 'terraform'; Source = 'path-heuristic' }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; B = $script:base; Cfg = $script:cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status | Should -Be 'pass'
        (Get-Content -Raw -LiteralPath (Join-Path $target '.gitignore')).Trim() | Should -Be 'tooling-version'
    }

    It 'syncs root files when the inferred origin id belongs to no group (F99)' {
        $target = script:New-AvmTargetRepo `
            -Dir (Join-Path $TestDrive ("eventgrid-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))) `
            -OriginUrl 'https://github.com/Azure/terraform-azurerm-avm-res-eventgrid-namespace.git'
        $ctx = [pscustomobject][ordered]@{ Kind = 'terraform-module-repo'; Root = $target; Ecosystem = 'terraform'; Source = 'path-heuristic' }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; B = $script:base; Cfg = $script:cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status | Should -Be 'pass'
        (Get-Content -Raw -LiteralPath (Join-Path $target '.gitignore')).Trim() | Should -Be 'root-version'
        Test-Path (Join-Path $target 'common.tf') | Should -BeTrue
        Test-Path (Join-Path $target 'pr-check.yml') | Should -BeFalse
    }

    It 'lets an explicit -RepoId short-circuit git-origin inference (F11)' {
        # Origin would normalise to avm-res-bar (absent from config); the explicit id must still win.
        $target = script:New-AvmTargetRepo `
            -Dir (Join-Path $TestDrive ("misleading-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))) `
            -OriginUrl 'https://github.com/Azure/terraform-azurerm-avm-res-bar.git'
        $ctx = [pscustomobject][ordered]@{ Kind = 'terraform-module-repo'; Root = $target; Ecosystem = 'terraform'; Source = 'path-heuristic' }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; B = $script:base; Cfg = $script:cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -RepoId 'avm-ptn-example-repo'
        }

        $result.Status | Should -Be 'pass'
        (Get-Content -Raw -LiteralPath (Join-Path $target '.gitignore')).Trim() | Should -Be 'tooling-version'
    }

    It 'syncs root files using the folder id when the origin is unavailable (F99)' {
        $target = script:New-AvmTargetRepo `
            -Dir (Join-Path $TestDrive 'terraform-azurerm-avm-res-ungrouped') `
            -OriginUrl ''
        $ctx = [pscustomobject][ordered]@{ Kind = 'terraform-module-repo'; Root = $target; Ecosystem = 'terraform'; Source = 'path-heuristic' }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; B = $script:base; Cfg = $script:cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status | Should -Be 'pass'
        (Get-Content -Raw -LiteralPath (Join-Path $target '.gitignore')).Trim() | Should -Be 'root-version'
        Test-Path (Join-Path $target 'pr-check.yml') | Should -BeFalse
    }
}

Describe 'Sync-AvmManagedFile git index safety (F13)' {
    BeforeAll {
        $script:git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }

    It 'never stages synced files, including executable-mode ones, and leaves the index untouched (F13)' {
        $unique = [Guid]::NewGuid().ToString('N').Substring(0, 8)

        # Managed source is a git repo whose root/avm is staged with mode 100755.
        $srcBase = Join-Path $TestDrive ("idx-src-" + $unique)
        $srcRoot = Join-Path $srcBase 'root'
        New-Item -ItemType Directory -Path $srcRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $srcRoot 'avm') -Value "#!/usr/bin/env pwsh`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $srcRoot '.gitignore') -Value "*.tfstate`n" -NoNewline
        & $script:git -C $srcBase init -q | Out-Null
        & $script:git -C $srcBase add -A | Out-Null
        & $script:git -C $srcBase update-index --chmod=+x root/avm | Out-Null
        ((& $script:git -C $srcBase ls-files --stage -- root/avm) -join '') | Should -Match '^100755 '

        # Target working tree is a git repo with a pre-staged UNRELATED file that must stay staged.
        $target = Join-Path $TestDrive ("idx-tgt-" + $unique)
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        & $script:git -C $target init -q | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'unrelated.txt') -Value "keep me staged`n" -NoNewline
        & $script:git -C $target add unrelated.txt | Out-Null
        $before = (& $script:git -C $target ls-files --stage) -join "`n"

        $ctx = [pscustomobject][ordered]@{ Kind = 'terraform-module-repo'; Root = $target; Ecosystem = 'terraform'; Source = 'path-heuristic' }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; B = $srcBase } {
            param($C, $B)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -RepoId 'avm-res-foo'
        }

        $result.Status | Should -Be 'pass'
        # The executable file landed on disk...
        Test-Path (Join-Path $target 'avm') | Should -BeTrue
        # ...but the git index is byte-for-byte unchanged: sync never staged anything.
        $after = (& $script:git -C $target ls-files --stage) -join "`n"
        $after | Should -Be $before
        # Synced files are untracked, never staged.
        $porcelain = @(& $script:git -C $target status --porcelain)
        @($porcelain | Where-Object { $_ -match '^\?\?\s+avm$' }) | Should -Not -BeNullOrEmpty
        @($porcelain | Where-Object { $_ -match '^\?\?\s+\.gitignore$' }) | Should -Not -BeNullOrEmpty
    }
}
