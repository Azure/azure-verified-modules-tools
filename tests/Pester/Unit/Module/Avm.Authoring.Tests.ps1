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

        It 'exports Invoke-Avm' {
            Get-Command -Module 'Avm.Authoring' -Name 'Invoke-Avm' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'exports the avm alias pointing at Invoke-Avm' {
            $alias = Get-Alias -Name 'avm' -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be 'Invoke-Avm'
        }

        It 'exports Get-AvmVersion' {
            Get-Command -Module 'Avm.Authoring' -Name 'Get-AvmVersion' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'exports Invoke-AvmDoctor' {
            Get-Command -Module 'Avm.Authoring' -Name 'Invoke-AvmDoctor' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'retains the Get-AvmAuthoringPlaceholder back-compat shim' {
            Get-Command -Module 'Avm.Authoring' -Name 'Get-AvmAuthoringPlaceholder' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'exports Get-AvmTool' {
            Get-Command -Module 'Avm.Authoring' -Name 'Get-AvmTool' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'exports Install-AvmTool' {
            Get-Command -Module 'Avm.Authoring' -Name 'Install-AvmTool' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'does not leak private helpers (Get-AvmFolder is module-private)' {
            Get-Command -Module 'Avm.Authoring' -Name 'Get-AvmFolder' -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }

        It 'does not leak private helpers (Invoke-AvmHttp is module-private)' {
            Get-Command -Module 'Avm.Authoring' -Name 'Invoke-AvmHttp' -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }

        It 'does not leak private helpers (Test-AvmToolsLock is module-private)' {
            Get-Command -Module 'Avm.Authoring' -Name 'Test-AvmToolsLock' -ErrorAction SilentlyContinue |
                Should -BeNullOrEmpty
        }
    }
}
