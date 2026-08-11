#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    # Every repository resolves its file groups from config.json. The 'default'
    # group's '*' wildcard is what makes 'root' apply everywhere, so tests build a
    # real config rather than relying on any implicit behaviour in the engine.
    function script:New-TestConfigDirectory {
        param(
            [Parameter(Mandatory)] [string] $Path,
            [object[]] $RepositoryGroups = @(),
            [string[]] $DefaultManagedFiles = @('root')
        )

        New-Item -ItemType Directory -Path $Path -Force | Out-Null

        $groups = @(
            [ordered]@{
                name         = 'default'
                repositories = @('*')
                order        = -100
                managedFiles = @($DefaultManagedFiles)
            }
        ) + @($RepositoryGroups)

        Set-Content -LiteralPath (Join-Path $Path 'config.json') `
            -Value (@{ repositoryGroups = @($groups) } | ConvertTo-Json -Depth 8) -NoNewline

        return $Path
    }

    function script:New-TestFileGroupConfig {
        param(
            [Parameter(Mandatory)] [string] $Path,
            [hashtable] $DeletedFilesByGroup = @{}
        )

        $fileGroups = @(
            foreach ($name in $DeletedFilesByGroup.Keys) {
                [ordered]@{ name = $name; deletedFiles = @($DeletedFilesByGroup[$name]) }
            }
        )

        Set-Content -LiteralPath $Path `
            -Value (@{ fileGroups = @($fileGroups) } | ConvertTo-Json -Depth 8) -NoNewline

        return $Path
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-AvmManagedFilesSetting defaults' {
    It 'uses the tooling repository paths and inherits the effective managed source for config' {
        $environmentNames = @(
            'AVM_MANAGED_FILES_REPO'
            'AVM_MANAGED_FILES_REF'
            'AVM_MANAGED_FILES_PATH'
            'AVM_MANAGED_FILES_LOCAL_PATH'
            'AVM_MANAGED_FILES_GROUP_CONFIG_PATH'
            'AVM_MANAGED_FILES_GROUP_CONFIG_LOCAL_PATH'
            'AVM_MANAGED_FILES_CONFIG_REPO'
            'AVM_MANAGED_FILES_CONFIG_REF'
            'AVM_MANAGED_FILES_CONFIG_PATH'
            'AVM_MANAGED_FILES_CONFIG_LOCAL_PATH'
            'AVM_MANAGED_FILES_REPO_ID'
        )
        $originalEnvironment = @{}

        try {
            foreach ($name in $environmentNames) {
                $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, $null)
            }

            $settings = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $TestDrive } {
                param($Root)
                Resolve-AvmManagedFilesSetting -Root $Root
            }

            $settings.ManagedFilesRepo | Should -Be 'Azure/azure-verified-modules-managed-files'
            $settings.ManagedFilesRef | Should -Be 'main'
            $settings.ManagedFilesPath | Should -Be 'terraform/files'
            $settings.FileGroupConfigPath | Should -Be 'terraform/config/managed-files.json'
            $settings.ConfigRepo | Should -Be 'Azure/azure-verified-modules-tools'
            $settings.ConfigRef | Should -Be 'main'
            $settings.ConfigPath | Should -Be 'repository-management/repository-config'

            $overridden = InModuleScope 'Avm.Authoring' -Parameters @{ Root = $TestDrive } {
                param($Root)
                Resolve-AvmManagedFilesSetting `
                    -Root $Root `
                    -ManagedFilesRepo 'example/source' `
                    -ManagedFilesRef 'pinned'
            }

            # config.json lives in the tools repository, so overriding the
            # managed-files source must not drag the config source with it.
            $overridden.ManagedFilesRepo | Should -Be 'example/source'
            $overridden.ManagedFilesRef | Should -Be 'pinned'
            $overridden.ConfigRepo | Should -Be 'Azure/azure-verified-modules-tools'
            $overridden.ConfigRef | Should -Be 'main'
        }
        finally {
            foreach ($name in $environmentNames) {
                [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
            }
        }
    }

    It 'contains no live dependency on the retired governance repository' {
        $retiredIdentifier = 'avm-terraform-' + 'governance'
        $sourcePath = Join-Path $script:moduleRoot 'Engines' 'ManagedFiles' 'Sync-AvmManagedFile.ps1'
        Get-Content -LiteralPath $sourcePath -Raw |
            Should -Not -Match ([regex]::Escape($retiredIdentifier))
    }
}

Describe 'Sync-AvmManagedFile' {
    BeforeEach {
        $unique = [Guid]::NewGuid().ToString('N').Substring(0, 8)

        # Managed-files source: a base folder holding root/ (and optionally
        # other file groups).
        $script:base = Join-Path $TestDrive ("gov-" + $unique)
        $script:root = Join-Path $script:base 'root'
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null

        # Repository config, carrying the 'default' group that maps '*' -> root.
        $script:cfgDir = New-TestConfigDirectory -Path (Join-Path $TestDrive ("cfg-" + $unique))

        # File-group config, carrying per-group deletedFiles.
        $script:fileGroupConfig = New-TestFileGroupConfig -Path (Join-Path $script:cfgDir 'managed-files.json')

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

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
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

    It 'broadcasts reserved _all subtrees to immediate module and example children' {
        $moduleAll = Join-Path (Join-Path $script:root 'modules') '_all'
        $exampleAll = Join-Path (Join-Path $script:root 'examples') '_all'
        New-Item -ItemType Directory -Path $moduleAll -Force | Out-Null
        New-Item -ItemType Directory -Path $exampleAll -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $moduleAll '_footer.md') -Value "module footer`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $exampleAll '_footer.md') -Value "example footer`n" -NoNewline

        foreach ($relativeDir in @('modules/alpha', 'modules/beta', 'modules/alpha/nested', 'examples/default')) {
            New-Item -ItemType Directory -Path (Join-Path $script:moduleDir $relativeDir) -Force | Out-Null
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 3
        $result.Added          | Should -Be @(
            'examples/default/_footer.md',
            'modules/alpha/_footer.md',
            'modules/beta/_footer.md'
        )

        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir 'modules/alpha/_footer.md')).Trim() | Should -Be 'module footer'
        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir 'modules/beta/_footer.md')).Trim() | Should -Be 'module footer'
        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir 'examples/default/_footer.md')).Trim() | Should -Be 'example footer'
        Test-Path (Join-Path $script:moduleDir 'modules/alpha/nested/_footer.md') | Should -BeFalse
        Test-Path (Join-Path $script:moduleDir 'modules/_all') | Should -BeFalse
        Test-Path (Join-Path $script:moduleDir 'examples/_all') | Should -BeFalse
    }

    It 'broadcasts under arbitrary named parents and supports chained scopes' {
        $contentAll = Join-Path (Join-Path $script:root 'content') '_all'
        $contentConfig = Join-Path $contentAll 'config'
        $regionAll = Join-Path (Join-Path $script:root 'regions') '_all'
        $packageAll = Join-Path (Join-Path $regionAll 'packages') '_all'
        $missingAll = Join-Path (Join-Path $script:root 'missing') '_all'
        New-Item -ItemType Directory -Path $contentConfig -Force | Out-Null
        New-Item -ItemType Directory -Path $packageAll -Force | Out-Null
        New-Item -ItemType Directory -Path $missingAll -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $contentConfig 'settings.json') -Value "{}`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $packageAll 'settings.json') -Value "{}`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $missingAll 'ignored.txt') -Value "ignored`n" -NoNewline

        foreach ($relativeDir in @(
                'content/alpha',
                'content/beta',
                'regions/east/packages/one',
                'regions/east/packages/two',
                'regions/west/packages/three'
            )) {
            New-Item -ItemType Directory -Path (Join-Path $script:moduleDir $relativeDir) -Force | Out-Null
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 5
        $result.Added          | Should -Be @(
            'content/alpha/config/settings.json',
            'content/beta/config/settings.json',
            'regions/east/packages/one/settings.json',
            'regions/east/packages/two/settings.json',
            'regions/west/packages/three/settings.json'
        )
        Test-Path (Join-Path $script:moduleDir 'content/alpha/config/settings.json') | Should -BeTrue
        Test-Path (Join-Path $script:moduleDir 'regions/east/packages/one/settings.json') | Should -BeTrue
        Test-Path (Join-Path $script:moduleDir 'content/_all') | Should -BeFalse
        Test-Path (Join-Path $script:moduleDir 'regions/east/packages/_all') | Should -BeFalse
        Test-Path (Join-Path $script:moduleDir 'missing') | Should -BeFalse
    }

    It 'keeps a root-level _all directory literal' {
        $rootAll = Join-Path $script:root '_all'
        New-Item -ItemType Directory -Path $rootAll -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $rootAll 'literal.txt') -Value "literal`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 1
        $result.Added          | Should -Be @('_all/literal.txt')
        Test-Path (Join-Path $script:moduleDir '_all/literal.txt') | Should -BeTrue
    }

    It 'preserves overlay, concrete-path, and exclusion precedence after _all expansion' {
        $rootModuleAll = Join-Path (Join-Path $script:root 'modules') '_all'
        $rootAlpha = Join-Path (Join-Path $script:root 'modules') 'alpha'
        $rootPolicyAll = Join-Path (Join-Path $script:root 'policies') '_all'
        New-Item -ItemType Directory -Path $rootModuleAll -Force | Out-Null
        New-Item -ItemType Directory -Path $rootAlpha -Force | Out-Null
        New-Item -ItemType Directory -Path $rootPolicyAll -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $rootModuleAll '_footer.md') -Value "root broadcast`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $rootAlpha '_footer.md') -Value "root alpha`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $rootPolicyAll 'rule.json') -Value "{}`n" -NoNewline

        $canary = Join-Path $script:base 'canary'
        $canaryModuleAll = Join-Path (Join-Path $canary 'modules') '_all'
        $canaryBeta = Join-Path (Join-Path $canary 'modules') 'beta'
        New-Item -ItemType Directory -Path $canaryModuleAll -Force | Out-Null
        New-Item -ItemType Directory -Path $canaryBeta -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $canaryModuleAll '_footer.md') -Value "canary broadcast`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $canaryBeta '_footer.md') -Value "canary beta`n" -NoNewline

        foreach ($relativeDir in @('modules/alpha', 'modules/beta', 'modules/gamma', 'policies/alpha', 'policies/beta')) {
            New-Item -ItemType Directory -Path (Join-Path $script:moduleDir $relativeDir) -Force | Out-Null
        }

        $cfg = New-TestConfigDirectory -Path (Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))) -RepositoryGroups @(
            [ordered]@{
                name         = 'canary'
                repositories = @('avm-res-foo')
                order        = 10
                managedFiles = @('canary')
            }
        )
        $fgc = New-TestFileGroupConfig -Path (Join-Path $cfg 'managed-files.json') -DeletedFilesByGroup @{
            canary = @('modules/gamma/_footer.md', 'policies/_all/rule.json')
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $cfg; F = $fgc } {
            param($C, $B, $Cfg, $F)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -FileGroupConfigLocalPath $F -RepoId 'avm-res-foo'
        }

        $result.Status | Should -Be 'pass'
        $result.Added  | Should -Be @('modules/alpha/_footer.md', 'modules/beta/_footer.md')
        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir 'modules/alpha/_footer.md')).Trim() | Should -Be 'canary broadcast'
        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir 'modules/beta/_footer.md')).Trim() | Should -Be 'canary beta'
        Test-Path (Join-Path $script:moduleDir 'modules/gamma/_footer.md') | Should -BeFalse
        Test-Path (Join-Path $script:moduleDir 'policies/alpha/rule.json') | Should -BeFalse
        Test-Path (Join-Path $script:moduleDir 'policies/beta/rule.json') | Should -BeFalse
    }

    It 'is a no-op on a second run with no changes' {
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "*.tfstate`n" -NoNewline

        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg | Out-Null
        }

        $second = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $second.Status  | Should -Be 'pass'
        $second.Added   | Should -BeNullOrEmpty
        $second.Updated | Should -BeNullOrEmpty
        $second.Removed | Should -BeNullOrEmpty
    }

    It 'logs each planned operation and omits unchanged files' {
        Set-Content -LiteralPath (Join-Path $script:root 'create.txt') -Value "new`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'update.txt') -Value "current`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'unchanged.txt') -Value "same`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'update.txt') -Value "stale`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'unchanged.txt') -Value "same`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'deprecated.txt') -Value "remove`n" -NoNewline

        $cfg = New-TestConfigDirectory -Path (Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)))
        $fgc = New-TestFileGroupConfig -Path (Join-Path $cfg 'managed-files.json') -DeletedFilesByGroup @{
            root = @('deprecated.txt')
        }

        $output = @(InModuleScope 'Avm.Authoring' -Parameters @{
                C = $script:context
                B = $script:base
                G = $cfg
                F = $fgc
            } {
                param($C, $B, $G, $F)
                Sync-AvmManagedFile `
                    -Context $C `
                    -ManagedFilesLocalPath $B `
                    -ConfigLocalPath $G `
                    -FileGroupConfigLocalPath $F `
                    -RepoId 'avm-res-foo' `
                    -CheckDrift `
                    -Verbose 4>&1
            })
        $messages = @($output |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
                ForEach-Object { $_.Message -replace "$([char]27)\[[0-9;]*m", '' })

        $messages | Should -Contain 'sync: create create.txt'
        $messages | Should -Contain 'sync: update update.txt (content)'
        $messages | Should -Contain 'sync: delete deprecated.txt'
        $messages -join "`n" | Should -Not -Match 'unchanged\.txt'
    }

    It 'logs a Git mode-only update with the existing and desired modes' {
        Set-Content -LiteralPath (Join-Path $script:root 'avm') -Value "#!/bin/sh`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'avm') -Value "#!/bin/sh`n" -NoNewline
        & git -C $script:moduleDir init --quiet
        & git -C $script:moduleDir add -- avm
        & git -C $script:moduleDir update-index --chmod=+x -- avm

        $output = @(InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
                param($C, $B, $Cfg)
                Sync-AvmManagedFile `
                    -Context $C `
                    -ManagedFilesLocalPath $B `
                    -ConfigLocalPath $Cfg `
                    -CheckDrift `
                    -Verbose 4>&1
            })
        $messages = @($output |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
                ForEach-Object { $_.Message -replace "$([char]27)\[[0-9;]*m", '' })
        $result = $output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }

        $result.Updated | Should -Be @('avm')
        $messages | Should -Contain 'sync: update avm (mode 100755 -> 100644)'
    }

    It 'updates a stale managed file' {
        $gitignore = Join-Path $script:root '.gitignore'
        Set-Content -LiteralPath $gitignore -Value "*.tfstate`n" -NoNewline

        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg | Out-Null
        }

        # Mutate the source so the on-disk copy is now stale.
        Set-Content -LiteralPath $gitignore -Value "*.tfstate`n.terraform/`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
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

        InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg | Out-Null
        }

        # Introduce drift in the source.
        Set-Content -LiteralPath $gitignore -Value "*.tfstate`n.terraform/`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -CheckDrift
        }

        $result.Status       | Should -Be 'fail'
        $result.Updated      | Should -HaveCount 1
        $result.Issues.Count | Should -BeGreaterThan 0

        # Nothing was written: the on-disk copy is still the old content.
        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')
        $onDisk | Should -Not -Match 'terraform'
    }

    It 'applies a higher-order file group and honours deletedFiles from the file-group config' {
        $canary = Join-Path $script:base 'canary'
        New-Item -ItemType Directory -Path $canary -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "root-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'common.tf') -Value "# common`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'excludeme.txt') -Value "skip`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $canary '.gitignore') -Value "canary-version`n" -NoNewline

        $cfg = New-TestConfigDirectory -Path (Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))) -RepositoryGroups @(
            [ordered]@{ name = 'canary'; repositories = @('avm-res-foo'); order = 10; managedFiles = @('canary') }
        )
        $fgc = New-TestFileGroupConfig -Path (Join-Path $cfg 'managed-files.json') -DeletedFilesByGroup @{
            canary = @('excludeme.txt')
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $cfg; F = $fgc } {
            param($C, $B, $Cfg, $F)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -FileGroupConfigLocalPath $F -RepoId 'avm-res-foo'
        }

        $result.Status  | Should -Be 'pass'
        $result.Added   | Should -HaveCount 2

        # The higher-order group wins for .gitignore.
        $gi = (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')).Trim()
        $gi | Should -Be 'canary-version'

        # Excluded file is never synced.
        Test-Path (Join-Path $script:moduleDir 'excludeme.txt') | Should -BeFalse
        # Root-only file still lands.
        Test-Path (Join-Path $script:moduleDir 'common.tf') | Should -BeTrue
    }

    It 'stacks multiple file groups in order, the highest order winning' {
        $alz = Join-Path $script:base 'alz'
        $canary = Join-Path $script:base 'canary'
        New-Item -ItemType Directory -Path $alz -Force | Out-Null
        New-Item -ItemType Directory -Path $canary -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "root-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'pr-check.yml') -Value "root-check`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'common.tf') -Value "# common`n" -NoNewline

        Set-Content -LiteralPath (Join-Path $alz '.gitignore') -Value "alz-version`n" -NoNewline
        # Placeholder that keeps an otherwise-empty file group tracked in git.
        Set-Content -LiteralPath (Join-Path $alz '.gitkeep') -Value '' -NoNewline

        Set-Content -LiteralPath (Join-Path $canary '.gitignore') -Value "canary-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $canary 'pr-check.yml') -Value "canary-check`n" -NoNewline

        $cfg = New-TestConfigDirectory -Path (Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))) -RepositoryGroups @(
            [ordered]@{ name = 'alz'; repositories = @('avm-res-foo'); order = 10; managedFiles = @('alz') }
            [ordered]@{ name = 'canary'; repositories = @('avm-res-foo'); order = 20; managedFiles = @('canary') }
        )

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -RepoId 'avm-res-foo'
        }

        $result.Status | Should -Be 'pass'
        $result.Added  | Should -HaveCount 3

        # The highest-order group wins over both the earlier group and root.
        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')).Trim() | Should -Be 'canary-version'
        # A group-only override of a root file wins.
        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir 'pr-check.yml')).Trim() | Should -Be 'canary-check'
        # Root-only file still lands.
        Test-Path (Join-Path $script:moduleDir 'common.tf') | Should -BeTrue
        # '.gitkeep' placeholders are never synced into the target repo.
        Test-Path (Join-Path $script:moduleDir '.gitkeep') | Should -BeFalse
    }

    It 'removes files listed in deletedFiles for an applicable group' {
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "*.tfstate`n" -NoNewline

        $cfg = New-TestConfigDirectory -Path (Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)))
        $fgc = New-TestFileGroupConfig -Path (Join-Path $cfg 'managed-files.json') -DeletedFilesByGroup @{
            root = @('old-thing.txt')
        }

        # Pre-seed the deleted file into the working tree.
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'old-thing.txt') -Value "delete me`n" -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $cfg; F = $fgc } {
            param($C, $B, $Cfg, $F)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -FileGroupConfigLocalPath $F -RepoId 'avm-res-foo'
        }

        $result.Status  | Should -Be 'pass'
        $result.Removed | Should -HaveCount 1

        Test-Path (Join-Path $script:moduleDir 'old-thing.txt') | Should -BeFalse
    }

    It 'lets a later group re-add a file an earlier group deleted' {
        $canary = Join-Path $script:base 'canary'
        New-Item -ItemType Directory -Path $canary -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:root 'contested.txt') -Value "root-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $canary 'contested.txt') -Value "canary-version`n" -NoNewline

        $cfg = New-TestConfigDirectory -Path (Join-Path $TestDrive ("cfg-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))) -RepositoryGroups @(
            [ordered]@{ name = 'canary'; repositories = @('avm-res-foo'); order = 10; managedFiles = @('canary') }
        )
        # 'root' deletes it, but 'canary' sorts later and supplies it again.
        $fgc = New-TestFileGroupConfig -Path (Join-Path $cfg 'managed-files.json') -DeletedFilesByGroup @{
            root = @('contested.txt')
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $cfg; F = $fgc } {
            param($C, $B, $Cfg, $F)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -FileGroupConfigLocalPath $F -RepoId 'avm-res-foo'
        }

        $result.Status  | Should -Be 'pass'
        $result.Removed | Should -BeNullOrEmpty
        (Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir 'contested.txt')).Trim() | Should -Be 'canary-version'
    }

    It 'returns a clean pass with FilesProcessed=0 when the source root is empty' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status         | Should -Be 'pass'
        $result.FilesProcessed | Should -Be 0
        $result.Added          | Should -BeNullOrEmpty
        $result.Issues         | Should -BeNullOrEmpty
    }

    It 'creates a line-managed file when it is missing and classifies it as Added' {
        $spec = '{ ".gitignore": { "required": ["*.tfstate", ".terraform/"], "removed": [] } }'
        Set-Content -LiteralPath (Join-Path $script:root '.avm-managed-lines.json') -Value $spec -NoNewline

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
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

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
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

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
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

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -CheckDrift
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

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; B = $script:base; Cfg = $script:cfgDir } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status | Should -Be 'pass'

        $onDisk = Get-Content -Raw -LiteralPath (Join-Path $script:moduleDir '.gitignore')
        $onDisk | Should -Match 'user-line'
        $onDisk | Should -Match 'line-managed-entry'
        $onDisk | Should -Not -Match 'whole-file-version'
    }
}

Describe 'Resolve-AvmManagedFilesRepositorySetting file group ordering' {
    BeforeAll {
        # Round-trip through JSON so the shape matches production exactly: the
        # function inspects PSObject.Properties, which behaves differently on a
        # raw hashtable than on the PSCustomObject ConvertFrom-Json produces.
        function script:New-TestConfig {
            param([object[]] $Groups)
            return (@{ repositoryGroups = $Groups } | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
        }

        function script:Resolve-FileGroups {
            param([object] $Config, [string] $RepoId)
            $settings = InModuleScope 'Avm.Authoring' -Parameters @{ C = $Config; R = $RepoId } {
                param($C, $R)
                Resolve-AvmManagedFilesRepositorySetting -RepositoryConfig $C -RepoId $R
            }
            return @($settings.FileGroups)
        }
    }

    It 'falls back to declaration order when no order is set' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'first'; managedFiles = @('alpha'); repositories = @('repo-x') }
            @{ name = 'second'; managedFiles = @('beta'); repositories = @('repo-x') }
        )

        script:Resolve-FileGroups -Config $config -RepoId 'repo-x' | Should -Be @('alpha', 'beta')
    }

    It 'lets an explicit order override declaration order' {
        # 'alpha' is declared FIRST but carries a higher order, so it must sort
        # last and therefore win. This is the whole point of the field.
        $config = script:New-TestConfig -Groups @(
            @{ name = 'first'; managedFiles = @('alpha'); order = 99; repositories = @('repo-x') }
            @{ name = 'second'; managedFiles = @('beta'); order = 1; repositories = @('repo-x') }
        )

        script:Resolve-FileGroups -Config $config -RepoId 'repo-x' | Should -Be @('beta', 'alpha')
    }

    It 'treats a missing order as 0' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'ordered'; managedFiles = @('alpha'); order = 5; repositories = @('repo-x') }
            @{ name = 'unordered'; managedFiles = @('beta'); repositories = @('repo-x') }
        )

        script:Resolve-FileGroups -Config $config -RepoId 'repo-x' | Should -Be @('beta', 'alpha')
    }

    It 'breaks ties on declaration order' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'first'; managedFiles = @('alpha'); order = 10; repositories = @('repo-x') }
            @{ name = 'second'; managedFiles = @('beta'); order = 10; repositories = @('repo-x') }
        )

        script:Resolve-FileGroups -Config $config -RepoId 'repo-x' | Should -Be @('alpha', 'beta')
    }

    It 'ignores groups the repository does not belong to' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'other'; managedFiles = @('alpha'); order = 1; repositories = @('repo-y') }
            @{ name = 'mine'; managedFiles = @('beta'); order = 2; repositories = @('repo-x') }
        )

        script:Resolve-FileGroups -Config $config -RepoId 'repo-x' | Should -Be @('beta')
    }

    It 'returns no file groups when the repository belongs to no group' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'other'; managedFiles = @('alpha'); repositories = @('repo-y') }
        )

        script:Resolve-FileGroups -Config $config -RepoId 'repo-x' | Should -HaveCount 0
    }

    It 'counts declaration index across groups that declare no managed files' {
        # The middle group contributes no file group but must still advance the
        # tie-break index, so 'alpha' and 'beta' stay in declaration order.
        $config = script:New-TestConfig -Groups @(
            @{ name = 'first'; managedFiles = @('alpha'); repositories = @('repo-x') }
            @{ name = 'tier'; repositories = @('repo-x') }
            @{ name = 'third'; managedFiles = @('beta'); repositories = @('repo-x') }
        )

        script:Resolve-FileGroups -Config $config -RepoId 'repo-x' | Should -Be @('alpha', 'beta')
    }

    It 'matches every repository through the wildcard' {
        # The 'default' group uses '*' so its files apply everywhere, and its
        # negative order puts them first.
        $config = script:New-TestConfig -Groups @(
            @{ name = 'canary'; managedFiles = @('canary'); order = 10; repositories = @('avm-ptn-example-repo') }
            @{ name = 'default'; managedFiles = @('root'); order = -100; repositories = @('*') }
        )

        script:Resolve-FileGroups -Config $config -RepoId 'avm-ptn-example-repo' |
            Should -Be @('root', 'canary')
        script:Resolve-FileGroups -Config $config -RepoId 'avm-res-unlisted' |
            Should -Be @('root')
    }

    It 'flattens a group that declares several managed file groups' {
        $config = script:New-TestConfig -Groups @(
            @{ name = 'combo'; managedFiles = @('alpha', 'beta'); order = 5; repositories = @('repo-x') }
            @{ name = 'later'; managedFiles = @('gamma'); order = 10; repositories = @('repo-x') }
        )

        script:Resolve-FileGroups -Config $config -RepoId 'repo-x' | Should -Be @('alpha', 'beta', 'gamma')
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

    It 'returns an unmatched origin candidate for root-only sync (F100)' {
        $root = Join-Path $TestDrive 'some-worktree'
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { 'avm-res-fromorigin' }
            Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-res-other') |
                Should -Be 'avm-res-fromorigin'
        }
    }

    It 'returns an unmatched folder candidate for root-only sync (F100)' {
        $root = Join-Path $TestDrive 'terraform-azurerm-avm-res-anything'
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { '' }
            Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-res-other') |
                Should -Be 'avm-res-anything'
        }
    }

    It 'prompts interactively and accepts an id when automatic inference fails (F100)' {
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

    It 'normalises an interactive answer before returning it (F100)' {
        $root = [System.IO.Path]::GetPathRoot($TestDrive)
        InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root } {
            param($Root)
            Mock Get-AvmManagedFilesOriginRepoId { '' }
            Mock Read-Host { 'terraform-azurerm-avm-res-ungrouped' }
            Resolve-AvmManagedFilesRepoId -Root $Root -KnownRepoIds @('avm-res-other') -Interactive $true |
                Should -Be 'avm-res-ungrouped'
        }
    }

    It 'throws a configuration error when no repository id can be found (F100)' {
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

    It 'throws when interactive resolution returns no repository id (F100)' {
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

        # Managed source: root + two stacked file groups (alz order 10, canary order 20).
        $script:base = Join-Path $TestDrive ("gov-" + $unique)
        $script:root = Join-Path $script:base 'root'
        $alz = Join-Path $script:base 'alz'
        $canary = Join-Path $script:base 'canary'
        New-Item -ItemType Directory -Path $script:root, $alz, $canary -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:root '.gitignore') -Value "root-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $script:root 'common.tf') -Value "# common`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $alz '.gitignore') -Value "alz-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $canary '.gitignore') -Value "canary-version`n" -NoNewline
        Set-Content -LiteralPath (Join-Path $canary 'pr-check.yml') -Value "canary-check`n" -NoNewline

        # Governance config: avm-ptn-example-repo is in both groups.
        $script:cfg = New-TestConfigDirectory -Path (Join-Path $TestDrive ("cfg-" + $unique)) -RepositoryGroups @(
            [ordered]@{ name = 'alz'; repositories = @('avm-ptn-example-repo'); order = 10; managedFiles = @('alz') }
            [ordered]@{ name = 'canary'; repositories = @('avm-ptn-example-repo'); order = 20; managedFiles = @('canary') }
        )
    }

    It 'infers the repo id from the git origin when the worktree leaf does not match, and stacks file groups (F11/F01/F12)' {
        $target = script:New-AvmTargetRepo `
            -Dir (Join-Path $TestDrive ("jaredfholgate-jubilant-potato-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))) `
            -OriginUrl 'https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo.git'
        $ctx = [pscustomobject][ordered]@{ Kind = 'terraform-module-repo'; Root = $target; Ecosystem = 'terraform'; Source = 'path-heuristic' }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; B = $script:base; Cfg = $script:cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg
        }

        $result.Status | Should -Be 'pass'
        # Origin resolved to avm-ptn-example-repo, so BOTH file groups land (not a root-only revert).
        (Get-Content -Raw -LiteralPath (Join-Path $target '.gitignore')).Trim() | Should -Be 'canary-version'
        (Get-Content -Raw -LiteralPath (Join-Path $target 'pr-check.yml')).Trim() | Should -Be 'canary-check'
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
        (Get-Content -Raw -LiteralPath (Join-Path $target '.gitignore')).Trim() | Should -Be 'canary-version'
    }

    It 'syncs root files when the inferred origin id belongs to no group (F100)' {
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
        (Get-Content -Raw -LiteralPath (Join-Path $target '.gitignore')).Trim() | Should -Be 'canary-version'
    }

    It 'syncs root files using the folder id when the origin is unavailable (F100)' {
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
        $cfg = New-TestConfigDirectory -Path (Join-Path $TestDrive ("idx-cfg-" + $unique))
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; B = $srcBase; Cfg = $cfg } {
            param($C, $B, $Cfg)
            Sync-AvmManagedFile -Context $C -ManagedFilesLocalPath $B -ConfigLocalPath $Cfg -RepoId 'avm-res-foo'
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
