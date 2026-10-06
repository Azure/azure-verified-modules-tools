#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Avm.Authoring module' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        $script:manifestPath = Join-Path $script:moduleRoot 'Avm.Authoring.psd1'
    }

    Context 'Manifest casing and shape' {
        It 'has a valid manifest' {
            { Test-ModuleManifest -Path $script:manifestPath } | Should -Not -Throw
        }

        It 'the on-disk folder name has the exact expected casing' {
            $folderName = Split-Path -Leaf $script:moduleRoot
            $folderName | Should -BeExactly 'Avm.Authoring'
        }

        It 'the on-disk manifest file name has the exact expected casing' {
            $found = Get-ChildItem -Path $script:moduleRoot -File |
                Where-Object { $_.Name -ceq 'Avm.Authoring.psd1' }
            $found | Should -Not -BeNullOrEmpty
        }

        It 'manifest Name matches the on-disk file basename' {
            $manifest = Test-ModuleManifest -Path $script:manifestPath
            $expectedName = [System.IO.Path]::GetFileNameWithoutExtension($script:manifestPath)
            $manifest.Name | Should -BeExactly $expectedName
        }

        It 'manifest PowerShellVersion is at least 7.4' {
            $manifest = Test-ModuleManifest -Path $script:manifestPath
            $manifest.PowerShellVersion | Should -BeGreaterOrEqual ([version]'7.4')
        }
    }

    Context 'Import and exports' {
        BeforeAll {
            Import-Module $script:manifestPath -Force
        }

        AfterAll {
            Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
        }

        It 'exports exactly the manifest functions, one per Public script' {
            $manifest = Import-PowerShellDataFile -LiteralPath $script:manifestPath
            $publicRoot = Join-Path (Split-Path -Parent $script:manifestPath) 'Public'
            $scripts = @(Get-ChildItem -LiteralPath $publicRoot -Filter '*.ps1' -Recurse -File).BaseName |
                Sort-Object
            $exported = @((Get-Module 'Avm.Authoring').ExportedFunctions.Keys) | Sort-Object

            $exported | Should -Be (@($manifest.FunctionsToExport) | Sort-Object)
            $exported | Should -Be $scripts
        }

        It 'keeps one exception type identity when a reimport follows script-cache eviction' {
            $clearCache = [scriptblock].GetMethod('ClearScriptBlockCache', [System.Reflection.BindingFlags]'NonPublic,Static')
            if ($null -eq $clearCache) {
                Set-ItResult -Skipped -Because 'this PowerShell version does not expose the parsed-script cache'
                return
            }
            $before = & (Get-Module 'Avm.Authoring') { [AvmProcessException] }
            $null = $clearCache.Invoke($null, @())
            Import-Module $script:manifestPath -Force
            $after = & (Get-Module 'Avm.Authoring') { [AvmProcessException] }
            [object]::ReferenceEquals($before, $after) | Should -BeTrue
        }

        It 'exports the avm alias pointing at Invoke-Avm' {
            $alias = Get-Alias -Name 'avm' -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be 'Invoke-Avm'
        }

        It 'retains the Get-AvmAuthoringPlaceholder back-compat shim' {
            Get-Command -Module 'Avm.Authoring' -Name 'Get-AvmAuthoringPlaceholder' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'does not leak private helper <_>' -ForEach @('Get-AvmFolder', 'Invoke-AvmHttp', 'Test-AvmPins') {
            Get-Command -Module 'Avm.Authoring' -Name $_ -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }

        It 'adds SkipModuleVersionCheck to every exported function except self-update' {
            $commands = Get-Command -Module 'Avm.Authoring' -CommandType Function |
                Where-Object Name -cne 'Update-AvmAuthoring'
            $commands.Count | Should -BeGreaterThan 0
            foreach ($command in $commands) {
                $command.Parameters.ContainsKey('SkipModuleVersionCheck') |
                    Should -BeTrue -Because "$($command.Name) must expose the module version check opt-out"
            }
        }

        It 'does not expose a redundant module-version opt-out on self-update' {
            $command = Get-Command -Module 'Avm.Authoring' -Name 'Update-AvmAuthoring'
            $command.Parameters.ContainsKey('SkipModuleVersionCheck') | Should -BeFalse
        }
    }
}
