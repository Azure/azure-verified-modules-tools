#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    $script:sourceManifest = Join-Path $moduleRoot 'Avm.Authoring.psd1'
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') -SourceManifest $script:sourceManifest
    $script:sourceManifest = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Avm.Authoring.psd1'
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep native parameter objects' -Tag Component {
    It 'preserves file references, ordinary objects, nulls, array shapes and authored names' {
        $path = Join-Path $TestDrive 'native-parameters.json'
        Set-Content -LiteralPath $path -Value @'
{"parameters":{"keys":{"value":["one"]},"count":{"value":0},"empty":{"value":[]},"nested":{"value":[["one"]]},"nil":{"value":null},"object":{"value":{"reference":"ordinary data"}},"secret":{"reference":{"keyVault":{"id":"/subscriptions/example/resourceGroups/example/providers/Microsoft.KeyVault/vaults/example"},"secretName":"credential"}}}}
'@
        InModuleScope Avm.Authoring -Parameters @{ Path = $path } {
            param($Path)
            $result = Get-AvmBicepNativeParameter -ParameterPath $Path
            $result.psbase.Count | Should -Be 7
            $result['keys'].Count | Should -Be 1
            $result['keys'][0] | Should -Be 'one'
            $result['count'] | Should -Be 0
            ($result['empty'] -is [array]) | Should -BeTrue
            $result['empty'].Count | Should -Be 0
            ($result['nested'][0] -is [array]) | Should -BeTrue
            $result['nil'] | Should -BeNullOrEmpty
            ($result['object'] -is [hashtable]) | Should -BeFalse
            $result['object']['reference'] | Should -Be 'ordinary data'
            ($result['secret'] -is [hashtable]) | Should -BeTrue
            $result['secret']['reference']['secretName'] | Should -Be 'credential'
        }
    }

    It 'keeps secure overrides in memory and prevents ordinary reference objects becoming vault lookups' {
        InModuleScope Avm.Authoring {
            $secret = ConvertTo-SecureString 'not-for-a-file' -AsPlainText -Force
            $result = Get-AvmBicepNativeParameter -Parameters @{
                password = $secret; count = 0; Name = 'authored'; object = @{ reference = @{ ordinary = $true } }
            }
            [object]::ReferenceEquals($result['password'], $secret) | Should -BeTrue
            $result['count'] | Should -Be 0
            $result['Name'] | Should -Be 'authored'
            ($result['object'] -is [hashtable]) | Should -BeFalse
            $result['object']['reference']['ordinary'] | Should -BeTrue
        }
    }

    It 'rejects ambiguous or incomplete file entries: <Entry>' -ForEach @(
        @{ Entry = '{"value":"one","reference":{}}' }
        @{ Entry = '{}' }
        @{ Entry = '"not-an-object"' }
    ) {
        $path = Join-Path $TestDrive 'invalid-native-parameters.json'
        Set-Content -LiteralPath $path -Value ('{"parameters":{"input":' + $Entry + '}}')
        InModuleScope Avm.Authoring -Parameters @{ Path = $path } {
            param($Path)
            { Get-AvmBicepNativeParameter -ParameterPath $Path } | Should -Throw -ExpectedMessage '*either value or reference*'
        }
    }
}

