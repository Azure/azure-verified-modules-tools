#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    $script:savedAvmHome = if (Test-Path Env:\AVM_HOME) { $env:AVM_HOME } else { $null }
    $script:tempRoot = Join-Path $TestDrive 'resolver-asset'
    New-Item -ItemType Directory -Path $script:tempRoot -Force | Out-Null

    # Helper: build a ZIP archive containing a known directory layout, return
    # @{ Path; Sha256; Url } where Url is a file:// pointer suitable for
    # Resolve-AvmPinnedAsset -AllowFileUrls.
    function script:New-ZipFixture {
        param(
            [Parameter(Mandatory)] [string] $WorkDir,
            [Parameter(Mandatory)] [string] $ArchiveName,
            [string] $TopDir = 'policies',
            [hashtable] $Files = @{ 'sample.rego' = 'package sample' }
        )

        $stage = Join-Path $WorkDir ("zipstage-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $topDirAbs = Join-Path $stage $TopDir
        New-Item -ItemType Directory -Path $topDirAbs -Force | Out-Null
        foreach ($kv in $Files.GetEnumerator()) {
            $dest = Join-Path $topDirAbs $kv.Key
            $destParent = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destParent)) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }
            Set-Content -LiteralPath $dest -Value $kv.Value -Encoding utf8 -NoNewline
        }

        $archivePath = Join-Path $WorkDir $ArchiveName
        if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $archivePath)
        Remove-Item -LiteralPath $stage -Recurse -Force

        $sha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $urlPath = ($archivePath -replace '\\', '/')
        if ($urlPath -notmatch '^/') { $urlPath = '/' + $urlPath }
        $url = "file://$urlPath"

        return [pscustomobject]@{
            Path   = $archivePath
            Sha256 = $sha
            Url    = $url
        }
    }
}

