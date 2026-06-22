#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmToolPlatform' {
    It 'returns a string of the form OS-ARCH' {
        $tag = InModuleScope 'Avm.Authoring' { Get-AvmToolPlatform }
        $tag | Should -Match '^(windows|linux|darwin)-(amd64|arm64)$'
    }

    It 'reports the correct OS for the host' {
        $tag = InModuleScope 'Avm.Authoring' { Get-AvmToolPlatform }
        $os = $tag.Split('-', 2)[0]
        if ($IsWindows) { $os | Should -Be 'windows' }
        elseif ($IsLinux) { $os | Should -Be 'linux' }
        elseif ($IsMacOS) { $os | Should -Be 'darwin' }
    }

    It 'reports an architecture that matches the runtime' {
        $tag = InModuleScope 'Avm.Authoring' { Get-AvmToolPlatform }
        $arch = $tag.Split('-', 2)[1]
        $runtime = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
        if ($runtime -eq 'x64') { $arch | Should -Be 'amd64' }
        elseif ($runtime -eq 'arm64') { $arch | Should -Be 'arm64' }
    }
}