Describe 'Component: Bicep native regional validation' -Tag Component {
    BeforeEach {
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive } {
            param($Root)
            $script:templateContent = '{"location":"#_resourceLocation_#"}'
            $script:templatePath = Join-Path $Root 'regional.json'
            [IO.File]::WriteAllText($script:templatePath, $script:templateContent)
            $script:options = @{
                Scope = 'sub'; DeploymentName = 'validation'; MetadataLocation = 'westus'
                TemplatePath = $script:templatePath; Parameters = @{ resourceLocation = ''; baseTime = 'fixed' }
            }
            $script:regions = [Collections.Generic.List[string]]::new()
            Mock Get-AvmBicepResourceLocation {
                $region = if ($UnavailableRegions.Count -eq 0) { 'eastus' } else { 'centralus' }
                [pscustomobject]@{ Location = $region; IsGlobal = $false }
            }
            Mock Invoke-AvmBicepNativeArmOperation {
                throw 'Unexpected native validation.'
            }
        }
    }

    It 'changes only the resource region after a classified validation failure' {
        InModuleScope Avm.Authoring {
            Mock Invoke-AvmBicepNativeArmOperation {
                $script:regions.Add($Parameters['resourceLocation'])
                $MetadataLocation | Should -Be 'westus'
                $Parameters['baseTime'] | Should -Be 'fixed'
                if ($script:regions.Count -eq 1) {
                    throw [Management.Automation.ErrorRecord]::new(
                        [InvalidOperationException]::new('safe validation summary'),
                        'AvmBicepTemplateValidationFailed', 'InvalidResult',
                        @(@{ Code = 'AllocationFailed'; Message = 'Insufficient capacity in the region.' }))
                }
            }
            $result = Test-AvmBicepNativeDeployment -DeploymentInput $script:options `
                -TemplateContent $script:templateContent -ResourceType 'Microsoft.Storage/storageAccounts'
            $result.Attempts | Should -Be 2
            $result.Location | Should -Be 'centralus'
            $result.DeploymentInput.Parameters['resourceLocation'] | Should -Be 'centralus'
            $script:options.Parameters['resourceLocation'] | Should -Be ''
            @($script:regions) | Should -Be @('eastus', 'centralus')
            [IO.File]::ReadAllText($script:templatePath) | Should -Be '{"location":"centralus"}'
        }
    }

    It 'does not change an explicit region or retry unclassified failures: <Mode>' -ForEach @(
        @{ Mode = 'explicit' }
        @{ Mode = 'group' }
        @{ Mode = 'unclassified' }
        @{ Mode = 'global' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Mode = $Mode } {
            param($Mode)
            $extra = @{}
            if ($Mode -eq 'explicit') { $extra.ResourceLocation = 'East US' }
            if ($Mode -eq 'group') { $script:options.Scope = 'group' }
            if ($Mode -eq 'global') {
                Mock Get-AvmBicepResourceLocation { [pscustomobject]@{ Location = 'westus'; IsGlobal = $true } }
            }
            Mock Invoke-AvmBicepNativeArmOperation {
                if ($Mode -eq 'unclassified') { throw [TimeoutException]::new('not regional') }
                throw [Management.Automation.ErrorRecord]::new(
                    [InvalidOperationException]::new('safe validation summary'),
                    'AvmBicepTemplateValidationFailed', 'InvalidResult',
                    @(@{ Code = 'AllocationFailed'; Message = 'Insufficient capacity in the region.' }))
            }
            { Test-AvmBicepNativeDeployment -DeploymentInput $script:options `
                    -TemplateContent $script:templateContent @extra } | Should -Throw
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 1
            [IO.File]::ReadAllText($script:templatePath) | Should -BeExactly $script:templateContent
        }
    }

    It 'rejects conflicting locations before Azure and leaves the pristine temporary template intact' {
        InModuleScope Avm.Authoring {
            { Test-AvmBicepNativeDeployment -DeploymentInput $script:options `
                    -TemplateContent $script:templateContent -ResourceLocation eastus -TokenResourceLocation westus } |
                Should -Throw -ExpectedMessage '*Conflicting resource locations*'
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 0
            [IO.File]::ReadAllText($script:templatePath) | Should -BeExactly $script:templateContent
        }
    }

    It 'classifies SDK-style objects without requiring JSON or a PowerShell custom object' {
        InModuleScope Avm.Authoring {
            $node = [InvalidOperationException]::new('Insufficient capacity in the region.')
            $node | Add-Member -MemberType NoteProperty -Name Code -Value 'AllocationFailed'
            ($node -is [pscustomobject]) | Should -BeFalse
            Test-AvmBicepRetryErrorNode -Node $node | Should -BeTrue
            $node.Code = 'AuthorizationFailed'
            Test-AvmBicepRetryErrorNode -Node $node | Should -BeFalse
        }
    }
}

Describe 'Component: Bicep same-process test scripts' -Tag Component {
    It 'returns output and restores location, overridden environment and exit code: <Action>' -ForEach @(
        @{ Action = 'success'; Text = '"script output"'; ExitCode = 0 }
        @{ Action = 'exit'; Text = 'exit 17'; ExitCode = 17 }
        @{ Action = 'throw'; Text = 'throw [InvalidOperationException]::new("do-not-print-this")'; ExitCode = 0 }
    ) {
        $path = Join-Path $TestDrive ('script-' + $Action + '.ps1')
        Set-Content -LiteralPath $path -Value @"
if ([Environment]::GetEnvironmentVariable('AVM_TEST_NATIVE_NEW', 'Process') -ne 'temporary') { throw 'Missing override' }
Set-Location -LiteralPath `$PSScriptRoot
$Text
"@
        InModuleScope Avm.Authoring -Parameters @{ Path = $path; Root = $TestDrive; Action = $Action; ExpectedExit = $ExitCode } {
            param($Path, $Root, $Action, $ExpectedExit)
            $priorLocation = (Get-Location).Path
            $original = [Environment]::GetEnvironmentVariable('AVM_TEST_NATIVE_NEW', 'Process')
            $priorExit = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
            $priorValue = if ($null -ne $priorExit) { $priorExit.Value } else { $null }
            try {
                [Environment]::SetEnvironmentVariable('AVM_TEST_NATIVE_NEW', [NullString]::Value, 'Process')
                $global:LASTEXITCODE = 29
                if ($Action -eq 'throw') {
                    $caught = $null
                    try { Invoke-AvmBicepTestScript -Path $Path -WorkingDirectory $Root -EnvVars @{ AVM_TEST_NATIVE_NEW = 'temporary' } }
                    catch { $caught = $_ }
                    $caught.Exception.Message | Should -Match 'Bicep test script failed'
                    $caught.Exception.Message | Should -Not -Match 'do-not-print-this'
                }
                else {
                    $run = Invoke-AvmBicepTestScript -Path $Path -WorkingDirectory $Root -EnvVars @{ AVM_TEST_NATIVE_NEW = 'temporary' }
                    $run.ExitCode | Should -Be $ExpectedExit
                    if ($Action -eq 'success') { $run.Output | Should -Be @('script output') }
                }
                (Get-Location).Path | Should -BeExactly $priorLocation
                $global:LASTEXITCODE | Should -Be 29
                ($null -eq [Environment]::GetEnvironmentVariable('AVM_TEST_NATIVE_NEW', 'Process')) | Should -BeTrue
            }
            finally {
                $value = if ($null -eq $original) { [NullString]::Value } else { $original }
                [Environment]::SetEnvironmentVariable('AVM_TEST_NATIVE_NEW', $value, 'Process')
                if ($null -eq $priorExit) { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
                else { $global:LASTEXITCODE = $priorValue }
            }
        }
    }

    It 'validates in-process summaries through the same protocol as isolated Pester' {
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive } {
            param($Root)
            Mock Invoke-AvmBicepTestScript {
                [pscustomobject]@{ ExitCode = 0; Output = @([ordered]@{ Version = '5.7.1'; Total = -1 }) }
            }
            { Invoke-AvmBicepPesterSuite -Mode E2e -Files @('never-run.Tests.ps1') -WorkingDirectory $Root `
                    -TestInputData @{} -InProcess } | Should -Throw -ExpectedMessage '*summary without*'
        }
    }

    It 'preserves an existing or empty environment override on cancellation: <Value>' -ForEach @(
        @{ Value = '' }
        @{ Value = 'original' }
    ) {
        $path = Join-Path $TestDrive 'cancel.ps1'
        Set-Content -LiteralPath $path -Value 'throw [OperationCanceledException]::new("cancelled")'
        InModuleScope Avm.Authoring -Parameters @{ Path = $path; Root = $TestDrive; Value = $Value } {
            param($Path, $Root, $Value)
            $name = 'AVM_TEST_NATIVE_CANCEL'
            $original = [Environment]::GetEnvironmentVariable($name, 'Process')
            try {
                [Environment]::SetEnvironmentVariable($name, $Value, 'Process')
                $expected = [Environment]::GetEnvironmentVariable($name, 'Process')
                { Invoke-AvmBicepTestScript -Path $Path -WorkingDirectory $Root -EnvVars @{ $name = 'temporary' } } |
                    Should -Throw -ExceptionType ([OperationCanceledException])
                [Environment]::GetEnvironmentVariable($name, 'Process') | Should -BeExactly $expected
            }
            finally {
                $restore = if ($null -eq $original) { [NullString]::Value } else { $original }
                [Environment]::SetEnvironmentVariable($name, $restore, 'Process')
            }
        }
    }

    It 'runs real Pester in the signed-in host process without a credential bridge' {
        $directory = Join-Path $TestDrive 'same-process'
        $null = New-Item -ItemType Directory -Path $directory
        Set-Content -LiteralPath (Join-Path $directory 'deployed.Tests.ps1') -Value @'
param($TestInputData)
Describe 'same host contract' {
    It 'retains host identity and deployment outputs' {
        $PID | Should -Be $TestInputData.DeploymentOutputs.process.value
        $global:AvmNativeSameProcessMarker | Should -Be 'host-only'
        $TestInputData.ModuleTestFolderPath | Should -Be $PSScriptRoot
    }
    It 'preserves authored failures as diagnostics' { 'actual' | Should -Be 'expected' }
}
'@
        $driver = Join-Path $directory 'driver.ps1'
        Set-Content -LiteralPath $driver -Value @'
param([string]$Manifest, [string]$DirectoryPath)
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
Import-Module $Manifest -Force
$global:AvmNativeSameProcessMarker = 'host-only'
$summary = & (Get-Module Avm.Authoring) {
    param($DirectoryPath)
    Invoke-AvmBicepPesterSuite -Mode E2e -Files @((Join-Path $DirectoryPath 'deployed.Tests.ps1')) `
        -WorkingDirectory $DirectoryPath -TestInputData @{
            DeploymentOutputs = @{ process = @{ value = $PID; type = 'Int' } }
            ModuleTestFolderPath = $DirectoryPath
        } -InProcess
} $DirectoryPath
[IO.File]::WriteAllText((Join-Path $DirectoryPath 'summary.json'), ($summary | ConvertTo-Json -Depth 8))
'@
        InModuleScope Avm.Authoring -Parameters @{ Driver = $driver; Root = $directory; Manifest = $script:sourceManifest } {
            param($Driver, $Root, $Manifest)
            $null = Invoke-AvmProcess -FilePath ([Environment]::ProcessPath) -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-File', $Driver, '-Manifest', $Manifest, '-DirectoryPath', $Root
            ) -WorkingDirectory $Root -TimeoutSec 60
            $summary = Get-Content -LiteralPath (Join-Path $Root 'summary.json') -Raw | ConvertFrom-Json
            $summary.Total | Should -Be 2
            $summary.Passed | Should -Be 1
            $summary.Failed | Should -Be 1
            $summary.Issues.Count | Should -Be 1
            $summary.Issues[0].Code | Should -Be 'avm.bicep.pester-failed'
            $summary.Issues[0].Message | Should -Match 'expected'
        }
    }
}

Describe 'Component: Bicep authored deployment output contract' -Tag Component {
    It 'preserves SDK-style Value access for real discovery and assertions: <InProcess>' -ForEach @(
        @{ InProcess = $true }
        @{ InProcess = $false }
    ) {
        $directory = Join-Path $TestDrive ('outputs-' + $InProcess)
        $null = New-Item -ItemType Directory -Path $directory
        Set-Content -LiteralPath (Join-Path $directory 'outputs.Tests.ps1') -Value @'
param([hashtable]$TestInputData)
Describe 'authored output contract' {
    BeforeAll {
        $script:resourceId = $TestInputData.DeploymentOutputs.resourceId.Value
    }
    It 'discovers configuration <name> with expected value <value>' -TestCases @(
        $TestInputData.DeploymentOutputs.configurations.Value | ForEach-Object {
            @{ name = $_.name; value = $_.value }
        }
    ) {
        param($name, $value)
        $resourceId | Should -BeExactly 'fixture-only'
        $name | Should -BeIn @('first', 'second')
        $value | Should -BeIn @('one', 'two')
    }
    It 'retains member casing compatibility without changing authored value keys or shapes' {
        $TestInputData.DeploymentOutputs['keys'].Value | Should -Be @('authored')
        $TestInputData.DeploymentOutputs['count'].Value | Should -Be 0
        $TestInputData.DeploymentOutputs.boolean.Value | Should -BeFalse
        $TestInputData.DeploymentOutputs.nil.Value | Should -BeNullOrEmpty
        ($TestInputData.DeploymentOutputs.empty.Value -is [array]) | Should -BeTrue
        $TestInputData.DeploymentOutputs.empty.Value.Count | Should -Be 0
        ($TestInputData.DeploymentOutputs.nested.Value[0] -is [array]) | Should -BeTrue
        $TestInputData.DeploymentOutputs.nested.Value[0][0] | Should -BeExactly 'one'
        $TestInputData.DeploymentOutputs.object.Value['Upper'] | Should -BeExactly 'first'
        $TestInputData.DeploymentOutputs.object.Value['upper'] | Should -BeExactly 'second'
        $TestInputData.DeploymentOutputs.resourceId.value | Should -BeExactly 'fixture-only'
        $TestInputData.DeploymentOutputs.resourceId.Type | Should -BeExactly 'String'
        $TestInputData.ModuleTestFolderPath | Should -BeExactly $PSScriptRoot
    }
}
'@
        $driver = Join-Path $directory 'driver.ps1'
        Set-Content -LiteralPath $driver -Value @'
param([string]$Manifest, [string]$DirectoryPath, [switch]$InProcess)
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
Import-Module $Manifest
$result = & (Get-Module Avm.Authoring) {
    param($DirectoryPath, $InProcess)
    $issues = [Collections.Generic.List[object]]::new()
    $outputJson = '{"properties":{"outputs":{"resourceId":{"type":"String","value":"fixture-only"},"configurations":{"type":"Array","value":[{"name":"first","value":"one"},{"name":"second","value":"two"}]},"keys":{"type":"Array","value":["authored"]},"count":{"type":"Int","value":0},"boolean":{"type":"Bool","value":false},"nil":{"type":"Object","value":null},"empty":{"type":"Array","value":[]},"nested":{"type":"Array","value":[["one"]]},"object":{"type":"Object","value":{"Upper":"first","upper":"second"}}}}}'
    $item = [pscustomobject]@{
        Case = [pscustomobject]@{
            Path = Join-Path $DirectoryPath 'main.test.bicep'
            RelativePath = 'tests/e2e/defaults/main.test.bicep'
            RelativeDirectory = 'tests/e2e/defaults'
        }
        AssertionFiles = [string[]]@((Join-Path $DirectoryPath 'outputs.Tests.ps1'))
    }
    $assertion = Invoke-AvmBicepTestE2eAssertion -Item $item -DeploymentName 'fixture-only' `
        -DeploymentOutput $outputJson -RepositoryRoot $DirectoryPath -Issues $issues -InProcess:$InProcess
    @{ Assertion = $assertion; Issues = $issues.ToArray() }
} $DirectoryPath ([bool]$InProcess)
[IO.File]::WriteAllText((Join-Path $DirectoryPath 'summary.json'), ($result | ConvertTo-Json -Depth 12))
'@
        InModuleScope Avm.Authoring -Parameters @{
            Driver = $driver; Root = $directory; Manifest = $script:sourceManifest; InProcess = $InProcess
        } {
            param($Driver, $Root, $Manifest, $InProcess)
            $arguments = @('-NoProfile', '-NonInteractive', '-File', $Driver,
                '-Manifest', $Manifest, '-DirectoryPath', $Root)
            if ($InProcess) { $arguments += '-InProcess' }
            $null = Invoke-AvmProcess -FilePath ([Environment]::ProcessPath) -ArgumentList $arguments `
                -WorkingDirectory $Root -TimeoutSec 60
            $summary = Get-Content -LiteralPath (Join-Path $Root 'summary.json') -Raw | ConvertFrom-Json
            $summary.Issues | Should -BeNullOrEmpty
            $summary.Assertion.Status | Should -Be 'pass'
            $summary.Assertion.RunsTotal | Should -Be 3
            $summary.Assertion.RunsPassed | Should -Be 3
            $summary.Assertion.RunsFailed | Should -Be 0
            $summary.Assertion.RunsSkipped | Should -Be 0
            $summary.Assertion.RunsFiltered | Should -Be 0
        }
    }
}