AfterAll {
    if ($null -eq $script:savedAvmHome) { Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue }
    else { $env:AVM_HOME = $script:savedAvmHome }
    if (Test-Path -LiteralPath $script:tempRoot) {
        Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-AvmPinnedAsset cold and warm cache' {
    BeforeEach {
        $script:sandbox = Join-Path $TestDrive ("avmhome-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:AVM_HOME = $script:sandbox

        $script:workDir = Join-Path $TestDrive ("work-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null
    }

    It 'downloads, extracts, and writes verified marker on cold cache' {
        $zip = script:New-ZipFixture -WorkDir $script:workDir -ArchiveName 'aprl.zip'
        $asset = [pscustomobject]@{
            Source = $zip.Url
            Sha256 = $zip.Sha256
            Ref    = $null
            Path   = $null
            Type   = $null
        }

        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls
        }

        $result.Action | Should -Be 'installed'
        $result.Name | Should -Be 'aprl'
        $result.Sha256 | Should -Be $zip.Sha256
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.Path '.verified') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.Path '.meta.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.Path 'policies/sample.rego') | Should -BeTrue
    }

    It 'short-circuits to cache-hit on a second invocation' {
        $zip = script:New-ZipFixture -WorkDir $script:workDir -ArchiveName 'aprl.zip'
        $asset = [pscustomobject]@{
            Source = $zip.Url
            Sha256 = $zip.Sha256
            Ref    = $null
            Path   = $null
            Type   = $null
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls | Out-Null
        }

        # Delete the fixture archive so any actual download would fail; a real
        # cache-hit must succeed without touching the source.
        Remove-Item -LiteralPath $zip.Path -Force

        $second = InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls
        }
        $second.Action | Should -Be 'cache-hit'
        Test-Path -LiteralPath $second.Path | Should -BeTrue
    }

    It 'reinstalls when -Force is set' {
        $zip = script:New-ZipFixture -WorkDir $script:workDir -ArchiveName 'aprl.zip'
        $asset = [pscustomobject]@{
            Source = $zip.Url
            Sha256 = $zip.Sha256
            Ref    = $null
            Path   = $null
            Type   = $null
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls | Out-Null
        }
        $forced = InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls -Force
        }
        $forced.Action | Should -Be 'installed'
    }

    It 'returns the subdir when descriptor Path is set' {
        $zip = script:New-ZipFixture -WorkDir $script:workDir -ArchiveName 'aprl.zip' -TopDir 'rules' -Files @{ 'a.rego' = 'package a' }
        $asset = [pscustomobject]@{
            Source = $zip.Url
            Sha256 = $zip.Sha256
            Ref    = $null
            Path   = 'rules'
            Type   = $null
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls
        }
        (Split-Path -Leaf $result.Path) | Should -Be 'rules'
        Test-Path -LiteralPath (Join-Path $result.Path 'a.rego') | Should -BeTrue
    }

    AfterEach {
        if ($null -eq $script:savedAvmHome) {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_HOME = $script:savedAvmHome
        }
        if (Test-Path -LiteralPath $script:sandbox) {
            Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Resolve-AvmPinnedAsset failure modes' {
    BeforeEach {
        $script:sandbox = Join-Path $TestDrive ("avmhome-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:AVM_HOME = $script:sandbox

        $script:workDir = Join-Path $TestDrive ("work-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null
    }

    It 'throws AvmConfigurationException when Sha256 is missing (ref-only)' {
        $asset = [pscustomobject]@{
            Source = 'https://example.test/bundle.zip'
            Sha256 = $null
            Ref    = 'main'
            Path   = $null
            Type   = $null
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            { Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }

    It 'throws AvmConfigurationException when Type is git' {
        $asset = [pscustomobject]@{
            Source = 'https://example.test/bundle.zip'
            Sha256 = ('a' * 64)
            Ref    = 'main'
            Path   = $null
            Type   = 'git'
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            { Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }

    It 'throws AvmConfigurationException for an unsupported archive extension' {
        $asset = [pscustomobject]@{
            Source = 'https://example.test/bundle.rar'
            Sha256 = ('a' * 64)
            Ref    = $null
            Path   = $null
            Type   = $null
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            { Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }

    It 'throws AvmConfigurationException for malformed Sha256' {
        $asset = [pscustomobject]@{
            Source = 'https://example.test/bundle.zip'
            Sha256 = 'not-hex'
            Ref    = $null
            Path   = $null
            Type   = $null
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            { Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }

    It 'throws AvmConfigurationException when descriptor Path is absent in the archive' {
        $zip = script:New-ZipFixture -WorkDir $script:workDir -ArchiveName 'aprl.zip' -TopDir 'policies' -Files @{ 'sample.rego' = 'package sample' }
        $asset = [pscustomobject]@{
            Source = $zip.Url
            Sha256 = $zip.Sha256
            Ref    = $null
            Path   = 'no-such-subdir'
            Type   = $null
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            { Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }

    It 'propagates SHA256 mismatch as AvmToolException' {
        $zip = script:New-ZipFixture -WorkDir $script:workDir -ArchiveName 'aprl.zip'
        $asset = [pscustomobject]@{
            Source = $zip.Url
            Sha256 = ('0' * 64)
            Ref    = $null
            Path   = $null
            Type   = $null
        }
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
                param($A)
                Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A -AllowFileUrls
            }
        }
        catch {
            $err = $_.Exception
        }
        $err | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmToolException'
        $err.Code | Should -Be 'AVM1011'
    }

    It 'throws AvmConfigurationException when source is file:// without -AllowFileUrls' {
        $zip = script:New-ZipFixture -WorkDir $script:workDir -ArchiveName 'aprl.zip'
        $asset = [pscustomobject]@{
            Source = $zip.Url
            Sha256 = $zip.Sha256
            Ref    = $null
            Path   = $null
            Type   = $null
        }
        InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            { Resolve-AvmPinnedAsset -Name 'aprl' -Asset $A } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }

    AfterEach {
        if ($null -eq $script:savedAvmHome) {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_HOME = $script:savedAvmHome
        }
        if (Test-Path -LiteralPath $script:sandbox) {
            Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Resolve-AvmPinnedAsset archive type inference' {
    BeforeEach {
        $script:sandbox = Join-Path $TestDrive ("avmhome-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:AVM_HOME = $script:sandbox

        $script:workDir = Join-Path $TestDrive ("work-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null
    }

    It 'accepts a .zip source' {
        $zip = script:New-ZipFixture -WorkDir $script:workDir -ArchiveName 'a.zip'
        $asset = [pscustomobject]@{
            Source = $zip.Url
            Sha256 = $zip.Sha256
            Ref    = $null
            Path   = $null
            Type   = $null
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ A = $asset } {
            param($A)
            Resolve-AvmPinnedAsset -Name 'x' -Asset $A -AllowFileUrls
        }
        $result.Action | Should -Be 'installed'
    }

    AfterEach {
        if ($null -eq $script:savedAvmHome) {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_HOME = $script:savedAvmHome
        }
        if (Test-Path -LiteralPath $script:sandbox) {
            Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
