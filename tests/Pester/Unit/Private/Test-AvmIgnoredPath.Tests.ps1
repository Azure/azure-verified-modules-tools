#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

Describe 'Test-AvmIgnoredPath' {
    It 'ignores <Relative>' -TestCases @(
        @{ Relative = '.terraform' }
        @{ Relative = '.terraform/modules/avm_interfaces' }
        @{ Relative = 'modules/slot/.terraform/modules/foo' }
        @{ Relative = '.git/objects' }
        @{ Relative = 'node_modules/pkg' }
        @{ Relative = 'examples/default/node_modules' }
    ) {
        param($Relative)
        $ignored = InModuleScope 'Avm.Authoring' -Parameters @{ P = $Relative } {
            param($P)
            Test-AvmIgnoredPath -Root '/repo' -Path (Join-Path '/repo' $P)
        }
        $ignored | Should -BeTrue
    }

    It 'does not ignore <Relative>' -TestCases @(
        @{ Relative = 'modules/slot' }
        @{ Relative = 'examples/default/main.tf' }
        @{ Relative = 'modules/terraform-things/main.tf' }
        @{ Relative = 'node_modules_helper' }
    ) {
        param($Relative)
        $ignored = InModuleScope 'Avm.Authoring' -Parameters @{ P = $Relative } {
            param($P)
            Test-AvmIgnoredPath -Root '/repo' -Path (Join-Path '/repo' $P)
        }
        $ignored | Should -BeFalse
    }

    It 'never ignores the root itself, even below a dot directory' {
        $ignored = InModuleScope 'Avm.Authoring' {
            $root = Join-Path (Join-Path '/repo' '.terraform') 'modules'
            Test-AvmIgnoredPath -Root $root -Path $root
        }
        $ignored | Should -BeFalse
    }
}

Describe 'Get-AvmDescendantDirectory' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
    }

    It 'returns an empty array for a path that does not exist' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ T = (Join-Path $script:root 'absent') } {
            param($T)
            Get-AvmDescendantDirectory -Root $T
        }
        @($result).Count | Should -Be 0
    }

    It 'walks nested directories but prunes ignored subtrees' {
        foreach ($dir in @(
                'slot',
                'slot/inner',
                'slot/.terraform/modules/avm_interfaces',
                '.terraform/providers'
            )) {
            New-Item -ItemType Directory -Path (Join-Path $script:root $dir) -Force | Out-Null
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ T = $script:root } {
            param($T)
            Get-AvmDescendantDirectory -Root $T
        }

        $relative = @($result | ForEach-Object {
                [System.IO.Path]::GetRelativePath($script:root, $_.FullName).Replace('\', '/')
            } | Sort-Object)
        $relative | Should -Be @('slot', 'slot/inner')
    }
}
