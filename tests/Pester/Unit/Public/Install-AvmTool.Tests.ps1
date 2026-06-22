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

    $script:lockPath = Join-Path $script:fixtureDir 'tools.lock.psd1'
    $lockText = "@{`n    schemaVersion = 1`n    tools = @(`n        @{`n            name = 'fake-tool'`n            version = '1.0.0'`n            urlTemplate = '$script:fileUrl'`n            archive = 'raw'`n            entrypoint = 'fake-tool'`n            sha256 = @{`n                'windows-amd64' = '$script:sha'`n                'windows-arm64' = '$script:sha'`n                'linux-amd64' = '$script:sha'`n                'linux-arm64' = '$script:sha'`n                'darwin-amd64' = '$script:sha'`n                'darwin-arm64' = '$script:sha'`n            }`n        }`n    )`n}`n"
    Set-Content -LiteralPath $script:lockPath -Value $lockText -Encoding utf8

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
        $result = Install-AvmTool -LockPath $script:lockPath -AllowFileUrls
        $result.Action | Should -Be 'installed'
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $expectedName = if ($IsWindows) { 'fake-tool.exe' } else { 'fake-tool' }
        (Split-Path -Leaf $result.Path) | Should -Be $expectedName
        (Split-Path -Leaf (Split-Path -Parent $result.Path)) | Should -Be '1.0.0'
    }

    It 'writes a .verified marker and a .meta.json' {
        $result = Install-AvmTool -LockPath $script:lockPath -AllowFileUrls
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
        Install-AvmTool -LockPath $script:lockPath -AllowFileUrls | Out-Null
        $second = Install-AvmTool -LockPath $script:lockPath -AllowFileUrls
        $second.Action | Should -Be 'cache-hit'
    }

    It 'reinstalls when -Force is set' {
        $first = Install-AvmTool -LockPath $script:lockPath -AllowFileUrls
        $first.Action | Should -Be 'installed'
        $forced = Install-AvmTool -Force -LockPath $script:lockPath -AllowFileUrls
        $forced.Action | Should -Be 'installed'
    }

    It 'throws ArgumentException for an unknown tool name' {
        { Install-AvmTool -Name 'no-such-tool' -LockPath $script:lockPath -AllowFileUrls } |
            Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'throws AvmToolException when the payload SHA256 has been tampered with' {
        $badPath = Join-Path $script:fixtureDir 'bad-lock.psd1'
        $bogus = ('1' * 64)
        $badText = "@{`n    schemaVersion = 1`n    tools = @(`n        @{`n            name = 'fake-tool'`n            version = '1.0.0'`n            urlTemplate = '$script:fileUrl'`n            archive = 'raw'`n            entrypoint = 'fake-tool'`n            sha256 = @{`n                'windows-amd64' = '$bogus'`n                'windows-arm64' = '$bogus'`n                'linux-amd64' = '$bogus'`n                'linux-arm64' = '$bogus'`n                'darwin-amd64' = '$bogus'`n                'darwin-arm64' = '$bogus'`n            }`n        }`n    )`n}`n"
        Set-Content -LiteralPath $badPath -Value $badText -Encoding utf8
        $err = $null
        try { Install-AvmTool -LockPath $badPath -AllowFileUrls } catch { $err = $_.Exception }
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

        $aliasBody = ($aliasMap.GetEnumerator() | Sort-Object Key |
            ForEach-Object { "                '$($_.Key)' = '$($_.Value)'" }) -join "`n"
        $shaBody = @(
            "                'windows-amd64' = '$script:sha'"
            "                'windows-arm64' = '$script:sha'"
            "                'linux-amd64' = '$script:sha'"
            "                'linux-arm64' = '$script:sha'"
            "                'darwin-amd64' = '$script:sha'"
            "                'darwin-arm64' = '$script:sha'"
        ) -join "`n"

        $platformLock = Join-Path $script:fixtureDir 'platform-lock.psd1'
        $lockText = @"
@{
    schemaVersion = 1
    tools = @(
        @{
            name = 'fake-tool'
            version = '1.0.0'
            urlTemplate = '$dirUrl/{platform}'
            archive = 'raw'
            entrypoint = 'fake-tool'
            platformAliases = @{
$aliasBody
            }
            sha256 = @{
$shaBody
            }
        }
    )
}
"@
        Set-Content -LiteralPath $platformLock -Value $lockText -Encoding utf8

        $result = Install-AvmTool -LockPath $platformLock -AllowFileUrls
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
        $result = avm tool install --LockPath $script:lockPath --AllowFileUrls
        $result.Action | Should -Be 'installed'
        $result.Name | Should -Be 'fake-tool'
    }

    It 'routes "avm tool install NAME" with a positional tool name' {
        $result = avm tool install fake-tool --LockPath $script:lockPath --AllowFileUrls
        $result.Action | Should -Be 'installed'
        $result.Name | Should -Be 'fake-tool'
    }

    It 'routes "avm tool install --force NAME" and re-installs' {
        avm tool install --LockPath $script:lockPath --AllowFileUrls | Out-Null
        $result = avm tool install --force fake-tool --LockPath $script:lockPath --AllowFileUrls
        $result.Action | Should -Be 'installed'
    }
}
