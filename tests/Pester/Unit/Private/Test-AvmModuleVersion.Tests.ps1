#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Test-AvmModuleVersion' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
        $script:moduleRoot = Join-Path $script:repoRoot 'src' 'Avm.Authoring'
        $script:originalTestSkip = $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK
        $script:originalMcrSkip = $env:AVM_SKIP_MCR_VERSION_CHECK
        $script:originalOffline = $env:AVM_OFFLINE
        $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = '0'
        Remove-Item Env:AVM_SKIP_MCR_VERSION_CHECK -ErrorAction SilentlyContinue
        Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
        Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
    }

    AfterAll {
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
        if ($null -eq $script:originalTestSkip) {
            Remove-Item Env:AVM_TEST_SKIP_MODULE_VERSION_CHECK -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = $script:originalTestSkip
        }
        if ($null -eq $script:originalMcrSkip) {
            Remove-Item Env:AVM_SKIP_MCR_VERSION_CHECK -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_SKIP_MCR_VERSION_CHECK = $script:originalMcrSkip
        }
        if ($null -eq $script:originalOffline) {
            Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_OFFLINE = $script:originalOffline
        }
    }

    BeforeEach {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'UserFeed'; Priority = 10 } }
            $script:AvmLatestModuleVersion = $null
            $script:AvmLatestModuleRelease = $null
            $script:AvmModuleVersionCheckCompleted = $false
            $script:AvmMcrAuthoringVersion = $null
            $script:AvmMcrAuthoringVersionCheckCompleted = $false
            $script:AvmModuleVersionSkipWarningWritten = $false
            $script:CurrentVersionUnderTest = (Get-Module -Name 'Avm.Authoring').Version.ToString()
            Mock Invoke-AvmWebRequest {
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = '{"name":"psresource/avm.authoring","tags":["' + $script:CurrentVersionUnderTest + '"]}'
                }
            }
        }
    }

    It 'queries PowerShell Gallery once and caches the result for direct cmdlets' {
        InModuleScope 'Avm.Authoring' {
            $current = (Get-Module -Name 'Avm.Authoring').Version
            Mock Find-PSResource {
                [pscustomobject]@{
                    Name    = 'Avm.Authoring'
                    Version = $current.ToString()
                }
            }

            Test-AvmModuleVersion
            Test-AvmModuleVersion

            Should -Invoke Find-PSResource -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Avm.Authoring' -and
                $Repository -eq 'UserFeed' -and
                $ErrorAction -eq 'Stop'
            }
        }
    }

    It 'refreshes the Gallery result for each top-level command' {
        InModuleScope 'Avm.Authoring' {
            $current = (Get-Module -Name 'Avm.Authoring').Version
            $script:GalleryLookupCount = 0
            Mock Find-PSResource {
                $script:GalleryLookupCount++
                [pscustomobject]@{
                    Name    = 'Avm.Authoring'
                    Version = if ($script:GalleryLookupCount -eq 1) {
                        $current.ToString()
                    }
                    else {
                        '99.0.0'
                    }
                }
            }

            Invoke-Avm version | Out-Null
            { Invoke-Avm help | Out-Null } | Should -Throw -ExceptionType ([AvmModuleVersionException])

            Should -Invoke Find-PSResource -Times 2 -Exactly
        }
    }

    It 'rejects an outdated module with actionable guidance and a typed exit code' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource {
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '99.0.0' }
            }

            $caught = $null
            try {
                Test-AvmModuleVersion
            }
            catch {
                $caught = $_.Exception
            }

            $caught | Should -BeOfType ([AvmModuleVersionException])
            $caught.Code | Should -Be 'AVM1050'
            $caught.ExitCode | Should -Be 10
            $caught.CurrentVersion | Should -Be (Get-Module Avm.Authoring).Version
            $caught.LatestVersion | Should -Be ([version]'99.0.0')
            $caught.Message | Should -Match 'Installed version:'
            $caught.Message | Should -Match 'Latest version: 99\.0\.0'
            $caught.Message | Should -Match 'avm upgrade'
            $caught.Message | Should -Match 'Import-Module Avm\.Authoring -Force'
        }
    }

    It 'warns instead of throwing for an outdated module in version-reporting mode' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource {
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '99.0.0' }
            }

            $records = @(Test-AvmModuleVersion -WarnOnly 3>&1)

            $records.Count | Should -Be 1
            $records[0] | Should -BeOfType ([System.Management.Automation.WarningRecord])
            [string]$records[0] | Should -Match 'update available: 99\.0\.0'
            [string]$records[0] | Should -Match 'avm upgrade'
        }
    }

    It 'does not warn when the running module is current' {
        InModuleScope 'Avm.Authoring' {
            $current = (Get-Module -Name 'Avm.Authoring').Version
            Mock Find-PSResource {
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = $current.ToString() }
            }

            @(Test-AvmModuleVersion -WarnOnly 3>&1).Count | Should -Be 0
        }
    }

    It 'prompts to register MAR only when MCR is ahead of configured repositories and the installed module' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'Proxy'; Priority = 10; Uri = 'https://proxy.example.test' } }
            Mock Invoke-AvmWebRequest {
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = '{"name":"psresource/avm.authoring","tags":["99.0.0"]}'
                }
            }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '2.0.0' } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }

            $caught = $null
            try {
                Test-AvmModuleVersion
            }
            catch {
                $caught = $_.Exception
            }

            $caught | Should -BeOfType ([AvmModuleVersionException])
            $caught.LatestVersion | Should -Be ([version]'99.0.0')
            $caught.Message | Should -Match 'Latest configured repository version: 2\.0\.0'
            $caught.Message | Should -Match "Register-PSResourceRepository -Name MAR -Uri 'https://mcr\.microsoft\.com' -ApiVersion ContainerRegistry -Trusted"
            $caught.Message | Should -Match 'Install-PSResource -Name avm\.authoring -Repository MAR -Scope CurrentUser -Reinstall'
            Should -Invoke Invoke-AvmWebRequest -Exactly 1 -ParameterFilter {
                $Uri -eq 'https://mcr.microsoft.com/v2/psresource/avm.authoring/tags/list'
            }
        }
    }

    It 'keeps the configured proxy update path when its release is current with MCR' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'Proxy'; Priority = 10; Uri = 'https://proxy.example.test' } }
            Mock Invoke-AvmWebRequest {
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = '{"name":"psresource/avm.authoring","tags":["99.0.0"]}'
                }
            }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '99.0.0' } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }

            $caught = $null
            try {
                Test-AvmModuleVersion
            }
            catch {
                $caught = $_.Exception
            }

            $caught | Should -BeOfType ([AvmModuleVersionException])
            $caught.Message | Should -Match 'avm upgrade'
            $caught.Message | Should -Not -Match 'Register-PSResourceRepository'
            Should -Invoke Invoke-AvmWebRequest -Exactly 1
            Should -Invoke Find-PSResource -Exactly 1
        }
    }

    It 'does not prompt for MAR when the installed module is current with MCR' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'Proxy'; Priority = 10; Uri = 'https://proxy.example.test' } }
            Mock Invoke-AvmWebRequest {
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = '{"name":"psresource/avm.authoring","tags":["99.0.0"]}'
                }
            }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '2.0.0' } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'99.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }

            @(Test-AvmModuleVersion 3>&1).Count | Should -Be 0
        }
    }

    It 'caches a current direct MCR version without suppressing the configured repository check' {
        InModuleScope 'Avm.Authoring' {
            $current = (Get-Module -Name 'Avm.Authoring').Version.ToString()
            Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'Proxy'; Priority = 10; Uri = 'https://proxy.example.test' } }
            Mock Invoke-AvmWebRequest {
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = '{"name":"psresource/avm.authoring","tags":["' + $current + '"]}'
                }
            }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = $current } }

            Test-AvmModuleVersion
            Test-AvmModuleVersion

            Should -Invoke Invoke-AvmWebRequest -Exactly 1
            Should -Invoke Find-PSResource -Exactly 1
        }
    }

    It 'skips only the direct MCR lookup when AVM_SKIP_MCR_VERSION_CHECK is set' {
        InModuleScope 'Avm.Authoring' {
            $env:AVM_SKIP_MCR_VERSION_CHECK = '1'
            Mock Invoke-AvmWebRequest { throw 'Unexpected MCR request.' }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '2.0.0' } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }

            try {
                { Test-AvmModuleVersion } | Should -Throw -ExceptionType ([AvmModuleVersionException])
                Should -Invoke Invoke-AvmWebRequest -Exactly 0
                Should -Invoke Find-PSResource -Exactly 1
            }
            finally {
                Remove-Item Env:AVM_SKIP_MCR_VERSION_CHECK -ErrorAction SilentlyContinue
            }
        }
    }

    It 'does not make the direct request in offline mode while keeping configured repository checks enabled' {
        InModuleScope 'Avm.Authoring' {
            $env:AVM_OFFLINE = '1'
            Mock Invoke-AvmWebRequest { throw 'Unexpected MCR request.' }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '2.0.0' } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }

            try {
                { Test-AvmModuleVersion } | Should -Throw -ExceptionType ([AvmModuleVersionException])
                Should -Invoke Invoke-AvmWebRequest -Exactly 0
                Should -Invoke Find-PSResource -Exactly 1
            }
            finally {
                Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
            }
        }
    }

    It 'does not make the direct request when MCR is registered under an alternate name' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'MCR Alias'; Priority = 10; Uri = 'https://mcr.microsoft.com/' }
            }
            Mock Invoke-AvmWebRequest { throw 'Unexpected MCR request.' }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '2.0.0' } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }

            { Test-AvmModuleVersion } | Should -Throw -ExceptionType ([AvmModuleVersionException])
            Should -Invoke Invoke-AvmWebRequest -Exactly 0
            Should -Invoke Find-PSResource -Exactly 1
        }
    }

    It 'warns and continues with configured repositories when MCR returns <ResponseKind>' -ForEach @(
        @{ ResponseKind = 'a request failure' }
        @{ ResponseKind = 'invalid tags' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ ResponseKind = $ResponseKind } {
            param($ResponseKind)
            Mock Get-PSResourceRepository { [pscustomobject]@{ Name = 'Proxy'; Priority = 10; Uri = 'https://proxy.example.test' } }
            Mock Invoke-AvmWebRequest {
                if ($ResponseKind -eq 'a request failure') {
                    throw [System.Net.Http.HttpRequestException]::new('private diagnostic')
                }
                [pscustomobject]@{
                    StatusCode = 200
                    Content    = '{"name":"psresource/avm.authoring","tags":["invalid"]}'
                }
            }
            Mock Find-PSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '1.0.0' } }
            Mock Get-Module { [pscustomobject]@{ Version = [version]'1.0.0' } } -ParameterFilter { $Name -eq 'Avm.Authoring' }

            $warnings = @(Test-AvmModuleVersion 3>&1)

            $warnings.Count | Should -Be 1
            [string]$warnings[0] | Should -Match 'Unable to check MCR'
            Should -Invoke Find-PSResource -Exactly 1
        }
    }

    It 'warns and continues when the PowerShell Gallery request fails' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource {
                throw [System.Net.Http.HttpRequestException]::new('private diagnostic')
            }
            Mock Wait-AvmRetryDelay { }

            $warnings = @(Test-AvmModuleVersion 3>&1)

            $warnings.Count | Should -Be 1
            Should -Invoke Find-PSResource -Exactly 2
            [string]$warnings[0] | Should -Match 'Unable to check configured PowerShell repositories'
            [string]$warnings[0] | Should -Match 'The repository request failed'
            [string]$warnings[0] | Should -Not -Match 'private diagnostic'
        }
    }

    It 'describes <Kind> Gallery results without internal indexing errors' -TestCases @(
        @{ Kind = 'empty'; Expected = 'returned no Avm.Authoring package' }
        @{ Kind = 'wrong package'; Expected = 'did not return the requested Avm.Authoring package' }
        @{ Kind = 'missing version'; Expected = 'did not contain a version' }
        @{ Kind = 'invalid version'; Expected = 'returned an invalid Avm.Authoring version' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{
            ResultKind     = $Kind
            ExpectedDetail = $Expected
        } {
            $script:GalleryResultUnderTest = switch ($ResultKind) {
                'empty' { $null }
                'wrong package' { [pscustomobject]@{ Name = 'Another.Module'; Version = '1.0.0' } }
                'missing version' { [pscustomobject]@{ Name = 'Avm.Authoring' } }
                'invalid version' { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = 'not-a-version' } }
            }
            Mock Find-PSResource { $script:GalleryResultUnderTest }

            $warnings = @(Test-AvmModuleVersion 3>&1)

            [string]$warnings[0] | Should -Match $ExpectedDetail
            [string]$warnings[0] | Should -Not -Match 'Cannot index into a null array'
        }
    }

    It 'warns once and never queries the Gallery when the check is explicitly skipped' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource

            $warnings = @(
                Test-AvmModuleVersion -SkipModuleVersionCheck 3>&1
                Test-AvmModuleVersion -SkipModuleVersionCheck 3>&1
            )

            $warnings.Count | Should -Be 1
            [string]$warnings[0] | Should -Match 'version check was skipped'
            Should -Invoke Find-PSResource -Times 0 -Exactly
        }
    }

    It 'uses configured priority order and falls through <Failure> without requiring PSGallery' -ForEach @(
        @{ Failure = 'empty response' }
        @{ Failure = 'wrong package' }
        @{ Failure = 'invalid version' }
        @{ Failure = 'unreachable repository' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Failure = $Failure } {
            param($Failure)
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'Backup'; Priority = 20 }
                [pscustomobject]@{ Name = 'Preferred'; Priority = 10 }
                [pscustomobject]@{ Name = 'Unused'; Priority = 30 }
            }
            $script:repositoryAttemptOrder = [Collections.Generic.List[string]]::new()
            Mock Find-PSResource {
                $script:repositoryAttemptOrder.Add($Repository)
                if ($Repository -eq 'Preferred') {
                    switch ($Failure) {
                        'empty response' { return }
                        'wrong package' { return [pscustomobject]@{ Name = 'Other'; Version = '99.0.0' } }
                        'invalid version' { return [pscustomobject]@{ Name = 'Avm.Authoring'; Version = 'bad' } }
                        'unreachable repository' { throw [InvalidOperationException]::new('Unavailable') }
                    }
                }
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '2.0.0' }
            }

            Get-AvmLatestModuleVersion | Should -Be ([version]'2.0.0')
            Get-AvmLatestModuleVersion | Should -Be ([version]'2.0.0')
            $script:repositoryAttemptOrder.ToArray() | Should -Be @('Preferred', 'Backup', 'Unused')
        }
    }

    It 'selects a newer release from a lower-priority repository' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'Preferred'; Priority = 10 }
                [pscustomobject]@{ Name = 'Backup'; Priority = 20 }
            }
            Mock Find-PSResource {
                [pscustomobject]@{
                    Name = 'Avm.Authoring'
                    Version = if ($Repository -eq 'Preferred') { '1.0.0' } else { '2.0.0' }
                }
            }
            $release = Get-AvmLatestModuleVersion -IncludeRepository
            $release.Version | Should -Be ([version]'2.0.0')
            $release.Repositories | Should -Be @('Backup')
            Should -Invoke Find-PSResource -Exactly 2
        }
    }

    It 'queries MAR and other feeds with the unchanged module name and caches all latest-version sources' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'CompanyFeed'; Priority = 1; Uri = 'https://packages.example.test/' }
                [pscustomobject]@{ Name = 'OfficialPackages'; Priority = 99; Uri = 'https://mcr.microsoft.com/' }
            }
            Mock Find-PSResource {
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '2.0.0' }
            }
            $release = Get-AvmLatestModuleVersion -IncludeRepository
            $release.Version | Should -Be ([version]'2.0.0')
            $release.Repositories | Should -Be @('CompanyFeed', 'OfficialPackages')
            Get-AvmLatestModuleVersion | Should -Be ([version]'2.0.0')
            (Get-AvmLatestModuleVersion -IncludeRepository).Repositories | Should -Be @('CompanyFeed', 'OfficialPackages')
            Should -Invoke Find-PSResource -Exactly 1 -ParameterFilter {
                $Name -eq 'Avm.Authoring' -and $Repository -eq 'OfficialPackages'
            }
            Should -Invoke Find-PSResource -Exactly 1 -ParameterFilter { $Repository -eq 'CompanyFeed' }
        }
    }

    It 'falls back to configured feeds when MAR is <Failure>' -ForEach @(
        @{ Failure = 'not yet published' }
        @{ Failure = 'unavailable' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Failure = $Failure } {
            param($Failure)
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'CompanyFeed'; Priority = 1; Uri = 'https://packages.example.test/' }
                [pscustomobject]@{ Name = 'OfficialPackages'; Priority = 99; Uri = 'https://mcr.microsoft.com/' }
            }
            $calls = [Collections.Generic.List[string]]::new()
            Mock Find-PSResource {
                $calls.Add($Repository)
                if ($Repository -eq 'OfficialPackages') {
                    if ($Failure -eq 'unavailable') { throw [InvalidOperationException]::new('Unavailable') }
                    return
                }
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '2.0.0' }
            }
            Get-AvmLatestModuleVersion | Should -Be ([version]'2.0.0')
            $calls.ToArray() | Should -Be @('CompanyFeed', 'OfficialPackages')
        }
    }

    It 'refreshes the selected version and its repositories together' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'First'; Priority = 1 }
                [pscustomobject]@{ Name = 'Second'; Priority = 2 }
            }
            $state = @{ Refreshed = $false }
            Mock Find-PSResource {
                [pscustomobject]@{
                    Name = 'Avm.Authoring'
                    Version = if ($state.Refreshed -and $Repository -eq 'Second') { '3.0.0' } else { '2.0.0' }
                }
            }
            (Get-AvmLatestModuleVersion -IncludeRepository).Repositories | Should -Be @('First', 'Second')
            $state.Refreshed = $true
            $release = Get-AvmLatestModuleVersion -Refresh -IncludeRepository
            $release.Version | Should -Be ([version]'3.0.0')
            $release.Repositories | Should -Be @('Second')
            Get-AvmLatestModuleVersion | Should -Be ([version]'3.0.0')
            Should -Invoke Find-PSResource -Exactly 4
        }
    }

    It 'retains a valid latest release when a later repository fails' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository {
                [pscustomobject]@{ Name = 'First'; Priority = 1 }
                [pscustomobject]@{ Name = 'Broken'; Priority = 2 }
            }
            Mock Find-PSResource {
                if ($Repository -eq 'Broken') { throw [InvalidOperationException]::new('Unavailable') }
                [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '3.0.0' }
            }
            $release = Get-AvmLatestModuleVersion -IncludeRepository
            $release.Version | Should -Be ([version]'3.0.0')
            $release.Repositories | Should -Be @('First')
        }
    }

    It 'warns when no repositories are configured without caching a successful check' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-PSResourceRepository {}
            Mock Find-PSResource
            $warnings = @(Test-AvmModuleVersion 3>&1)
            $warnings.Count | Should -Be 1
            $script:AvmModuleVersionCheckCompleted | Should -BeFalse
            Should -Invoke Find-PSResource -Exactly 0
        }
    }

    It 'silently bypasses a nested check after the dispatcher already checked' {
        InModuleScope 'Avm.Authoring' {
            Mock Find-PSResource

            $warnings = @(Test-AvmModuleVersion -SkipModuleVersionCheck -SuppressSkipWarning 3>&1)

            $warnings.Count | Should -Be 0
            Should -Invoke Find-PSResource -Times 0 -Exactly
        }
    }

    Context 'public commands that resolve module context' {
        It 'honours -SkipModuleVersionCheck when the Gallery has a newer version: <Command>' -ForEach @(
            @{ Command = 'Invoke-AvmLint'; Engine = 'Invoke-AvmTerraformLint' }
            @{ Command = 'Invoke-AvmFormat'; Engine = 'Format-AvmTerraformModule' }
            @{ Command = 'Invoke-AvmTransform'; Engine = 'Invoke-AvmTerraformTransform' }
            @{ Command = 'Invoke-AvmDocs'; Engine = 'Invoke-AvmTerraformDocs' }
            @{ Command = 'Invoke-AvmTest'; Engine = 'Invoke-AvmTerraformTest' }
        ) {
            $root = Join-Path $TestDrive "skip-$Command"
            $null = New-Item -ItemType Directory -Path $root -Force
            [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), "terraform {}`n")
            InModuleScope 'Avm.Authoring' -Parameters @{ Root = $root; Command = $Command; Engine = $Engine } {
                param($Root, $Command, $Engine)
                Mock Find-PSResource { [pscustomobject]@{ Name = 'Avm.Authoring'; Version = '9999.0.0' } }
                Mock $Engine { [pscustomobject]@{ Engine = 'terraform'; Status = 'pass'; Issues = @() } }
                Mock Write-AvmLog

                { & $Command -Path $Root -Ecosystem terraform } | Should -Throw -ExceptionType ([AvmModuleVersionException])
                Should -Invoke $Engine -Exactly 0

                $script:AvmLatestModuleVersion = $null
                $script:AvmModuleVersionCheckCompleted = $false
                $null = & $Command -Path $Root -Ecosystem terraform -SkipModuleVersionCheck 3>$null
                Should -Invoke $Engine -Exactly 1
            }
        }
    }
}
