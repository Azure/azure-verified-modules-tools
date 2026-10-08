#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepServiceRetry.ps1')
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep native service retry <Kind>' -Tag Component -ForEach @(
    @{ Kind = 'SearchSku' }, @{ Kind = 'SearchSemantic' }
    @{ Kind = 'ContainerApps' }, @{ Kind = 'ContainerAppsNewCluster' }
) {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:options.Remove('ResourceLocation')
        $script:fixture.Schema = 'subscriptionDeploymentTemplate'
        $service = New-BicepServiceRetryFixture -Kind $Kind -SubscriptionId $script:options.SubscriptionId
        $script:fixture.TransientResourceType = $service.Provider
        $errorJson = $service.Response.error | ConvertTo-Json -Depth 20 -Compress
        $serviceId = $service.ResourceId
        $script:fixture.RegionalErrorFactory = {
            param([string] $Region, [string] $Target)
            $json = $errorJson
            if ($Region) { $json = $json.Replace('eastus', $Region) }
            if ($Target) { $json = $json.Replace($serviceId, $Target) }
            $json | ConvertFrom-Json -AsHashtable
        }.GetNewClosure()
        $script:sourcePath = Join-Path $script:fixture.Directory 'main.test.bicep'
        $script:source = [IO.File]::ReadAllText($script:sourcePath)
        Set-Content -LiteralPath (Join-Path $script:fixture.Directory 'deployed.Tests.ps1') -Value 'param($TestInputData)'
    }

    AfterEach {
        [IO.File]::ReadAllText($script:sourcePath) | Should -BeExactly $script:source
        $script:fixture.CurrentSubscription | Should -Be '00000000-0000-0000-0000-000000000099'
        Remove-NativeBicepWorkflowFixture -Fixture $script:fixture
    }

    It 'forwards the selected subscription through validation before the only Create' {
        $script:fixture.RegionalValidationFailures = 1
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        $validations = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate')
        $validations.Parameters.resourceLocation | Should -Be @('eastus', 'centralus')
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Count | Should -Be 1
        $creates[0].Parameters.resourceLocation | Should -Be 'centralus'
        @($script:fixture.NativeInputs.Parameters.baseTime | Sort-Object -Unique).Count | Should -Be 1
        @($script:fixture.NativeInputs.Location | Sort-Object -Unique) | Should -Be @('westus')
        @($script:fixture.NativeInputs.SubscriptionId | Sort-Object -Unique) | Should -Be @($script:options.SubscriptionId)
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
        $script:fixture.Calls | Should -Contain 'pester'
    }

    It 'classifies the same subscription-bound evidence at <Scope> validation scope' -ForEach @(
        @{ Scope = 'sub' }, @{ Scope = 'mg' }, @{ Scope = 'tenant' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{
            Scope = $Scope; Root = $script:fixture.Root; Subscription = $script:options.SubscriptionId
        } {
            param($Scope, $Root, $Subscription)
            $script:serviceValidationCount = 0
            Mock Invoke-AvmBicepNativeArmOperation {
                $script:serviceValidationCount++
                if ($script:serviceValidationCount -eq 1) {
                    $node = & $script:nativeWorkflow.RegionalErrorFactory $Parameters['resourceLocation'] $null
                    throw [Management.Automation.ErrorRecord]::new(
                        [InvalidOperationException]::new('Safe regional validation failure.'),
                        'AvmBicepTemplateValidationFailed', 'InvalidResult', $node)
                }
            }
            $path = Join-Path $Root 'validation.json'
            $template = '{"location":"#_resourceLocation_#"}'
            [IO.File]::WriteAllText($path, $template)
            $inputOptions = @{
                Scope = $Scope; TemplatePath = $path; MetadataLocation = 'westus'; DeploymentName = 'validation'
                Parameters = @{ resourceLocation = ''; baseTime = 'fixed' }
            }
            $result = Test-AvmBicepNativeDeployment -DeploymentInput $inputOptions -TemplateContent $template -SubscriptionId $Subscription
            $result.Attempts | Should -Be 2
            $result.AttemptedRegions | Should -Be @('eastus', 'centralus')
            $result.DeploymentInput.Parameters.baseTime | Should -Be 'fixed'
            $inputOptions.Parameters.resourceLocation | Should -Be ''
            [IO.File]::ReadAllText($path) | Should -BeExactly '{"location":"centralus"}'
            Should -Invoke Invoke-AvmBicepNativeArmOperation -Exactly 2 -ParameterFilter { $Operation -eq 'Validate' }
        }
    }

    It 'bounds validation to three candidates without recording a submission' {
        $script:fixture.RegionalValidationFailures = 3
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $validations = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate')
        $validations.Parameters.resourceLocation | Should -Be @('eastus', 'centralus', 'westus2')
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 0
        $script:fixture.RestInputs.Count | Should -Be 0
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).deployments.Count | Should -Be 0
    }

    It 'refuses validation relocation for <Restriction>' -ForEach @(
        @{ Restriction = 'explicit region' }, @{ Restriction = 'resource-group scope' }
        @{ Restriction = 'global placement' }, @{ Restriction = 'no movable region' }
    ) {
        $script:fixture.RegionalValidationFailures = 1
        switch ($Restriction) {
            'explicit region' { $script:options.ResourceLocation = 'eastus' }
            'resource-group scope' { $script:fixture.Schema = 'deploymentTemplate' }
            'global placement' {
                Mock Get-AvmBicepResourceLocation -ModuleName Avm.Authoring {
                    [pscustomobject]@{ Location = 'eastus'; IsGlobal = $true }
                }
            }
            'no movable region' { $script:fixture.Parameters.Remove('resourceLocation') }
        }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 1
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 0
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 0
    }

    It 'cleans complete operation evidence and confirms absent history before changing regions' {
        $script:fixture.RegionalFailures = 1
        $script:fixture.RecordVisibilityReads = 2
        $script:fixture.RecordVisibilityState = 'Deleting'
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.CleanupPending.Count | Should -Be 0
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Parameters.resourceLocation | Should -Be @('eastus', 'centralus')
        @($creates.Parameters.baseTime | Sort-Object -Unique).Count | Should -Be 1
        $creates.Location | Should -Be @('westus', 'westus')
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 2
        $deletions = @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' })
        $deletions.Count | Should -Be 1
        $confirmations = @($script:fixture.Calls | Where-Object { $_ -like 'confirm-record:*' })
        $confirmations.Count | Should -Be 3
        $script:fixture.Calls.IndexOf("purge:$($script:fixture.CreatedId)") | Should -BeLessThan $script:fixture.Calls.IndexOf($deletions[0])
        $script:fixture.Calls.LastIndexOf($confirmations[-1]) | Should -BeLessThan $script:fixture.Calls.LastIndexOf('validate')
        $script:fixture.Calls.LastIndexOf('validate') | Should -BeLessThan $script:fixture.Calls.LastIndexOf('create')
    }

    It 'keeps both budgets bounded when exhausted regions leave only in-place retries' {
        $script:fixture.RegionalValidationFailures = 1
        $script:fixture.RegionalFailures = 3
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Parameters.resourceLocation | Should -Be @('centralus', 'westus2', 'westus2')
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Parameters.resourceLocation |
            Should -Be @('eastus', 'centralus', 'westus2')
        @($script:fixture.Calls | Where-Object { $_ -like 'delete-record:*' }).Count | Should -Be 1
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).deployments[-1].id | Should -BeLike '*-t3'
        $script:fixture.Calls | Should -Not -Contain 'pester'
    }

    It 'does not relocate a retained deployment' {
        $script:fixture.RegionalFailures = 1
        $script:options.KeepResources = $true
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $creates = @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create')
        $creates.Parameters.resourceLocation | Should -Be @('eastus', 'eastus')
        @($script:fixture.Calls | Where-Object { $_ -match '^(delete-record|remove|purge):' }).Count | Should -Be 0
    }

    It 'never replays when <Obstacle> prevents confirmed complete cleanup' -ForEach @(
        @{ Obstacle = 'resource removal' }, @{ Obstacle = 'history visibility' }, @{ Obstacle = 'history authorization' }
    ) {
        $script:fixture.RegionalFailures = 1
        switch ($Obstacle) {
            'resource removal' { $script:fixture.CleanupFails = $true }
            'history visibility' { $script:fixture.RecordVisibilityReads = 6; $script:fixture.RecordVisibilityState = 'Deleting' }
            'history authorization' { $script:fixture.RecordConfirmationDenied = $true }
        }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.CleanupPending.Count | Should -BeGreaterThan 0
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Create').Count | Should -Be 1
        @($script:fixture.NativeInputs | Where-Object Operation -eq 'Validate').Count | Should -Be 1
        $script:fixture.Calls | Should -Not -Contain 'pester'
    }
}
