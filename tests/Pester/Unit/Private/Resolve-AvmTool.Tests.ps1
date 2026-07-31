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

    # Build a pin manifest with a single 'fake-tool' entry.
    $script:pinsPath = Join-Path $script:fixtureDir 'avm.pins.jsonc'
    $shaMap = [ordered]@{}
    foreach ($p in 'windows-amd64', 'windows-arm64', 'linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64') {
        $shaMap[$p] = $script:sha
    }
    $pins = [ordered]@{
        schemaVersion = 1
        tools         = @(
            [ordered]@{
                name        = 'fake-tool'
                version     = '1.0.0'
                urlTemplate = $script:fileUrl
                archive     = 'raw'
                entrypoint  = 'fake-tool'
                sha256      = $shaMap
            }
        )
    }
    Set-Content -LiteralPath $script:pinsPath -Value ($pins | ConvertTo-Json -Depth 8) -Encoding utf8

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
        $pinsPath = $script:pinsPath
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pinsPath } {
                param($L)
                Resolve-AvmTool -Name 'no-such-thing' -PinsPath $L -AllowFileUrls
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'throws AvmToolException with code AVM1014 when missing and auto-install is disabled' {
        $pinsPath = $script:pinsPath
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pinsPath } {
                param($L)
                Resolve-AvmTool -Name 'fake-tool' -PinsPath $L -AllowFileUrls -NoAutoInstall
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
        Install-AvmTool -PinsPath $script:pinsPath -AllowFileUrls | Out-Null
        $pinsPath = $script:pinsPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ L = $pinsPath } {
            param($L)
            Resolve-AvmTool -Name 'fake-tool' -PinsPath $L -AllowFileUrls
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
        $pinsPath = $script:pinsPath
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pinsPath } {
                param($L)
                Resolve-AvmTool -Name 'fake-tool' -PinsPath $L -AllowFileUrls -NoAutoInstall
            }
        }
        catch {
            $err = $_.Exception
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
    }

    It 'auto-installs a missing tool on demand and returns Source=installed' {
        $pinsPath = $script:pinsPath
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ L = $pinsPath } {
            param($L)
            Resolve-AvmTool -Name 'fake-tool' -PinsPath $L -AllowFileUrls
        }
        $result.Name | Should -Be 'fake-tool'
        $result.Version | Should -Be '1.0.0'
        $result.Source | Should -Be 'installed'
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        # The install must land under the isolated AVM_HOME sandbox, not a shared cache.
        $result.Path | Should -BeLike (Join-Path $script:sandbox '*')
    }

    It 'reuses the cache on a second resolve instead of reinstalling' {
        $pinsPath = $script:pinsPath
        $first = InModuleScope 'Avm.Authoring' -Parameters @{ L = $pinsPath } {
            param($L)
            Resolve-AvmTool -Name 'fake-tool' -PinsPath $L -AllowFileUrls
        }
        $second = InModuleScope 'Avm.Authoring' -Parameters @{ L = $pinsPath } {
            param($L)
            Resolve-AvmTool -Name 'fake-tool' -PinsPath $L -AllowFileUrls
        }
        $first.Source | Should -Be 'installed'
        $second.Source | Should -Be 'cache'
        $second.Path | Should -Be $first.Path
    }

    It 'honours AVM_NO_AUTO_INSTALL=1 and hard-fails without downloading' {
        $env:AVM_NO_AUTO_INSTALL = '1'
        $pinsPath = $script:pinsPath
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $pinsPath } {
                param($L)
                Resolve-AvmTool -Name 'fake-tool' -PinsPath $L -AllowFileUrls
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
        $badLock = Join-Path $script:sandbox 'bad.pins.jsonc'
        $badSha = '0' * 64
        $badShaMap = [ordered]@{}
        foreach ($p in 'windows-amd64', 'windows-arm64', 'linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64') {
            $badShaMap[$p] = $badSha
        }
        $badPins = [ordered]@{
            schemaVersion = 1
            tools         = @(
                [ordered]@{
                    name        = 'fake-tool'
                    version     = '1.0.0'
                    urlTemplate = $script:fileUrl
                    archive     = 'raw'
                    entrypoint  = 'fake-tool'
                    sha256      = $badShaMap
                }
            )
        }
        Set-Content -LiteralPath $badLock -Value ($badPins | ConvertTo-Json -Depth 8) -Encoding utf8
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ L = $badLock } {
                param($L)
                Resolve-AvmTool -Name 'fake-tool' -PinsPath $L -AllowFileUrls
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
