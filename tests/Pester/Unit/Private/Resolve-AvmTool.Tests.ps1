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
        Remove-Item Env:\AVM_NO_AUTO_INSTALL -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item Env:\AVM_NO_AUTO_INSTALL -ErrorAction SilentlyContinue
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

    It 'throws AvmToolException with code AVM1014 when missing and auto-install is disabled' {
        $lockPath = $script:lockPath
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $lockPath } {
                param($L)
                Resolve-AvmTool -Name 'fake-tool' -LockPath $L -AllowFileUrls -NoAutoInstall
            }
        }
        catch {
            $err = $_.Exception
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
        $err.Code | Should -Be 'AVM1014'
        $err.Message | Should -Match 'automatic installation is disabled'
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
                Resolve-AvmTool -Name 'fake-tool' -LockPath $L -AllowFileUrls -NoAutoInstall
            }
        }
        catch {
            $err = $_.Exception
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
    }

    It 'auto-installs a missing tool on demand and returns Source=installed' {
        $lockPath = $script:lockPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ L = $lockPath } {
            param($L)
            Resolve-AvmTool -Name 'fake-tool' -LockPath $L -AllowFileUrls
        }
        $result.Name | Should -Be 'fake-tool'
        $result.Version | Should -Be '1.0.0'
        $result.Source | Should -Be 'installed'
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        # The install must land under the isolated AVM_HOME sandbox, not a shared cache.
        $result.Path | Should -BeLike (Join-Path $script:sandbox '*')
    }

    It 'reuses the cache on a second resolve instead of reinstalling' {
        $lockPath = $script:lockPath
        $first = InModuleScope 'Avm.Authoring' -Parameters @{ L = $lockPath } {
            param($L)
            Resolve-AvmTool -Name 'fake-tool' -LockPath $L -AllowFileUrls
        }
        $second = InModuleScope 'Avm.Authoring' -Parameters @{ L = $lockPath } {
            param($L)
            Resolve-AvmTool -Name 'fake-tool' -LockPath $L -AllowFileUrls
        }
        $first.Source | Should -Be 'installed'
        $second.Source | Should -Be 'cache'
        $second.Path | Should -Be $first.Path
    }

    It 'honours AVM_NO_AUTO_INSTALL=1 and hard-fails without downloading' {
        $env:AVM_NO_AUTO_INSTALL = '1'
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
        $err.Message | Should -Match 'automatic installation is disabled'
        # Nothing should have been planted in the cache.
        $planted = Join-Path (Join-Path (Join-Path $script:sandbox 'tools') 'fake-tool') '1.0.0'
        (Test-Path -LiteralPath (Join-Path $planted '.verified')) | Should -BeFalse
    }

    It 'surfaces an installer failure when the payload hash does not match' {
        $badLock = Join-Path $script:sandbox 'bad.lock.psd1'
        $badSha = '0' * 64
        $badText = @"
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
                'windows-amd64' = '$badSha'
                'windows-arm64' = '$badSha'
                'linux-amd64' = '$badSha'
                'linux-arm64' = '$badSha'
                'darwin-amd64' = '$badSha'
                'darwin-arm64' = '$badSha'
            }
        }
    )
}
"@
        Set-Content -LiteralPath $badLock -Value $badText -Encoding utf8
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $badLock } {
                param($L)
                Resolve-AvmTool -Name 'fake-tool' -LockPath $L -AllowFileUrls
            }
        }
        catch {
            $err = $_.Exception
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
        # The failed download must not leave a verified marker behind.
        $planted = Join-Path (Join-Path (Join-Path $script:sandbox 'tools') 'fake-tool') '1.0.0'
        (Test-Path -LiteralPath (Join-Path $planted '.verified')) | Should -BeFalse
    }
}
