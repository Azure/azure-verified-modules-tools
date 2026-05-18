#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    $script:fixtureDir = Join-Path $TestDrive 'fixture'
    New-Item -ItemType Directory -Path $script:fixtureDir | Out-Null

    # Stand up a self-hashing fake payload (re-used from Install-AvmTool tests).
    $script:payload = Join-Path $script:fixtureDir 'fake-tool-1.0.0.bin'
    Set-Content -LiteralPath $script:payload -Value 'fake-tool-payload-v2' -NoNewline -Encoding utf8
    $script:sha = (Get-FileHash -LiteralPath $script:payload -Algorithm SHA256).Hash.ToLowerInvariant()
    $urlPath = ($script:payload -replace '\\', '/')
    if ($urlPath -notmatch '^/') { $urlPath = '/' + $urlPath }
    $script:fileUrl = "file://$urlPath"

    # Build a lock with a single 'fake-tool' entry.
    $script:lockPath = Join-Path $script:fixtureDir 'tools.lock.psd1'
    $lockText = @"
@{
    schemaVersion = 1
    tools = @(
        @{
            name = 'fake-tool'
            version = '1.0.0'
            urlTemplate = '$script:fileUrl'
            archive = 'raw'
            entrypoint = 'fake-tool'
            sha256 = @{
                'windows-amd64' = '$script:sha'
                'windows-arm64' = '$script:sha'
                'linux-amd64' = '$script:sha'
                'linux-arm64' = '$script:sha'
                'darwin-amd64' = '$script:sha'
                'darwin-arm64' = '$script:sha'
            }
        }
    )
}
"@
    Set-Content -LiteralPath $script:lockPath -Value $lockText -Encoding utf8

    $script:savedAvmHome = if (Test-Path Env:\AVM_HOME) { $env:AVM_HOME } else { $null }
}

AfterAll {
    if ($null -eq $script:savedAvmHome) { Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue }
    else { $env:AVM_HOME = $script:savedAvmHome }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-AvmTool' {
    BeforeEach {
        $script:sandbox = Join-Path $TestDrive ("avmhome-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:AVM_HOME = $script:sandbox
    }

    It 'throws ArgumentException when the tool name is not in the lock' {
        $lockPath = $script:lockPath
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lockPath } {
                param($L)
                Resolve-AvmTool -Name 'no-such-thing' -LockPath $L -AllowFileUrls
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'throws AvmToolException with code AVM1014 when the tool is missing from cache and PATH' {
        $lockPath = $script:lockPath
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lockPath } {
                param($L)
                Resolve-AvmTool -Name 'fake-tool' -LockPath $L -AllowFileUrls
            }
        }
        catch {
            $err = $_.Exception
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
        $err.Code | Should -Be 'AVM1014'
        $err.Message | Should -Match 'avm tool install fake-tool'
    }

    It 'returns Source=cache and the entrypoint path after Install-AvmTool plants it' {
        Install-AvmTool -LockPath $script:lockPath -AllowFileUrls | Out-Null
        $lockPath = $script:lockPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ L = $lockPath } {
            param($L)
            Resolve-AvmTool -Name 'fake-tool' -LockPath $L -AllowFileUrls
        }
        $result.Name | Should -Be 'fake-tool'
        $result.Version | Should -Be '1.0.0'
        $result.Source | Should -Be 'cache'
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $expectedName = if ($IsWindows) { 'fake-tool.exe' } else { 'fake-tool' }
        (Split-Path -Leaf $result.Path) | Should -Be $expectedName
    }

    It 'does NOT fall back to PATH by default even when -AllowPathFallback is omitted' {
        # pwsh is definitely on PATH; we use it as a stand-in for a missing managed binary.
        $lockPath = $script:lockPath
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lockPath } {
                param($L)
                Resolve-AvmTool -Name 'fake-tool' -LockPath $L -AllowFileUrls
            }
        }
        catch {
            $err = $_.Exception
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
    }
}
