#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force

    function New-RuntimeModulePackage {
        param([string] $Root, [string] $Name, [string] $Version, [string] $Dependency)

        $directory = Join-Path $Root $Name $Version
        $null = New-Item -ItemType Directory -Path $directory -Force
        $required = if ($Dependency) { "@(@{ ModuleName = '$Dependency'; ModuleVersion = '1.0.0' })" } else { '@()' }
        [System.IO.File]::WriteAllText((Join-Path $directory "$Name.psd1"), @"
@{
    RootModule = '$Name.psm1'
    ModuleVersion = '$Version'
    GUID = '08b4772f-d6e5-4cde-b714-ae2151b8c692'
    FunctionsToExport = @('Get-AvmFixtureValue')
    RequiredModules = $required
}
"@)
        [System.IO.File]::WriteAllText((Join-Path $directory "$Name.psm1"), "function Get-AvmFixtureValue { '$Version' }")
        $archive = Join-Path $Root "$Name-$Version.zip"
        [System.IO.Compression.ZipFile]::CreateFromDirectory($directory, $archive)
        [pscustomobject]@{
            Directory = $directory; Archive = $archive
            Sha256 = (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()
        }
    }

    function Save-RuntimePins {
        param($Fixture)
        [System.IO.File]::WriteAllText($Fixture.PinsPath, ($Fixture.Pins | ConvertTo-Json -Depth 20))
    }

    function Set-RuntimeOverride {
        param([string] $Root, [string] $Json)
        $directory = Join-Path $Root '.avm'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $path = Join-Path $directory 'tool-version-overrides.json'
        [System.IO.File]::WriteAllText($path, $Json)
        return $path
    }
}

AfterAll { Remove-Module Avm.Authoring -Force }

Describe 'Component: runtime prerequisites' -Tag Component {
    BeforeEach {
        $script:savedEnvironment = @{}
        foreach ($name in @('AVM_HOME', 'AVM_OFFLINE', 'AVM_MIRROR', 'AVM_NO_AUTO_INSTALL', 'PSModulePath')) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        foreach ($name in @('AVM_OFFLINE', 'AVM_MIRROR', 'AVM_NO_AUTO_INSTALL')) {
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        }
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $env:AVM_HOME = Join-Path $root 'cache'
        [System.IO.File]::WriteAllText((Join-Path $root 'terraform.tf'), 'terraform {}')
        $assets = Join-Path $root 'assets'
        $dependency = New-RuntimeModulePackage -Root $assets -Name AvmFixtureDependency -Version '1.0.0'
        $package = New-RuntimeModulePackage -Root $assets -Name AvmFixturePrerequisite -Version '1.0.0' -Dependency AvmFixtureDependency
        $newPackage = New-RuntimeModulePackage -Root $assets -Name AvmFixturePrerequisite -Version '2.0.0' -Dependency AvmFixtureDependency
        $payload = Join-Path $assets 'binary'
        [System.IO.File]::WriteAllText($payload, 'binary fixture')
        $hash = (Get-FileHash -LiteralPath $payload).Hash.ToLowerInvariant()
        $hashes = @{}
        foreach ($platform in @('windows-amd64', 'windows-arm64', 'linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64')) {
            $hashes[$platform] = $hash
        }
        $script:fixture = [pscustomobject]@{
            Root = $root; PinsPath = Join-Path $root 'fixture.pins.json'; Package = $package
            NewPackage = $newPackage; Dependency = $dependency; Assets = $assets
            Packages = @{
                'https://www.powershellgallery.com/api/v2/package/AvmFixturePrerequisite/1.0.0' = $package.Archive
                'https://www.powershellgallery.com/api/v2/package/AvmFixturePrerequisite/2.0.0' = $newPackage.Archive
                'https://www.powershellgallery.com/api/v2/package/AvmFixtureDependency/1.0.0' = $dependency.Archive
                'https://example.invalid/terraform/1.0.0' = $payload
                'https://example.invalid/terraform/2.0.0' = $payload
            }
            Pins = @{
                schemaVersion = 1
                tools = @(@{
                        name = 'terraform'; version = '1.0.0'; archive = 'raw'; entrypoint = 'terraform'
                        urlTemplate = 'https://example.invalid/terraform/{version}'; sha256 = $hashes
                    })
                powerShellModules = @{
                    AvmFixturePrerequisite = @{ version = '1.0.0'; sha256 = $package.Sha256; dependencies = @('AvmFixtureDependency') }
                    AvmFixtureDependency = @{ version = '1.0.0'; sha256 = $dependency.Sha256 }
                }
            }
        }
        Save-RuntimePins -Fixture $script:fixture
        InModuleScope Avm.Authoring -Parameters @{ Fixture = $script:fixture } {
            param($Fixture)
            $script:runtimeFixture = $Fixture
            Mock Test-AvmModuleVersion
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                if (-not $script:runtimeFixture.Packages.ContainsKey([string]$Uri)) {
                    throw [System.InvalidOperationException]::new("Unexpected fixture request: $Uri")
                }
                Copy-Item -LiteralPath $script:runtimeFixture.Packages[[string]$Uri] -Destination $OutFile
            }
        }
    }

    AfterEach {
        InModuleScope Avm.Authoring {
            foreach ($name in @('AvmFixturePrerequisite', 'AvmFixtureDependency')) {
                Remove-Module -Name $name -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($name in $script:savedEnvironment.Keys) {
            $value = if ($null -eq $script:savedEnvironment[$name]) { [NullString]::Value } else { $script:savedEnvironment[$name] }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }

    It 'installs and imports checksum-pinned modules and their pinned dependencies without modifying PSModulePath' {
        $before = $env:PSModulePath
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            $loaded = Import-AvmPowerShellModule -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $loaded.Version | Should -Be ([version]'1.0.0')
            & $loaded.ExportedCommands['Get-AvmFixtureValue'] | Should -Be '1.0.0'
            $loaded.RequiredModules.Version | Should -Be ([version]'1.0.0')
            $tool = Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $tool.Source | Should -Be 'cache'
            $tool.Path | Should -BeLike (Join-Path $env:AVM_HOME '*')
            $metadata = Get-Content (Join-Path (Split-Path $tool.Path) '.meta.json') -Raw | ConvertFrom-Json
            $metadata.sha256 | Should -Be $F.Package.Sha256
            $metadata.checksumVerified | Should -BeTrue
            Should -Invoke Invoke-WebRequest -Exactly 2
        }
        $env:PSModulePath | Should -BeExactly $before
    }

    It 'reuses an installed exact module version without a download' {
        $env:PSModulePath = $script:fixture.Assets + [System.IO.Path]::PathSeparator + $env:PSModulePath
        $env:AVM_NO_AUTO_INSTALL = '1'
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            $resolved = Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $resolved.Source | Should -Be 'module-path'
            $resolved.Path | Should -Be (Join-Path $F.Package.Directory 'AvmFixturePrerequisite.psd1')
            $loaded = Import-AvmPowerShellModule -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $loaded.Version | Should -Be ([version]'1.0.0')
            Should -Invoke Invoke-WebRequest -Exactly 0
        }
    }

    It 'ignores older installed modules and acquires the configured version' {
        $installedRoot = Join-Path $script:fixture.Root 'old-installed'
        $null = New-RuntimeModulePackage -Root $installedRoot -Name AvmFixturePrerequisite -Version '0.9.0'
        $env:PSModulePath = $installedRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            $resolved = Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $resolved.Version | Should -Be '1.0.0'
            $resolved.Source | Should -Be 'installed'
            Should -Invoke Invoke-WebRequest -Exactly 1
        }
    }

    It 'installs dependencies when explicitly installing a single PowerShell tool' {
        $installed = @(Install-AvmTool -Name AvmFixturePrerequisite -PinsPath $script:fixture.PinsPath -Path $script:fixture.Root)
        $installed.Name | Should -Be @('AvmFixtureDependency', 'AvmFixturePrerequisite')
        $env:AVM_OFFLINE = '1'
        $env:AVM_NO_AUTO_INSTALL = '1'
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            (Import-AvmPowerShellModule -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root).Version |
                Should -Be ([version]'1.0.0')
            Should -Invoke Invoke-WebRequest -Exactly 2
        }
    }

    It 'rejects an already loaded different module version before acquisition with fresh-session guidance' {
        $old = New-RuntimeModulePackage -Root (Join-Path $script:fixture.Root 'old-loaded') `
            -Name AvmFixturePrerequisite -Version '0.9.0'
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture; Old = $old } {
            param($F, $Old)
            Import-Module (Join-Path $Old.Directory 'AvmFixturePrerequisite.psd1')
            { Import-AvmPowerShellModule -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root } |
                Should -Throw '*0.9.0*already loaded*configured version is 1.0.0*fresh PowerShell session*'
            Should -Invoke Invoke-WebRequest -Exactly 0
        }
    }

    It 'rejects same-version Pester from another path before importing a second engine' {
        $pester = Get-Module -Name Pester
        $script:fixture.Pins.powerShellModules.Pester = @{ version = $pester.Version.ToString(); sha256 = '0' * 64 }
        Save-RuntimePins -Fixture $script:fixture
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Path = Join-Path $F.Root 'different Pester' 'Pester.psd1' }
            } -ParameterFilter { $Name -ceq 'Pester' }
            Mock Import-Module { throw 'A second Pester engine must not be imported.' }
            { Import-AvmPowerShellModule -Name Pester -PinsPath $F.PinsPath -ModuleRoot $F.Root } |
                Should -Throw '*already loaded*not the configured path*fresh PowerShell session*'
            Should -Invoke Import-Module -Exactly 0
            Should -Invoke Invoke-WebRequest -Exactly 0
        }
    }

    It 'reuses the configured Pester engine when its version and path already match' {
        $pester = Get-Module -Name Pester
        $script:fixture.Pins.powerShellModules.Pester = @{ version = $pester.Version.ToString(); sha256 = '0' * 64 }
        Save-RuntimePins -Fixture $script:fixture
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture; Pester = $pester } {
            param($F, $Pester)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Path = Join-Path $Pester.ModuleBase 'Pester.psd1' }
            } -ParameterFilter { $Name -ceq 'Pester' }
            $loaded = Import-AvmPowerShellModule -Name Pester -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $loaded.Version | Should -Be $Pester.Version
            $loaded.ModuleBase | Should -BeExactly $Pester.ModuleBase
            Should -Invoke Invoke-WebRequest -Exactly 0
        }
    }

    It 'keeps <Setting> effective for an uncached <Kind>' -ForEach @(
        @{ Setting = 'AVM_OFFLINE'; Kind = 'pin'; Override = $false; Message = '*AVM_OFFLINE=1*' }
        @{ Setting = 'AVM_NO_AUTO_INSTALL'; Kind = 'pin'; Override = $false; Message = '*automatic installation is disabled*' }
        @{ Setting = 'AVM_OFFLINE'; Kind = 'override'; Override = $true; Message = '*AVM_OFFLINE=1*' }
        @{ Setting = 'AVM_NO_AUTO_INSTALL'; Kind = 'override'; Override = $true; Message = '*automatic installation is disabled*' }
    ) {
        if ($Override) { $null = Set-RuntimeOverride -Root $script:fixture.Root -Json '{"AvmFixturePrerequisite":"2.0.0"}' }
        [Environment]::SetEnvironmentVariable($Setting, '1', 'Process')
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture; Message = $Message } {
            param($F, $Message)
            { Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root } |
                Should -Throw -ExpectedMessage $Message
            Should -Invoke Invoke-WebRequest -Exactly 0
        }
    }

    It 'fails a corrupted pinned package without writing a verified entry' {
        $script:fixture.Pins.powerShellModules.AvmFixturePrerequisite.sha256 = '0' * 64
        Save-RuntimePins -Fixture $script:fixture
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            { Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root } |
                Should -Throw '*SHA256 mismatch*'
            $tool = Get-AvmToolDefinition -Pins (Read-AvmPins -Path $F.PinsPath) -Name AvmFixturePrerequisite
            (Get-AvmToolCacheEntry -Tool $tool -Platform (Get-AvmToolPlatform)).Cached | Should -BeFalse
        }
    }

    It 'surfaces a download failure without a cache success' {
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            Mock Invoke-WebRequest { throw [System.IO.FileNotFoundException]::new('Gallery package not found.') }
            { Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root } |
                Should -Throw '*Gallery package not found*'
            Should -Invoke Invoke-WebRequest -Exactly 1
        }
    }

    It 'reports malformed cache metadata and repairs it through explicit installation' {
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            $first = Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $metadataPath = Join-Path (Split-Path $first.Path) '.meta.json'
            [System.IO.File]::WriteAllText($metadataPath, '{invalid')
            Mock Write-AvmLog
            { Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root -NoAutoInstall } |
                Should -Throw '*automatic installation is disabled*'
            Should -Invoke Write-AvmLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'Invalid cache metadata*' }
            $null = Install-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -Path $F.Root -Force
            (Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root -NoAutoInstall).Source |
                Should -Be 'cache'
            (Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json).checksumVerified | Should -BeTrue
        }
    }

    It 'rejects undeclared dependencies before importing the requesting module' {
        $script:fixture.Pins.powerShellModules.AvmFixturePrerequisite.Remove('dependencies')
        Save-RuntimePins -Fixture $script:fixture
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            { Import-AvmPowerShellModule -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root } |
                Should -Throw '*unpinned dependency*'
            Get-Module -Name AvmFixturePrerequisite | Should -BeNullOrEmpty
        }
    }

    It 'isolates explicit <ToolName> overrides, warns on cache hits and leaves normal pins verified' -ForEach @(
        @{ ToolName = 'terraform'; Version = '2.0.0' }
        @{ ToolName = 'AvmFixturePrerequisite'; Version = '2.0.0' }
        @{ ToolName = 'terraform'; Version = '1.0.0' }
        @{ ToolName = 'AvmFixturePrerequisite'; Version = '1.0.0' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture; ToolName = $ToolName; Version = $Version } {
            param($F, $ToolName, $Version)
            $normal = Resolve-AvmTool -Name $ToolName -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $normalHash = (Get-FileHash -LiteralPath $normal.Path).Hash
            $directory = Join-Path $F.Root '.avm'
            $null = New-Item -ItemType Directory -Path $directory
            $overridePath = Join-Path $directory 'tool-version-overrides.json'
            [System.IO.File]::WriteAllText($overridePath, (@{ $ToolName = $Version } | ConvertTo-Json -Compress))
            Mock Write-AvmLog
            $override = Resolve-AvmTool -Name $ToolName -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $override.Path | Should -Not -Be $normal.Path
            $override.Version | Should -Be $Version
            $override.VersionOverride.Path | Should -Be $overridePath
            $override.VersionOverride.PackagedVersion | Should -Be '1.0.0'
            Join-Path (Split-Path $override.Path) '.unverified' | Should -Exist
            Join-Path (Split-Path $override.Path) '.verified' | Should -Not -Exist
            $meta = Get-Content (Join-Path (Split-Path $override.Path) '.meta.json') -Raw | ConvertFrom-Json
            $meta.sha256 | Should -BeNullOrEmpty
            $meta.checksumVerified | Should -BeFalse
            $env:AVM_OFFLINE = '1'
            $env:AVM_NO_AUTO_INSTALL = '1'
            (Resolve-AvmTool -Name $ToolName -PinsPath $F.PinsPath -ModuleRoot $F.Root).Source | Should -Be 'cache'
            Should -Invoke Write-AvmLog -Exactly 2 -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*OVERRIDE*packaged 1.0.0*checksum verification is DISABLED*'
            }
            $adjacent = Join-Path $F.Root 'adjacent'
            $null = New-Item -ItemType Directory -Path $adjacent
            $default = Resolve-AvmTool -Name $ToolName -PinsPath $F.PinsPath -ModuleRoot $adjacent
            $default.Path | Should -Be $normal.Path
            $default.VersionOverride | Should -BeNullOrEmpty
            (Get-FileHash -LiteralPath $normal.Path).Hash | Should -Be $normalHash
            Join-Path (Split-Path $normal.Path) '.verified' | Should -Exist
            (Get-Content (Join-Path (Split-Path $normal.Path) '.meta.json') -Raw | ConvertFrom-Json).checksumVerified |
                Should -BeTrue
        }
    }

    It 'does not inherit the packaged hash for an override or weaken untouched dependencies' {
        @($script:fixture.Pins.tools[0].sha256.Keys) | ForEach-Object { $script:fixture.Pins.tools[0].sha256[$_] = '0' * 64 }
        Save-RuntimePins -Fixture $script:fixture
        $null = Set-RuntimeOverride -Root $script:fixture.Root -Json '{"terraform":"2.0.0"}'
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            $effective = Read-AvmPins -Path $F.PinsPath -ModuleRoot $F.Root
            $effective.tools[0].sha256.Count | Should -Be 0
            $effective.powerShellModules.AvmFixturePrerequisite.sha256 | Should -Be $F.Package.Sha256
            (Resolve-AvmTool -Name terraform -PinsPath $F.PinsPath -ModuleRoot $F.Root).Version | Should -Be '2.0.0'
            { Resolve-AvmTool -Name terraform -PinsPath $F.PinsPath } | Should -Throw '*SHA256 mismatch*'
        }
    }

    It 'never treats a loaded same-version override as an installed default module' {
        $overridePath = Set-RuntimeOverride -Root $script:fixture.Root -Json '{"AvmFixturePrerequisite":"1.0.0"}'
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture; OverridePath = $overridePath } {
            param($F, $OverridePath)
            $overridden = Import-AvmPowerShellModule -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root
            Join-Path $overridden.ModuleBase '.unverified' | Should -Exist
            Remove-Item -LiteralPath $OverridePath
            $env:AVM_OFFLINE = '1'
            $env:AVM_NO_AUTO_INSTALL = '1'
            $env:PSModulePath = (Get-AvmFolder -Kind Tools) + [System.IO.Path]::PathSeparator + $env:PSModulePath
            { Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root } |
                Should -Throw '*automatic installation is disabled*'
            $status = Get-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -Path $F.Root
            $status.Status | Should -Be 'auto-install-disabled'
            $status.Path | Should -BeNullOrEmpty
            Should -Invoke Invoke-WebRequest -Exactly 2

            [Environment]::SetEnvironmentVariable('AVM_OFFLINE', [NullString]::Value, 'Process')
            [Environment]::SetEnvironmentVariable('AVM_NO_AUTO_INSTALL', [NullString]::Value, 'Process')
            $normal = Resolve-AvmTool -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $normal.Source | Should -Be 'installed'
            $normal.Path | Should -Not -Be (Join-Path $overridden.ModuleBase 'AvmFixturePrerequisite.psd1')
            Join-Path (Split-Path $normal.Path) '.verified' | Should -Exist
            { Import-AvmPowerShellModule -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root } |
                Should -Throw '*unverified*fresh PowerShell session*'
            Remove-Module -Name AvmFixturePrerequisite -Force
            $loaded = Import-AvmPowerShellModule -Name AvmFixturePrerequisite -PinsPath $F.PinsPath -ModuleRoot $F.Root
            $loaded.ModuleBase | Should -Be (Split-Path $normal.Path)
        }
    }

    It 'reports override provenance in tool list and doctor without installing anything' {
        $path = Set-RuntimeOverride -Root $script:fixture.Root -Json '{"terraform":"2.0.0"}'
        $tools = @(Get-AvmTool -PinsPath $script:fixture.PinsPath -Path $script:fixture.Root)
        ($tools | Where-Object Name -eq 'terraform').VersionOverride.Path | Should -Be $path
        ($tools | Where-Object Name -eq 'AvmFixturePrerequisite').VersionOverride | Should -BeNullOrEmpty
        $doctor = Invoke-AvmDoctor -PinsPath $script:fixture.PinsPath -Path $script:fixture.Root
        $doctor.Status | Should -Be 'OK'
        @($doctor.Checks | Where-Object Status -eq 'Warning').Count | Should -Be 1
        ($doctor.Checks | Where-Object Status -eq 'Warning').Detail | Should -Match ([regex]::Escape($path))
        InModuleScope Avm.Authoring { Should -Invoke Invoke-WebRequest -Exactly 0 }
    }

    It 'rejects invalid version override files: <Label>' -ForEach @(
        @{ Label = 'array'; Json = '[]' }
        @{ Label = 'null'; Json = 'null' }
        @{ Label = 'unknown tool'; Json = '{"unknown":"1.0.0"}' }
        @{ Label = 'wrong casing'; Json = '{"Terraform":"1.0.0"}' }
        @{ Label = 'duplicate key'; Json = '{"terraform":"1.0.0","terraform":"2.0.0"}' }
        @{ Label = 'case collision'; Json = '{"terraform":"1.0.0","Terraform":"2.0.0"}' }
        @{ Label = 'version range'; Json = '{"terraform":">=1.0.0"}' }
        @{ Label = 'numeric version'; Json = '{"terraform":2}' }
        @{ Label = 'arbitrary URL'; Json = '{"terraform":{"version":"1.0.0","url":"https://example.invalid"}}' }
        @{ Label = 'checksum object'; Json = '{"terraform":{"version":"1.0.0","sha256":"a"}}' }
        @{ Label = 'traversal'; Json = '{"terraform":"../../tool"}' }
        @{ Label = 'malformed JSON'; Json = '{"terraform":' }
    ) {
        $null = Set-RuntimeOverride -Root $script:fixture.Root -Json $Json
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture } {
            param($F)
            { Read-AvmPins -Path $F.PinsPath -ModuleRoot $F.Root } | Should -Throw '*Invalid tool overrides*'
            Should -Invoke Invoke-WebRequest -Exactly 0
        }
    }

    It 'uses only the recognized Bicep monorepo root for <Kind> modules and repository commands' -ForEach @(
        @{ Kind = 'implemented'; HasSource = $true }
        @{ Kind = 'proposed'; HasSource = $false }
    ) {
        $repository = Join-Path $script:fixture.Root 'registry'
        $module = Join-Path $repository 'avm' 'res' 'storage' 'storage-account'
        $null = New-Item -ItemType Directory -Path $module -Force
        [System.IO.File]::WriteAllText((Join-Path $repository 'bicepconfig.json'), '{}')
        if ($HasSource) {
            [System.IO.File]::WriteAllText((Join-Path $module 'main.bicep'), "metadata name = 'Storage'")
        }
        else {
            [System.IO.File]::WriteAllText((Join-Path $module 'metadata.json'), '{}')
        }
        $source = Set-RuntimeOverride -Root $repository -Json '{"terraform":"2.0.0","AvmFixturePrerequisite":"2.0.0"}'
        $null = Set-RuntimeOverride -Root $module -Json '{"terraform":"3.0.0","AvmFixturePrerequisite":"3.0.0"}'
        InModuleScope Avm.Authoring -Parameters @{ F = $script:fixture; Repository = $repository; Module = $module; Source = $source } {
            param($F, $Repository, $Module, $Source)
            foreach ($path in @($Repository, $Module)) {
                $pins = Read-AvmPins -Path $F.PinsPath -ModuleRoot $path
                $pins.tools[0].version | Should -Be '2.0.0'
                $pins.tools[0].versionOverride.Path | Should -Be $Source
                $pins.powerShellModules.AvmFixturePrerequisite.version | Should -Be '2.0.0'
            }
            (Read-AvmPins -Path $F.PinsPath -ModuleRoot $F.Root).tools[0].version | Should -Be '1.0.0'
        }
    }
}
