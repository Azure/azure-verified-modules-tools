#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function script:New-DoctorFixture {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [string] $PayloadText = 'fake-tool-payload-doctor',
            [string] $ToolName    = 'fake-tool',
            [string] $ToolVersion = '1.0.0',
            [string[]] $UnsupportedPlatforms,
            [string] $TamperedSha
        )
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $payload = Join-Path $Root "$ToolName-$ToolVersion.bin"
        Set-Content -LiteralPath $payload -Value $PayloadText -NoNewline -Encoding utf8
        $realSha = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
        $sha = if ($TamperedSha) { $TamperedSha } else { $realSha }
        $urlPath = ($payload -replace '\\', '/')
        if ($urlPath -notmatch '^/') { $urlPath = '/' + $urlPath }
        $fileUrl = "file://$urlPath"

        $allPlatforms = @(
            'windows-amd64', 'windows-arm64',
            'linux-amd64', 'linux-arm64',
            'darwin-amd64', 'darwin-arm64'
        )
        $unsupported = if ($UnsupportedPlatforms) { @($UnsupportedPlatforms) } else { @() }
        $shaMap = [ordered]@{}
        foreach ($p in $allPlatforms) {
            if ($unsupported -contains $p) { continue }
            $shaMap[$p] = $sha
        }

        $tool = [ordered]@{
            name        = $ToolName
            version     = $ToolVersion
            urlTemplate = $fileUrl
            archive     = 'raw'
            entrypoint  = $ToolName
        }
        if ($UnsupportedPlatforms) { $tool['unsupportedPlatforms'] = @($UnsupportedPlatforms) }
        $tool['sha256'] = $shaMap

        $pins = [ordered]@{ schemaVersion = 1; tools = @($tool) }
        $pinsPath = Join-Path $Root 'avm.pins.jsonc'
        Set-Content -LiteralPath $pinsPath -Value ($pins | ConvertTo-Json -Depth 8) -Encoding utf8
        return $pinsPath
    }

    $script:savedAvmHome = if (Test-Path Env:\AVM_HOME) { $env:AVM_HOME } else { $null }
}

