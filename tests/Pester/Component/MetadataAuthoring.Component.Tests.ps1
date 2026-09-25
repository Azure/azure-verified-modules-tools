#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
    $metadataSchemaId = (Get-Content (Join-Path $moduleRoot 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json') -Raw | ConvertFrom-Json).'$id'

    function New-AuthoringMetadataFixture {
        param([string] $Ecosystem, [switch] $Child)

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $fixture = [pscustomobject]@{
            Root = $root
            Context = [pscustomobject]@{
                Root = $root
                Ecosystem = $Ecosystem
                Kind = if ($Ecosystem -eq 'bicep') { 'bicep-module' } else { 'terraform-module-repo' }
                Scope = 'res'
            }
            Paths = @($root)
            Data = [ordered]@{
                '$schema' = $metadataSchemaId
                moduleDisplayName = 'Storage'
                moduleDescription = 'Creates storage.'
                canonicalType = 'Microsoft.Storage/storageAccounts'
                telemetryIdPrefix = if ($Ecosystem -eq 'bicep') { '46d3xbcp.res.storage-account' } else { '46d3xtrf.res.a1b2c3d' }
                owners = @('module-owner', '@Azure/team-name')
            }
        }
        if ($Child) {
            $childPath = if ($Ecosystem -eq 'bicep') { Join-Path $root 'blob-service' } else { Join-Path $root 'modules' 'blob-service' }
            $null = New-Item -ItemType Directory -Path $childPath -Force
            $fixture.Paths += $childPath
        }
        foreach ($path in $fixture.Paths) {
            if ($Ecosystem -eq 'bicep') {
                [System.IO.File]::WriteAllText((Join-Path $path 'main.bicep'), "metadata name = 'Storage'`nmetadata description = 'Creates storage.'`n")
            }
            else {
                [System.IO.File]::WriteAllText((Join-Path $path 'main.tf'), "locals { unrelated = true }`n")
            }
        }
        return $fixture
    }

    function Save-AuthoringMetadataFixture {
        param([object] $Fixture)

        foreach ($path in $Fixture.Paths) {
            $data = [ordered]@{}
            foreach ($key in $Fixture.Data.Keys) {
                if ($path -ceq $Fixture.Root -or $key -ne 'owners') {
                    $data[$key] = $Fixture.Data[$key]
                }
            }
            [System.IO.File]::WriteAllText((Join-Path $path 'metadata.json'), ($data | ConvertTo-Json -Depth 20))
        }
    }

    function Invoke-AuthoringMetadataFixture {
        param([object] $Fixture, [string] $Command, [switch] $Actions, [switch] $LogVerbose)

        InModuleScope Avm.Authoring -Parameters @{ ModuleContext = $Fixture.Context; CommandName = $Command; Actions = $Actions.IsPresent; LogVerbose = $LogVerbose.IsPresent } {
            param($ModuleContext, $CommandName, $Actions, $LogVerbose)
            $script:metadataLaterCalls = 0
            $script:metadataToolResolutions = 0
            Mock Get-AvmModuleContext { $ModuleContext }
            Mock Test-AvmModuleVersion {}
            Mock Resolve-AvmCommandTool { $script:metadataToolResolutions++; @() }
            Mock Assert-AvmGitWorkingTreeClean {}
            Mock Invoke-AvmHttp { throw 'Metadata validation must not fetch external data.' }
            Mock Invoke-AvmProcess { throw 'These metadata fixtures must not run a subprocess.' }
            foreach ($name in @('Invoke-AvmSync', 'Invoke-AvmFormat', 'Invoke-AvmTransform', 'Invoke-AvmLint', 'Invoke-AvmCheckPolicy', 'Invoke-AvmCheckConvention', 'Invoke-AvmTest', 'Invoke-AvmDocs')) {
                Mock -CommandName $name -MockWith {
                    $script:metadataLaterCalls++
                    [pscustomobject]@{ Status = 'pass'; Issues = @() }
                }
            }
            $savedActions = $env:GITHUB_ACTIONS
            try {
                $env:GITHUB_ACTIONS = if ($Actions) { 'true' } else { '' }
                $output = @(& $CommandName -Path $ModuleContext.Root -Ecosystem $ModuleContext.Ecosystem `
                        -SkipModuleVersionCheck -Verbose:$LogVerbose 3>&1 4>&1 6>&1)
                $result = $output | Where-Object { $_.PSObject.Properties['Steps'] } | Select-Object -Last 1
                $script:metadataToolResolutions | Should -Be 1
                if ($result.Status -ne 'pass') {
                    $result.Steps | Should -HaveCount 1
                    $result.Steps[0].Step | Should -Be 'metadata'
                    $script:metadataLaterCalls | Should -Be 0
                }
                $warnings = @($output | Where-Object {
                        $_ -is [System.Management.Automation.WarningRecord] -or
                        ($_ -is [System.Management.Automation.InformationRecord] -and [string]$_.MessageData -match '^::warning')
                    } | ForEach-Object { [string]$_ })
                $verboseLogs = @($output | Where-Object {
                        $_ -is [System.Management.Automation.VerboseRecord]
                    } | ForEach-Object { [string]$_.Message })
                [pscustomobject]@{ Result = $result; Warnings = $warnings; VerboseLogs = $verboseLogs }
            }
            finally {
                $env:GITHUB_ACTIONS = $savedActions
            }
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: metadata in authoring checks' -Tag Component {
    It 'validates telemetry-free <Ecosystem> <ModuleType> helpers in <Command> with scope=<Scope>' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($kind in @('resource', 'pattern', 'utility')) {
                foreach ($command in @('Invoke-AvmPreCommit', 'Invoke-AvmPrCheck')) {
                    foreach ($scope in @($false, $true)) {
                        @{ Ecosystem = $ecosystem; ModuleType = $kind; Command = $command; Scope = $scope }
                    }
                }
            }
        }
    ) {
        param($Ecosystem, $ModuleType, $Command, $Scope)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
        $fixture.Context.Scope = if ($Scope) { $kind } else { $null }
        $fixture.Data.canonicalType = if ($ModuleType -eq 'resource') { 'Microsoft.Storage/storageAccounts' } else { 'example/module' }
        $fixture.Data.telemetryIdPrefix = $fixture.Data.telemetryIdPrefix.Replace('.res.', ".$kind.")
        Save-AuthoringMetadataFixture -Fixture $fixture
        $childFile = Join-Path $fixture.Paths[1] 'metadata.json'
        $child = Get-Content -LiteralPath $childFile -Raw | ConvertFrom-Json -AsHashtable
        $child.canonicalType = 'helper'
        $child.Remove('telemetryIdPrefix')
        [System.IO.File]::WriteAllText($childFile, ($child | ConvertTo-Json -Depth 20))
        if ($Ecosystem -eq 'bicep') {
            [System.IO.File]::WriteAllText((Join-Path $fixture.Paths[1] 'version.json'), '{"version":"1.0.0"}')
        }
        $before = @(Get-ChildItem $fixture.Root -Recurse -File | Get-FileHash | ForEach-Object Hash)
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'pass'
        ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues | Should -HaveCount 0
        $probe.Warnings | Should -HaveCount 0
        @(Get-ChildItem $fixture.Root -Recurse -File | Get-FileHash | ForEach-Object Hash) | Should -Be $before
    }

    It 'does not let a helper prefix redefine its <Ecosystem> <ModuleType> family in a renamed checkout' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($kind in @('resource', 'pattern', 'utility')) {
                @{ Ecosystem = $ecosystem; ModuleType = $kind }
            }
        }
    ) {
        param($Ecosystem, $ModuleType)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        $fixture.Context.Scope = $null
        $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
        $otherKind = if ($ModuleType -eq 'resource') { 'ptn' } else { 'res' }
        $fixture.Data.canonicalType = if ($ModuleType -eq 'resource') { 'Microsoft.Storage/storageAccounts' } else { 'example/module' }
        $fixture.Data.telemetryIdPrefix = $fixture.Data.telemetryIdPrefix.Replace('.res.', ".$kind.")
        Save-AuthoringMetadataFixture -Fixture $fixture
        $childFile = Join-Path $fixture.Paths[1] 'metadata.json'
        $child = Get-Content -LiteralPath $childFile -Raw | ConvertFrom-Json -AsHashtable
        $child.canonicalType = 'helper'
        $child.telemetryIdPrefix = $child.telemetryIdPrefix.Replace(".$kind.", ".$otherKind.")
        [System.IO.File]::WriteAllText($childFile, ($child | ConvertTo-Json -Depth 20))
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPrCheck
        $probe.Result.Status | Should -Be 'fail'
        $issues = ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues
        $issues | Should -HaveCount 1
        $issues[0].Code | Should -Be 'AVM_METADATA_TELEMETRY'
        $issues[0].File | Should -Match 'blob-service/metadata.json$'
    }

    It 'rejects helper metadata at a <Ecosystem> <ModuleType> root in <Command>' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($kind in @('resource', 'pattern', 'utility')) {
                foreach ($command in @('Invoke-AvmPreCommit', 'Invoke-AvmPrCheck')) {
                    @{ Ecosystem = $ecosystem; ModuleType = $kind; Command = $command }
                }
            }
        }
    ) {
        param($Ecosystem, $ModuleType, $Command)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem
        $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
        $fixture.Context.Scope = $kind
        $fixture.Data.canonicalType = 'helper'
        $fixture.Data.telemetryIdPrefix = $fixture.Data.telemetryIdPrefix.Replace('.res.', ".$kind.")
        Save-AuthoringMetadataFixture -Fixture $fixture
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'fail'
        $issues = ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues
        $issues | Should -HaveCount 1
        $issues[0].Code | Should -Be 'AVM_METADATA_SCHEMA'
        $issues[0].File | Should -BeExactly 'metadata.json'
        $probe.Warnings | Should -HaveCount 0
    }

    It 'validates Oracle roots and children without changing files in <Command> for <Ecosystem>' -TestCases @(
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPrCheck' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPrCheck' }
    ) {
        param($Ecosystem, $Command)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        $fixture.Context.Scope = $null
        $fixture.Data.canonicalType = 'Oracle.Database/cloudVmClusters'
        Save-AuthoringMetadataFixture -Fixture $fixture
        if ($Ecosystem -eq 'bicep') {
            $childFile = Join-Path $fixture.Paths[1] 'metadata.json'
            $child = Get-Content -LiteralPath $childFile -Raw | ConvertFrom-Json -AsHashtable
            $child.Remove('telemetryIdPrefix')
            [System.IO.File]::WriteAllText($childFile, ($child | ConvertTo-Json -Depth 20))
        }
        $before = @(Get-ChildItem $fixture.Root -Recurse -File | Get-FileHash | ForEach-Object Hash)
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'pass'
        ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues | Should -HaveCount 0
        $probe.Warnings | Should -HaveCount 0
        @(Get-ChildItem $fixture.Root -Recurse -File | Get-FileHash | ForEach-Object Hash) | Should -Be $before
    }

    It 'discovers Oracle metadata-only children and reports missing telemetry for <Ecosystem>' -TestCases @(
        @{ Ecosystem = 'bicep'; Extension = 'bicep' }
        @{ Ecosystem = 'terraform'; Extension = 'tf' }
    ) {
        param($Ecosystem, $Extension)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        $fixture.Context.Scope = $null
        $fixture.Data.canonicalType = 'Oracle.Database/autonomousDatabases'
        Save-AuthoringMetadataFixture -Fixture $fixture
        $childFile = Join-Path $fixture.Paths[1] 'metadata.json'
        $child = Get-Content -LiteralPath $childFile -Raw | ConvertFrom-Json -AsHashtable
        $child.Remove('telemetryIdPrefix')
        [System.IO.File]::WriteAllText($childFile, ($child | ConvertTo-Json -Depth 20))
        [System.IO.File]::Delete((Join-Path $fixture.Paths[1] "main.$Extension"))
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPrCheck
        $probe.Result.Status | Should -Be 'fail'
        $issues = ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues
        $issues | Should -HaveCount 1
        $issues[0].Code | Should -Be 'AVM_METADATA_TELEMETRY'
        $issues[0].File | Should -Match 'blob-service/metadata.json$'
        $probe.Warnings | Should -HaveCount 0
    }

    It 'returns actionable errors for missing metadata in CI' {
        $fixture = New-AuthoringMetadataFixture -Ecosystem terraform -Child
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPrCheck -Actions
        $probe.Result.Status | Should -Be 'fail'
        $probe.Warnings | Should -HaveCount 0
        $issues = $probe.Result.Steps[0].Result.Issues
        $issues.File | Should -Be @('metadata.json', 'modules/blob-service/metadata.json')
        $issues[0].Message | Should -Match 'avm metadata initialize'
    }

    It 'fails fast for missing <Ecosystem> root and child metadata in <Command>' -TestCases @(
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPrCheck' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPrCheck' }
    ) {
        param($Ecosystem, $Command)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'fail'
        $metadata = $probe.Result.Steps | Where-Object Step -eq 'metadata'
        $metadata.Status | Should -Be 'fail'
        $metadata.Result.Issues | Should -HaveCount 2
        @($metadata.Result.Issues | Where-Object Severity -ne 'error') | Should -HaveCount 0
        $probe.Warnings | Should -HaveCount 0
        foreach ($path in $fixture.Paths) {
            Test-Path -LiteralPath (Join-Path $path 'metadata.json') | Should -BeFalse
        }
    }

    It 'logs validated paths and results for <Command> in verbose mode' -TestCases @(
        @{ Command = 'Invoke-AvmPreCommit' }
        @{ Command = 'Invoke-AvmPrCheck' }
    ) {
        param($Command)
        $fixture = New-AuthoringMetadataFixture -Ecosystem terraform -Child
        Save-AuthoringMetadataFixture -Fixture $fixture
        $childFile = Join-Path $fixture.Paths[1] 'metadata.json'
        [System.IO.File]::Delete($childFile)

        $failed = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command -LogVerbose
        $failed.Result.Status | Should -Be 'fail'
        $failedLogs = $failed.VerboseLogs -join "`n"
        $failedLogs | Should -Match 'metadata: discovered 2 module scope\(s\)'
        $failedLogs | Should -Match 'metadata: validating metadata\.json \(root\)'
        $failedLogs | Should -Match 'metadata: validating modules/blob-service/metadata\.json \(child\)'
        $failedLogs | Should -Match 'metadata: \[AVM_METADATA_MISSING\] modules/blob-service/metadata\.json:'
        $failedLogs | Should -Match 'metadata: checked 2 module scope\(s\); status=fail; issues=1'

        Save-AuthoringMetadataFixture -Fixture $fixture
        $passed = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command -LogVerbose
        $passed.Result.Status | Should -Be 'pass'
        ($passed.VerboseLogs -join "`n") | Should -Match 'metadata: checked 2 module scope\(s\); status=pass; issues=0'
    }

    It 'validates <Ecosystem> roots and children without changing files in <Command>' -TestCases @(
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPrCheck' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPrCheck' }
    ) {
        param($Ecosystem, $Command)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        Save-AuthoringMetadataFixture -Fixture $fixture
        $before = @(Get-ChildItem $fixture.Root -Recurse -File | Get-FileHash | ForEach-Object Hash)
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'pass'
        ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues | Should -HaveCount 0
        $probe.Warnings | Should -HaveCount 0
        @(Get-ChildItem $fixture.Root -Recurse -File | Get-FileHash | ForEach-Object Hash) | Should -Be $before
    }

    It 'fails for invalid existing <Ecosystem> child metadata in <Command>' -TestCases @(
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPrCheck' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPrCheck' }
    ) {
        param($Ecosystem, $Command)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        Save-AuthoringMetadataFixture -Fixture $fixture
        $childFile = Join-Path $fixture.Paths[1] 'metadata.json'
        [System.IO.File]::WriteAllText($childFile, '{}')
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'fail'
        $metadata = $probe.Result.Steps | Where-Object Step -eq 'metadata'
        $metadata.Status | Should -Be 'fail'
        $metadata.Result.Issues[0].File | Should -Match 'blob-service/metadata.json$'
        [System.IO.File]::ReadAllText($childFile) | Should -BeExactly '{}'
    }

    It 'rejects obsolete <Ecosystem> root metadata property <Property> in <Command>' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($command in @('Invoke-AvmPreCommit', 'Invoke-AvmPrCheck')) {
                foreach ($legacy in @(
                        @{ Property = 'owners'; Value = @{ individuals = @() } }
                        @{ Property = 'tier'; Value = 'core' }
                        @{ Property = 'schemaVersion'; Value = 1 }
                    )) {
                    @{ Ecosystem = $ecosystem; Command = $command; Property = $legacy.Property; Value = $legacy.Value }
                }
            }
        }
    ) {
        param($Ecosystem, $Command, $Property, $Value)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem
        $fixture.Data[$Property] = $Value
        Save-AuthoringMetadataFixture -Fixture $fixture
        $before = @(Get-ChildItem $fixture.Root -Recurse -File | Get-FileHash | ForEach-Object Hash)
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'fail'
        $metadata = $probe.Result.Steps | Where-Object Step -eq 'metadata'
        $metadata.Status | Should -Be 'fail'
        $metadata.Result.Issues[0].Code | Should -Be 'AVM_METADATA_SCHEMA'
        $probe.Warnings | Should -HaveCount 0
        @(Get-ChildItem $fixture.Root -Recurse -File | Get-FileHash | ForEach-Object Hash) | Should -Be $before
    }

    It 'fails a Bicep source mismatch rather than repairing either file' {
        $fixture = New-AuthoringMetadataFixture -Ecosystem bicep
        $fixture.Data.moduleDescription = 'Does not match the source.'
        Save-AuthoringMetadataFixture -Fixture $fixture
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPrCheck
        $probe.Result.Status | Should -Be 'fail'
        ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues[0].Code | Should -Be 'AVM_METADATA_SOURCE'
        Get-Content (Join-Path $fixture.Root 'main.bicep') -Raw | Should -Match 'Creates storage\.'
    }

    It 'rejects incorrect metadata casing instead of treating it as missing' {
        $fixture = New-AuthoringMetadataFixture -Ecosystem terraform
        [System.IO.File]::WriteAllText((Join-Path $fixture.Root 'Metadata.json'), '{}')
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPreCommit
        $probe.Result.Status | Should -Be 'fail'
        ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues[0].Code | Should -Be 'AVM_METADATA_CASE'
        $probe.Warnings | Should -HaveCount 0
    }

    It 'does not validate test or example metadata as <Ecosystem> module metadata' -TestCases @(
        @{ Ecosystem = 'bicep'; Extension = 'bicep' }
        @{ Ecosystem = 'terraform'; Extension = 'tf' }
    ) {
        param($Ecosystem, $Extension)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        Save-AuthoringMetadataFixture -Fixture $fixture
        foreach ($directory in @('tests', 'examples', '.test', 'node_modules')) {
            $path = Join-Path $fixture.Paths[1] $directory 'helper'
            $null = New-Item -ItemType Directory -Path $path -Force
            [System.IO.File]::WriteAllText((Join-Path $path "main.$Extension"), '')
            [System.IO.File]::WriteAllText((Join-Path $path 'metadata.json'), '{}')
        }
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPrCheck
        $probe.Result.Status | Should -Be 'pass'
        ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues | Should -HaveCount 0
    }

    It 'requires metadata for deep <Ecosystem> children in <Command>' -TestCases @(
        foreach ($ecosystem in @('bicep', 'terraform')) {
            foreach ($command in @('Invoke-AvmPreCommit', 'Invoke-AvmPrCheck')) {
                @{ Ecosystem = $ecosystem; Command = $command }
            }
        }
    ) {
        param($Ecosystem, $Command)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        Save-AuthoringMetadataFixture -Fixture $fixture
        $deepPath = if ($Ecosystem -eq 'terraform') {
            Join-Path $fixture.Paths[1] 'modules' 'container'
        }
        else {
            Join-Path $fixture.Paths[1] 'container'
        }
        $null = New-Item -ItemType Directory -Path $deepPath -Force
        $source = if ($Ecosystem -eq 'terraform') { 'main.tf.json' } else { 'main.bicep' }
        [System.IO.File]::WriteAllText((Join-Path $deepPath $source), '{}')
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'fail'
        $issues = $probe.Result.Steps[0].Result.Issues
        $issues | Should -HaveCount 1
        $issues[0].Code | Should -Be 'AVM_METADATA_MISSING'
        $issues[0].File | Should -Be ([System.IO.Path]::GetRelativePath($fixture.Root, (Join-Path $deepPath 'metadata.json')).Replace('\', '/'))
    }

    It 'fails for malformed JSON without running later steps in <Command>' -TestCases @(
        @{ Command = 'Invoke-AvmPreCommit' }
        @{ Command = 'Invoke-AvmPrCheck' }
    ) {
        param($Command)
        $fixture = New-AuthoringMetadataFixture -Ecosystem terraform
        [System.IO.File]::WriteAllText((Join-Path $fixture.Root 'metadata.json'), '{')
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'fail'
        $probe.Result.Steps[0].Result.Issues[0].Code | Should -Be 'AVM_METADATA_INVALID'
    }

    It 'validates Bicep monorepo roots and deep children without requiring metadata on grouping directories' {
        $fixture = New-AuthoringMetadataFixture -Ecosystem bicep
        $modulePath = Join-Path $fixture.Root 'avm' 'res' 'storage' 'storage-account'
        $childPath = Join-Path $modulePath 'blob-service' 'container'
        $null = New-Item -ItemType Directory -Path $childPath -Force
        foreach ($path in @($modulePath, $childPath)) {
            [System.IO.File]::WriteAllText((Join-Path $path 'main.bicep'), "metadata name = 'Storage'`nmetadata description = 'Creates storage.'`n")
        }
        $fixture.Paths = @($modulePath, $childPath)
        $fixture.Root = $modulePath
        Save-AuthoringMetadataFixture -Fixture $fixture
        $fixture.Context.Kind = 'bicep-monorepo'
        $fixture.Context.Scope = $null
        $fixture.Root = $fixture.Context.Root
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPrCheck
        $probe.Result.Status | Should -Be 'pass'
        $probe.Warnings | Should -HaveCount 0
        [System.IO.File]::WriteAllText((Join-Path $childPath 'metadata.json'), '{}')
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPreCommit
        $probe.Result.Status | Should -Be 'fail'
        ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues[0].File |
            Should -Be 'avm/res/storage/storage-account/blob-service/container/metadata.json'
    }

    It 'validates a single canonical type on grouped Bicep <Kind> roots and reduced children' -TestCases @(
        @{ Kind = 'ptn'; Canonical = 'alz' }
        @{ Kind = 'utl'; Canonical = 'naming' }
    ) {
        param($Kind, $Canonical)
        $fixture = New-AuthoringMetadataFixture -Ecosystem bicep
        $modulePath = Join-Path $fixture.Root 'avm' $Kind 'group' 'module'
        $childPath = Join-Path $modulePath 'child'
        $null = New-Item -ItemType Directory -Path $childPath -Force
        foreach ($path in @($modulePath, $childPath)) {
            [System.IO.File]::WriteAllText((Join-Path $path 'main.bicep'), "metadata name = 'Storage'`nmetadata description = 'Creates storage.'`n")
        }
        $fixture.Data.canonicalType = $Canonical
        if ($Kind -eq 'utl') { $fixture.Data.Remove('telemetryIdPrefix') }
        else { $fixture.Data.telemetryIdPrefix = "46d3xbcp.ptn.$Canonical" }
        $fixture.Paths = @($modulePath, $childPath)
        $fixture.Root = $modulePath
        Save-AuthoringMetadataFixture -Fixture $fixture
        $fixture.Context.Scope = $null
        $monorepo = $fixture.Context.Root
        foreach ($path in @($monorepo, $modulePath, $childPath)) {
            $fixture.Context.Root = $path
            $fixture.Context.Kind = if ($path -ceq $monorepo) { 'bicep-monorepo' } else { 'bicep-module' }
            foreach ($command in @('Invoke-AvmPreCommit', 'Invoke-AvmPrCheck')) {
                $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $command
                $probe.Result.Status | Should -Be 'pass'
                ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues | Should -HaveCount 0
                $probe.Warnings | Should -HaveCount 0
            }
        }
    }

    It 'does not turn a disabled child into a missing-file warning or a skipped validation' {
        $fixture = New-AuthoringMetadataFixture -Ecosystem terraform -Child
        Save-AuthoringMetadataFixture -Fixture $fixture
        $disabled = Join-Path $fixture.Paths[1] '.avm'
        $null = New-Item -ItemType Directory -Path $disabled
        [System.IO.File]::WriteAllText((Join-Path $disabled '.disable'), '')
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPreCommit
        $probe.Result.Status | Should -Be 'fail'
        ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues[0].Code | Should -Be 'AVM_METADATA_DISABLED'
        $probe.Warnings | Should -HaveCount 0
    }
}
