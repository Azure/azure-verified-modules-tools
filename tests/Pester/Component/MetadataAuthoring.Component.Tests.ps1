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
                telemetryIdPrefix = if ($Ecosystem -eq 'bicep') { '46d3xbcp.res.storage-account' } else { '46d3xtrf.res.storage-account' }
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
        param([object] $Fixture, [string] $Command, [switch] $Actions)

        InModuleScope Avm.Authoring -Parameters @{ ModuleContext = $Fixture.Context; CommandName = $Command; Actions = $Actions.IsPresent } {
            param($ModuleContext, $CommandName, $Actions)
            Mock Get-AvmModuleContext { $ModuleContext }
            Mock Test-AvmModuleVersion {}
            Mock Resolve-AvmCommandTool { @() }
            Mock Assert-AvmGitWorkingTreeClean {}
            Mock Invoke-AvmHttp { throw 'Metadata validation must not fetch external data.' }
            Mock Invoke-AvmProcess { throw 'These metadata fixtures must not run a subprocess.' }
            foreach ($name in @('Invoke-AvmSync', 'Invoke-AvmFormat', 'Invoke-AvmTransform', 'Invoke-AvmLint', 'Invoke-AvmCheckPolicy', 'Invoke-AvmCheckConvention', 'Invoke-AvmTest', 'Invoke-AvmDocs')) {
                Mock -CommandName $name -MockWith { [pscustomobject]@{ Status = 'pass'; Issues = @() } }
            }
            $savedActions = $env:GITHUB_ACTIONS
            try {
                $env:GITHUB_ACTIONS = if ($Actions) { 'true' } else { '' }
                $output = @(& $CommandName -Path $ModuleContext.Root -Ecosystem $ModuleContext.Ecosystem `
                        -SkipModuleVersionCheck 3>&1 6>&1)
                $result = $output | Where-Object { $_.PSObject.Properties['Steps'] } | Select-Object -Last 1
                $warnings = @($output | Where-Object {
                        $_ -is [System.Management.Automation.WarningRecord] -or
                        ($_ -is [System.Management.Automation.InformationRecord] -and [string]$_.MessageData -match '^::warning')
                    } | ForEach-Object { [string]$_ })
                [pscustomobject]@{ Result = $result; Warnings = $warnings }
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
    It 'emits GitHub warning annotations for missing metadata without failing CI' {
        $fixture = New-AuthoringMetadataFixture -Ecosystem terraform -Child
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPrCheck -Actions
        $probe.Result.Status | Should -Be 'pass'
        $probe.Warnings | Should -HaveCount 2
        ($probe.Warnings -join "`n") | Should -Match '::warning file=metadata.json,line=1'
        ($probe.Warnings -join "`n") | Should -Match 'modules/blob-service/metadata.json'
    }

    It 'warns without failing for missing <Ecosystem> metadata in <Command>' -TestCases @(
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'bicep'; Command = 'Invoke-AvmPrCheck' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPreCommit' }
        @{ Ecosystem = 'terraform'; Command = 'Invoke-AvmPrCheck' }
    ) {
        param($Ecosystem, $Command)
        $fixture = New-AuthoringMetadataFixture -Ecosystem $Ecosystem -Child
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command $Command
        $probe.Result.Status | Should -Be 'pass'
        $metadata = $probe.Result.Steps | Where-Object Step -eq 'metadata'
        $metadata.Status | Should -Be 'pass'
        $metadata.Result.Issues | Should -HaveCount 2
        @($metadata.Result.Issues | Where-Object Severity -ne 'warning') | Should -HaveCount 0
        $probe.Warnings | Should -HaveCount 2
        foreach ($path in $fixture.Paths) {
            Test-Path -LiteralPath (Join-Path $path 'metadata.json') | Should -BeFalse
        }
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

    It 'does not validate test or example metadata as module metadata' {
        $fixture = New-AuthoringMetadataFixture -Ecosystem bicep
        Save-AuthoringMetadataFixture -Fixture $fixture
        foreach ($directory in @('tests', 'examples', '.test', 'modules')) {
            $path = Join-Path $fixture.Root $directory 'helper'
            $null = New-Item -ItemType Directory -Path $path -Force
            [System.IO.File]::WriteAllText((Join-Path $path 'main.bicep'), "metadata name = 'ignored'")
            [System.IO.File]::WriteAllText((Join-Path $path 'metadata.json'), '{}')
        }
        $probe = Invoke-AuthoringMetadataFixture -Fixture $fixture -Command Invoke-AvmPrCheck
        $probe.Result.Status | Should -Be 'pass'
        ($probe.Result.Steps | Where-Object Step -eq 'metadata').Result.Issues | Should -HaveCount 0
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
