#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    $script:fixtureDir = Join-Path $TestDrive 'fixture'
    New-Item -ItemType Directory -Path $script:fixtureDir | Out-Null
    $script:payload = Join-Path $script:fixtureDir 'fake-tool-1.0.0.bin'
    Set-Content -LiteralPath $script:payload -Value 'fake-tool-payload-v2' -NoNewline -Encoding utf8
    $script:sha = (Get-FileHash -LiteralPath $script:payload -Algorithm SHA256).Hash.ToLowerInvariant()
    $urlPath = ($script:payload -replace '\\', '/')
    if ($urlPath -notmatch '^/') { $urlPath = '/' + $urlPath }
    $script:fileUrl = "file://$urlPath"

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

Describe 'Install-AvmTool' {
    BeforeEach {
        # Fresh sandbox per test so cache state is deterministic.
        $script:sandbox = Join-Path $TestDrive ("avmhome-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:AVM_HOME = $script:sandbox
    }

    It 'downloads, verifies, and writes the entrypoint under Tools/name/version/' {
        $result = Install-AvmTool -PinsPath $script:pinsPath -AllowFileUrls
        $result.Action | Should -Be 'installed'
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $expectedName = if ($IsWindows) { 'fake-tool.exe' } else { 'fake-tool' }
        (Split-Path -Leaf $result.Path) | Should -Be $expectedName
        (Split-Path -Leaf (Split-Path -Parent $result.Path)) | Should -Be '1.0.0'
    }

    It 'writes a .verified marker and a .meta.json' {
        $result = Install-AvmTool -PinsPath $script:pinsPath -AllowFileUrls
        $versionDir = Split-Path -Parent $result.Path
        Test-Path -LiteralPath (Join-Path $versionDir '.verified') | Should -BeTrue
        $metaPath = Join-Path $versionDir '.meta.json'
        Test-Path -LiteralPath $metaPath | Should -BeTrue
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        $meta.name | Should -Be 'fake-tool'
        $meta.version | Should -Be '1.0.0'
        $meta.sha256 | Should -Be $script:sha
    }

    It 'short-circuits to cache-hit on a second invocation' {
        Install-AvmTool -PinsPath $script:pinsPath -AllowFileUrls | Out-Null
        $second = Install-AvmTool -PinsPath $script:pinsPath -AllowFileUrls
        $second.Action | Should -Be 'cache-hit'
    }

    It 'reinstalls when -Force is set' {
        $first = Install-AvmTool -PinsPath $script:pinsPath -AllowFileUrls
        $first.Action | Should -Be 'installed'
        $forced = Install-AvmTool -Force -PinsPath $script:pinsPath -AllowFileUrls
        $forced.Action | Should -Be 'installed'
    }

    It 'throws ArgumentException for an unknown tool name' {
        { Install-AvmTool -Name 'no-such-tool' -PinsPath $script:pinsPath -AllowFileUrls } |
            Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'throws AvmToolException when the payload SHA256 has been tampered with' {
        $badPath = Join-Path $script:fixtureDir 'bad-pins.jsonc'
        $bogus = ('1' * 64)
        $badShaMap = [ordered]@{}
        foreach ($p in 'windows-amd64', 'windows-arm64', 'linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64') {
            $badShaMap[$p] = $bogus
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
        Set-Content -LiteralPath $badPath -Value ($badPins | ConvertTo-Json -Depth 8) -Encoding utf8
        $err = $null
        try { Install-AvmTool -PinsPath $badPath -AllowFileUrls } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
        $err.Code | Should -Be 'AVM1011'
    }

    It 'resolves {platform} via platformAliases when downloading' {
        # Build a lock that puts the file's basename behind a {platform}
        # placeholder. Only the current platform alias points at the real
        # file; every other alias points at a non-existent name. If install
        # succeeds, the substitution worked.
        $platform = InModuleScope 'Avm.Authoring' { Get-AvmToolPlatform }
        $realName = Split-Path -Leaf $script:payload
        $dirUrl = $script:fileUrl.Substring(0, $script:fileUrl.LastIndexOf('/'))
        $aliasMap = @{
            'windows-amd64' = 'missing.bin'
            'windows-arm64' = 'missing.bin'
            'linux-amd64'   = 'missing.bin'
            'linux-arm64'   = 'missing.bin'
            'darwin-amd64'  = 'missing.bin'
            'darwin-arm64'  = 'missing.bin'
        }
        $aliasMap[$platform] = $realName

        $shaMap = [ordered]@{}
        foreach ($p in 'windows-amd64', 'windows-arm64', 'linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64') {
            $shaMap[$p] = $script:sha
        }

        $platformLock = Join-Path $script:fixtureDir 'platform-pins.jsonc'
        $pins = [ordered]@{
            schemaVersion = 1
            tools         = @(
                [ordered]@{
                    name            = 'fake-tool'
                    version         = '1.0.0'
                    urlTemplate     = "$dirUrl/{platform}"
                    archive         = 'raw'
                    entrypoint      = 'fake-tool'
                    platformAliases = $aliasMap
                    sha256          = $shaMap
                }
            )
        }
        Set-Content -LiteralPath $platformLock -Value ($pins | ConvertTo-Json -Depth 8) -Encoding utf8

        $result = Install-AvmTool -PinsPath $platformLock -AllowFileUrls
        $result.Action | Should -Be 'installed'
        $result.Name | Should -Be 'fake-tool'
    }
}

Describe 'avm tool install dispatcher route' {
    BeforeEach {
        $script:sandbox = Join-Path $TestDrive ("avmhome-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:AVM_HOME = $script:sandbox
    }

    It 'routes "avm tool install" to Install-AvmTool' {
        $result = avm tool install --PinsPath $script:pinsPath --AllowFileUrls
        $result.Action | Should -Be 'installed'
        $result.Name | Should -Be 'fake-tool'
    }

    It 'routes "avm tool install NAME" with a positional tool name' {
        $result = avm tool install fake-tool --PinsPath $script:pinsPath --AllowFileUrls
        $result.Action | Should -Be 'installed'
        $result.Name | Should -Be 'fake-tool'
    }

    It 'routes "avm tool install --force NAME" and re-installs' {
        avm tool install --PinsPath $script:pinsPath --AllowFileUrls | Out-Null
        $result = avm tool install --force fake-tool --PinsPath $script:pinsPath --AllowFileUrls
        $result.Action | Should -Be 'installed'
    }
}
