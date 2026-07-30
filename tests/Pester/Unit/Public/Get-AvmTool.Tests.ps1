#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    # Build a fixture lock with one fake tool that points at a payload we
    # write into $TestDrive. The lock uses file:// URLs so we never touch
    # the network during unit tests.
    $script:fixtureDir = Join-Path $TestDrive 'fixture'
    New-Item -ItemType Directory -Path $script:fixtureDir | Out-Null
    $script:payload = Join-Path $script:fixtureDir 'fake-tool-1.0.0.bin'
    Set-Content -LiteralPath $script:payload -Value 'fake-tool-payload' -NoNewline -Encoding utf8
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

    # Sandbox AVM_HOME so tool installs land under $TestDrive, not the real
    # %LOCALAPPDATA% / XDG / ~/Library tree.
    $script:savedAvmHome = if (Test-Path Env:\AVM_HOME) { $env:AVM_HOME } else { $null }
    $script:sandbox = Join-Path $TestDrive 'avmhome'
    New-Item -ItemType Directory -Path $script:sandbox | Out-Null
    $env:AVM_HOME = $script:sandbox

    # Auto-install is on by default; make sure a stray environment setting
    # cannot flip these tests into the disabled path.
    $script:savedNoAutoInstall = if (Test-Path Env:\AVM_NO_AUTO_INSTALL) { $env:AVM_NO_AUTO_INSTALL } else { $null }
    Remove-Item Env:\AVM_NO_AUTO_INSTALL -ErrorAction SilentlyContinue
}

AfterAll {
    if ($null -eq $script:savedAvmHome) { Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue }
    else { $env:AVM_HOME = $script:savedAvmHome }
    if ($null -eq $script:savedNoAutoInstall) { Remove-Item Env:\AVM_NO_AUTO_INSTALL -ErrorAction SilentlyContinue }
    else { $env:AVM_NO_AUTO_INSTALL = $script:savedNoAutoInstall }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmTool' {
    Context 'list mode (no -Name)' {
        It 'returns one pscustomobject per tool in the lock' {
            $rows = @(Get-AvmTool -PinsPath $script:pinsPath -AllowFileUrls)
            $rows.Count | Should -Be 1
            $rows[0].Name | Should -Be 'fake-tool'
            $rows[0].Version | Should -Be '1.0.0'
        }

        It 'reports Status=not-installed before install (auto-install pending, no PATH probe)' {
            # Use a sandbox specific to this test so other tests cannot affect us.
            $miniSandbox = Join-Path $TestDrive 'mini'
            New-Item -ItemType Directory -Path $miniSandbox -Force | Out-Null
            $prev = $env:AVM_HOME
            $env:AVM_HOME = $miniSandbox
            try {
                $rows = @(Get-AvmTool -PinsPath $script:pinsPath -AllowFileUrls)
                $rows[0].Status | Should -Be 'not-installed'
                $rows[0].Path | Should -BeNullOrEmpty
                $rows[0].Source | Should -BeNullOrEmpty
            }
            finally {
                $env:AVM_HOME = $prev
            }
        }

        It 'reports Status=auto-install-disabled when AVM_NO_AUTO_INSTALL is set' {
            $miniSandbox = Join-Path $TestDrive 'mini-disabled'
            New-Item -ItemType Directory -Path $miniSandbox -Force | Out-Null
            $prevHome = $env:AVM_HOME
            $env:AVM_HOME = $miniSandbox
            $env:AVM_NO_AUTO_INSTALL = '1'
            try {
                $rows = @(Get-AvmTool -PinsPath $script:pinsPath -AllowFileUrls)
                $rows[0].Status | Should -Be 'auto-install-disabled'
                $rows[0].Path | Should -BeNullOrEmpty
                $rows[0].Source | Should -BeNullOrEmpty
            }
            finally {
                $env:AVM_HOME = $prevHome
                Remove-Item Env:\AVM_NO_AUTO_INSTALL -ErrorAction SilentlyContinue
            }
        }

        It 'reports Status=installed and a real Path after install' {
            Install-AvmTool -PinsPath $script:pinsPath -AllowFileUrls | Out-Null
            $rows = @(Get-AvmTool -PinsPath $script:pinsPath -AllowFileUrls)
            $rows[0].Status | Should -Be 'installed'
            $rows[0].Source | Should -Be 'cache'
            $rows[0].Path | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $rows[0].Path | Should -BeTrue
        }
    }

    Context 'which mode (-Name)' {
        It 'returns only the requested tool' {
            $row = Get-AvmTool -Name 'fake-tool' -PinsPath $script:pinsPath -AllowFileUrls
            $row.Name | Should -Be 'fake-tool'
        }

        It 'throws ArgumentException for an unknown tool name' {
            { Get-AvmTool -Name 'no-such-tool' -PinsPath $script:pinsPath -AllowFileUrls } |
                Should -Throw -ExceptionType ([System.ArgumentException])
        }
    }
}

Describe 'avm tool dispatcher routes' {
    It 'routes "avm tool list" to Get-AvmTool' {
        $rows = @(avm tool list --PinsPath $script:pinsPath --AllowFileUrls)
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'fake-tool'
    }

    It 'routes "avm tool which NAME" to Get-AvmTool -Name' {
        $row = avm tool which fake-tool --PinsPath $script:pinsPath --AllowFileUrls
        $row.Name | Should -Be 'fake-tool'
    }

    It 'accepts kebab-case flags ("--allow-path-fallback" -> "AllowPathFallback")' {
        $rows = @(avm tool list --pins-path $script:pinsPath --allow-file-urls --allow-path-fallback)
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'fake-tool'
    }
}
