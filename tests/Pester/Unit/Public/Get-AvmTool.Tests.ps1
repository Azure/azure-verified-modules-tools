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

    $script:lockPath = Join-Path $script:fixtureDir 'tools.lock.psd1'
    $lockText = "@{`n    schemaVersion = 1`n    tools = @(`n        @{`n            name = 'fake-tool'`n            version = '1.0.0'`n            urlTemplate = '$script:fileUrl'`n            archive = 'raw'`n            entrypoint = 'fake-tool'`n            sha256 = @{`n                'windows-amd64' = '$script:sha'`n                'windows-arm64' = '$script:sha'`n                'linux-amd64' = '$script:sha'`n                'linux-arm64' = '$script:sha'`n                'darwin-amd64' = '$script:sha'`n                'darwin-arm64' = '$script:sha'`n            }`n        }`n    )`n}`n"
    Set-Content -LiteralPath $script:lockPath -Value $lockText -Encoding utf8

    # Sandbox AVM_HOME so tool installs land under $TestDrive, not the real
    # %LOCALAPPDATA% / XDG / ~/Library tree.
    $script:savedAvmHome = if (Test-Path Env:\AVM_HOME) { $env:AVM_HOME } else { $null }
    $script:sandbox = Join-Path $TestDrive 'avmhome'
    New-Item -ItemType Directory -Path $script:sandbox | Out-Null
    $env:AVM_HOME = $script:sandbox
}

AfterAll {
    if ($null -eq $script:savedAvmHome) { Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue }
    else { $env:AVM_HOME = $script:savedAvmHome }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmTool' {
    Context 'list mode (no -Name)' {
        It 'returns one pscustomobject per tool in the lock' {
            $rows = @(Get-AvmTool -LockPath $script:lockPath -AllowFileUrls)
            $rows.Count | Should -Be 1
            $rows[0].Name | Should -Be 'fake-tool'
            $rows[0].Version | Should -Be '1.0.0'
        }

        It 'reports Status=missing before install (no PATH fallback)' {
            # Use a sandbox specific to this test so other tests cannot affect us.
            $miniSandbox = Join-Path $TestDrive 'mini'
            New-Item -ItemType Directory -Path $miniSandbox -Force | Out-Null
            $prev = $env:AVM_HOME
            $env:AVM_HOME = $miniSandbox
            try {
                $rows = @(Get-AvmTool -LockPath $script:lockPath -AllowFileUrls -NoPathFallback)
                $rows[0].Status | Should -Be 'missing'
                $rows[0].Path | Should -BeNullOrEmpty
                $rows[0].Source | Should -BeNullOrEmpty
            }
            finally {
                $env:AVM_HOME = $prev
            }
        }

        It 'reports Status=installed and a real Path after install' {
            Install-AvmTool -LockPath $script:lockPath -AllowFileUrls | Out-Null
            $rows = @(Get-AvmTool -LockPath $script:lockPath -AllowFileUrls)
            $rows[0].Status | Should -Be 'installed'
            $rows[0].Source | Should -Be 'cache'
            $rows[0].Path | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $rows[0].Path | Should -BeTrue
        }
    }

    Context 'which mode (-Name)' {
        It 'returns only the requested tool' {
            $row = Get-AvmTool -Name 'fake-tool' -LockPath $script:lockPath -AllowFileUrls
            $row.Name | Should -Be 'fake-tool'
        }

        It 'throws ArgumentException for an unknown tool name' {
            { Get-AvmTool -Name 'no-such-tool' -LockPath $script:lockPath -AllowFileUrls } |
                Should -Throw -ExceptionType ([System.ArgumentException])
        }
    }
}

Describe 'avm tool dispatcher routes' {
    It 'routes "avm tool list" to Get-AvmTool' {
        $rows = @(avm tool list --LockPath $script:lockPath --AllowFileUrls --NoPathFallback)
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'fake-tool'
    }

    It 'routes "avm tool which NAME" to Get-AvmTool -Name' {
        $row = avm tool which fake-tool --LockPath $script:lockPath --AllowFileUrls --NoPathFallback
        $row.Name | Should -Be 'fake-tool'
    }

    It 'accepts kebab-case flags ("--no-path-fallback" -> "NoPathFallback")' {
        $rows = @(avm tool list --lock-path $script:lockPath --allow-file-urls --no-path-fallback)
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'fake-tool'
    }
}
