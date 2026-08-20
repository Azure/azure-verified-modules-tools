#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    $script:savedAvmHome = $env:AVM_HOME
    $script:savedOffline = $env:AVM_OFFLINE

    function script:New-SnapshotPin {
        param(
            [string] $Url,
            [string] $Sha256,
            [bool] $Enabled = $true,
            [bool] $Placeholder = $false
        )

        return @{
            schemaVersion = 1
            tools = @()
            tflintAvmSchemaSnapshot = @{
                enabled = $Enabled
                placeholder = $Placeholder
                version = '1.2.3'
                url = $Url
                sha256 = $Sha256
            }
        }
    }

    function script:New-SnapshotFixture {
        param([string] $Root, [string] $Content = '{"resources":[]}')

        $path = Join-Path $Root ('snapshot-' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($false))
        $uriPath = ($path -replace '\\', '/')
        if ($uriPath -notmatch '^/') { $uriPath = '/' + $uriPath }
        return [pscustomobject]@{
            Path = $path
            Url = "file://$uriPath"
            Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}

AfterAll {
    $env:AVM_HOME = $script:savedAvmHome
    $env:AVM_OFFLINE = $script:savedOffline
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-AvmTflintAvmSchemaSnapshot' {
    BeforeEach {
        $script:avmHomeDir = Join-Path $TestDrive ('avm-home-' + [guid]::NewGuid().ToString('N'))
        $script:work = Join-Path $TestDrive ('snapshot-work-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:avmHomeDir, $script:work -Force | Out-Null
        $env:AVM_HOME = $script:avmHomeDir
        Remove-Item Env:\AVM_OFFLINE -ErrorAction SilentlyContinue
    }

    It 'does not resolve a disabled placeholder pin' {
        $pins = script:New-SnapshotPin -Url 'https://example.invalid/snapshot.json' -Sha256 ('0' * 64) -Enabled $false -Placeholder $true
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $pins } {
            param($P)
            Resolve-AvmTflintAvmSchemaSnapshot -Pins $P
        }

        $result | Should -BeNullOrEmpty
        Join-Path $script:avmHomeDir 'cache/tflint-avm-schema' | Should -Not -Exist
    }

    It 'downloads, verifies, and atomically installs the exact snapshot on a cache miss' {
        $fixture = script:New-SnapshotFixture -Root $script:work
        $pins = script:New-SnapshotPin -Url $fixture.Url -Sha256 $fixture.Sha256
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $pins } {
            param($P)
            Resolve-AvmTflintAvmSchemaSnapshot -Pins $P
        }

        $result.Action | Should -Be 'installed'
        (Split-Path -Leaf (Split-Path -Parent $result.Path)) | Should -Be $fixture.Sha256
        $result.Path | Should -Exist
        Join-Path (Split-Path -Parent $result.Path) '.verified' | Should -Exist
        Join-Path (Split-Path -Parent $result.Path) '.meta.json' | Should -Exist
    }

    It 'uses only the exact checksum cache entry and never an older snapshot' {
        $fixture = script:New-SnapshotFixture -Root $script:work
        $pins = script:New-SnapshotPin -Url $fixture.Url -Sha256 $fixture.Sha256
        InModuleScope 'Avm.Authoring' -Parameters @{ P = $pins } {
            param($P)
            Resolve-AvmTflintAvmSchemaSnapshot -Pins $P | Out-Null
        }
        Remove-Item -LiteralPath $fixture.Path -Force

        $hit = InModuleScope 'Avm.Authoring' -Parameters @{ P = $pins } {
            param($P)
            Resolve-AvmTflintAvmSchemaSnapshot -Pins $P
        }
        $hit.Action | Should -Be 'cache-hit'

        $newPins = script:New-SnapshotPin -Url 'https://example.invalid/new-snapshot.json' -Sha256 ('f' * 64)
        $env:AVM_OFFLINE = '1'
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $newPins } {
                param($P)
                Resolve-AvmTflintAvmSchemaSnapshot -Pins $P
            }
        } | Should -Throw '*Preload the exact pin*'
    }

    It 'fails before TFLint on checksum mismatch and leaves no verified cache entry' {
        $fixture = script:New-SnapshotFixture -Root $script:work
        $pins = script:New-SnapshotPin -Url $fixture.Url -Sha256 ('0' * 64)

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $pins } {
                param($P)
                Resolve-AvmTflintAvmSchemaSnapshot -Pins $P
            }
        } | Should -Throw '*could not be verified*'
        Join-Path $script:avmHomeDir ('cache/tflint-avm-schema/' + ('0' * 64) + '/.verified') | Should -Not -Exist
    }

    It 'reports offline cache misses with exact preload instructions' {
        $env:AVM_OFFLINE = '1'
        $pins = script:New-SnapshotPin -Url 'https://example.invalid/snapshot.json' -Sha256 ('a' * 64)

        {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $pins } {
                param($P)
                Resolve-AvmTflintAvmSchemaSnapshot -Pins $P
            }
        } | Should -Throw '*Preload the exact pin*'
    }

    It 'uses the cache lock and cleans its staging directory after an atomic install' {
        $fixture = script:New-SnapshotFixture -Root $script:work
        $pins = script:New-SnapshotPin -Url $fixture.Url -Sha256 $fixture.Sha256
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ P = $pins } {
            param($P)
            Mock Lock-AvmToolCache {
                [System.IO.File]::Open(
                    $LockFile,
                    [System.IO.FileMode]::OpenOrCreate,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None)
            }
            $result = Resolve-AvmTflintAvmSchemaSnapshot -Pins $P
            $assetRoot = Join-Path (Get-AvmFolder -Kind Cache) 'tflint-avm-schema'
            Should -Invoke Lock-AvmToolCache -Exactly 1 -ParameterFilter {
                $LockFile -eq (Join-Path $assetRoot '.lock')
            }
            [pscustomobject]@{
                Result = $result
                LockExists = Test-Path -LiteralPath (Join-Path $assetRoot '.lock')
                StagingCount = @(Get-ChildItem -LiteralPath (Join-Path $assetRoot '.staging') -Force).Count
            }
        }

        $probe.Result.Action | Should -Be 'installed'
        $probe.LockExists | Should -BeTrue
        $probe.StagingCount | Should -Be 0
    }
}