AfterAll {
    if ($null -eq $script:savedAvmHome) { Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue }
    else { $env:AVM_HOME = $script:savedAvmHome }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmDoctor (baseline checks)' {
    BeforeEach {
        $script:sandbox = Join-Path $TestDrive ("avmhome-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:AVM_HOME = $script:sandbox
    }

    It 'returns a single pscustomobject with Status, Failed, Checks' {
        $result = Invoke-AvmDoctor
        $result | Should -BeOfType [pscustomobject]
        @($result).Count | Should -Be 1
        $result.PSObject.Properties.Name | Should -Contain 'Status'
        $result.PSObject.Properties.Name | Should -Contain 'Failed'
        $result.PSObject.Properties.Name | Should -Contain 'Checks'
    }

    It 'reports OK overall on a sane environment' {
        $result = Invoke-AvmDoctor
        $result.Status | Should -Be 'OK'
        $result.Failed | Should -Be 0
    }

    It 'includes the PowerShell version, edition, OS, and folder probes' {
        $names = @((Invoke-AvmDoctor).Checks | ForEach-Object Name)
        $names | Should -Contain 'PowerShell version'
        $names | Should -Contain 'PowerShell edition'
        $names | Should -Contain 'Operating system'
        $names | Should -Contain 'AVM folder (Tools)'
        $names | Should -Contain 'AVM folder (Cache)'
    }

    It 'does NOT add any "Install tool" checks when -Install is not set' {
        $names = @((Invoke-AvmDoctor).Checks | ForEach-Object Name)
        @($names | Where-Object { $_ -like 'Install tool*' }).Count | Should -Be 0
    }

    It 'emits valid JSON with --json' {
        $json = Invoke-AvmDoctor -Json
        $json | Should -Not -BeNullOrEmpty
        { $json | ConvertFrom-Json } | Should -Not -Throw
        $parsed = $json | ConvertFrom-Json
        $parsed.Status | Should -Be 'OK'
    }
}

Describe 'Invoke-AvmDoctor -Install' {
    BeforeEach {
        $script:sandbox = Join-Path $TestDrive ("avmhome-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:AVM_HOME = $script:sandbox

        $script:fixtureRoot = Join-Path $TestDrive ("fx-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:pinsPath = New-DoctorFixture -Root $script:fixtureRoot
    }

    It 'installs the tool and adds an OK "Install tool" check' {
        $result = Invoke-AvmDoctor -Install -PinsPath $script:pinsPath -AllowFileUrls
        $result.Status | Should -Be 'OK'
        $installCheck = @($result.Checks | Where-Object { $_.Name -like 'Install tool (fake-tool*' })
        $installCheck.Count | Should -Be 1
        $installCheck[0].Status | Should -Be 'OK'
        $installCheck[0].Detail | Should -Match '^installed: '
    }

    It 'reports cache-hit on the second invocation' {
        Invoke-AvmDoctor -Install -PinsPath $script:pinsPath -AllowFileUrls | Out-Null
        $second = Invoke-AvmDoctor -Install -PinsPath $script:pinsPath -AllowFileUrls
        $installCheck = @($second.Checks | Where-Object { $_.Name -like 'Install tool (fake-tool*' })[0]
        $installCheck.Detail | Should -Match '^cache-hit: '
    }

    It 'reinstalls when -Force is set' {
        Invoke-AvmDoctor -Install -PinsPath $script:pinsPath -AllowFileUrls | Out-Null
        $forced = Invoke-AvmDoctor -Install -Force -PinsPath $script:pinsPath -AllowFileUrls
        $installCheck = @($forced.Checks | Where-Object { $_.Name -like 'Install tool (fake-tool*' })[0]
        $installCheck.Detail | Should -Match '^installed: '
    }

    It 'marks the check Skip (not Fail) when the platform is unsupported' {
        $platform = InModuleScope 'Avm.Authoring' { Get-AvmToolPlatform }
        $skipFixture = Join-Path $TestDrive ("fx-skip-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $skipLock = New-DoctorFixture -Root $skipFixture -UnsupportedPlatforms @($platform)
        $result = Invoke-AvmDoctor -Install -PinsPath $skipLock -AllowFileUrls
        $installCheck = @($result.Checks | Where-Object { $_.Name -like 'Install tool*' })[0]
        $installCheck.Status | Should -Be 'Skip'
        $result.Status | Should -Be 'OK'
        $result.Failed | Should -Be 0
    }

    It 'marks the check Fail when the payload SHA256 has been tampered with, but other checks survive' {
        $tamperedFixture = Join-Path $TestDrive ("fx-bad-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $tamperedLock = New-DoctorFixture -Root $tamperedFixture -TamperedSha ('1' * 64)
        $result = Invoke-AvmDoctor -Install -PinsPath $tamperedLock -AllowFileUrls
        $installCheck = @($result.Checks | Where-Object { $_.Name -like 'Install tool*' })[0]
        $installCheck.Status | Should -Be 'Fail'
        $result.Status | Should -Be 'Fail'
        # Environment checks still ran and still report OK.
        @($result.Checks | Where-Object { $_.Name -eq 'PowerShell version' })[0].Status | Should -Be 'OK'
    }

    It 'supports -WhatIf: emits a Skip check and does not install' {
        $result = Invoke-AvmDoctor -Install -WhatIf -PinsPath $script:pinsPath -AllowFileUrls
        $installCheck = @($result.Checks | Where-Object { $_.Name -like 'Install tool*' })[0]
        $installCheck.Status | Should -Be 'Skip'
        $installCheck.Detail | Should -Match 'ShouldProcess'
        # Overall status is still OK because Skip does not count as a failure.
        $result.Status | Should -Be 'OK'
        # No cache directory should have been created.
        $toolsDir = Join-Path $script:sandbox 'data\tools\fake-tool'
        Test-Path -LiteralPath $toolsDir | Should -BeFalse
    }
}

Describe 'avm doctor (dispatcher routes)' {
    BeforeEach {
        $script:sandbox = Join-Path $TestDrive ("avmhome-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null
        $env:AVM_HOME = $script:sandbox
    }

    It 'routes "avm doctor" to Invoke-AvmDoctor' {
        $direct = Invoke-AvmDoctor
        $via = avm doctor --passthru
        $via.Status | Should -Be $direct.Status
    }

    It 'routes "avm doctor --json" to Invoke-AvmDoctor -Json' {
        $json = avm doctor --json
        # F47: `'' | ConvertFrom-Json` does not throw, so -Not -Throw alone passes on
        # empty output - the exact regression a routing test exists to catch.
        $json | Should -Not -BeNullOrEmpty
        { $json | ConvertFrom-Json } | Should -Not -Throw
        ($json | ConvertFrom-Json).Status | Should -BeIn @('OK', 'Fail')
    }

    It 'routes "avm doctor --install" with all install flags through the dispatcher' {
        $fixtureRoot = Join-Path $TestDrive ("fx-disp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $pinsPath = New-DoctorFixture -Root $fixtureRoot
        $result = avm doctor --install --PinsPath $pinsPath --AllowFileUrls --passthru
        $result.Status | Should -Be 'OK'
        $installCheck = @($result.Checks | Where-Object { $_.Name -like 'Install tool (fake-tool*' })[0]
        $installCheck.Status | Should -Be 'OK'
    }
}
