#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Get-AvmFolder' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:hadAvmHome = Test-Path Env:\AVM_HOME
        $script:savedAvmHome = if ($script:hadAvmHome) { $env:AVM_HOME } else { $null }
    }

    AfterEach {
        if ($script:hadAvmHome) {
            $env:AVM_HOME = $script:savedAvmHome
        }
        else {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }
    }

    Context 'AVM_HOME override' {
        BeforeEach {
            $script:tempHome = Join-Path ([System.IO.Path]::GetTempPath()) "avm-test-$([guid]::NewGuid().Guid)"
            $env:AVM_HOME = $script:tempHome
        }

        AfterEach {
            if (Test-Path -LiteralPath $script:tempHome) {
                Remove-Item -LiteralPath $script:tempHome -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'places <Kind> under $AVM_HOME/<segment>' -ForEach @(
            @{ Kind = 'Config'; Segment = 'config' }
            @{ Kind = 'Cache';  Segment = 'cache' }
            @{ Kind = 'Data';   Segment = 'data' }
            @{ Kind = 'State';  Segment = 'state' }
            @{ Kind = 'Tools';  Segment = 'tools' }
            @{ Kind = 'Logs';   Segment = 'logs' }
        ) {
            $path = InModuleScope 'Avm.Authoring' -Parameters @{ K = $Kind } { param($K) Get-AvmFolder -Kind $K }
            $expected = Join-Path $script:tempHome $Segment
            $path | Should -Be $expected
        }

        It 'creates the directory by default' {
            $path = InModuleScope 'Avm.Authoring' { Get-AvmFolder -Kind Config }
            Test-Path -LiteralPath $path | Should -BeTrue
        }

        It 'does not create the directory when -NoCreate is set' {
            $path = InModuleScope 'Avm.Authoring' { Get-AvmFolder -Kind Logs -NoCreate }
            Test-Path -LiteralPath $path | Should -BeFalse
        }

        It 'returns an absolute path' {
            $path = InModuleScope 'Avm.Authoring' { Get-AvmFolder -Kind Cache }
            [System.IO.Path]::IsPathRooted($path) | Should -BeTrue
        }
    }

    Context 'Temp folder' {
        BeforeEach {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }

        It 'returns [System.IO.Path]::GetTempPath()' {
            $path = InModuleScope 'Avm.Authoring' { Get-AvmFolder -Kind Temp }
            $path | Should -Be ([System.IO.Path]::GetTempPath())
        }
    }

    Context 'OS-default folders (without AVM_HOME)' {
        BeforeEach {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }

        It 'returns an absolute path' {
            $path = InModuleScope 'Avm.Authoring' { Get-AvmFolder -Kind Config -NoCreate }
            [System.IO.Path]::IsPathRooted($path) | Should -BeTrue
        }

        It 'on Windows, Config is rooted at %APPDATA%' -Skip:(-not $IsWindows) {
            $path = InModuleScope 'Avm.Authoring' { Get-AvmFolder -Kind Config -NoCreate }
            $expected = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Avm'
            $path | Should -Be $expected
        }

        It 'on Windows, Cache is under %LOCALAPPDATA%\Avm\Cache' -Skip:(-not $IsWindows) {
            $path = InModuleScope 'Avm.Authoring' { Get-AvmFolder -Kind Cache -NoCreate }
            $expected = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Avm') 'Cache'
            $path | Should -Be $expected
        }

        It 'on Linux, Config is under ${XDG_CONFIG_HOME:-~/.config}/avm' -Skip:(-not $IsLinux) {
            $path = InModuleScope 'Avm.Authoring' { Get-AvmFolder -Kind Config -NoCreate }
            $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
            $path | Should -Be (Join-Path $base 'avm')
        }

        It 'on macOS, Config is under ~/Library/Application Support/Avm' -Skip:(-not $IsMacOS) {
            $path = InModuleScope 'Avm.Authoring' { Get-AvmFolder -Kind Config -NoCreate }
            $expected = Join-Path (Join-Path (Join-Path $HOME 'Library') 'Application Support') 'Avm'
            $path | Should -Be $expected
        }
    }
}
