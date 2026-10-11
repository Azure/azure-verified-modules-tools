#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep required subscription providers' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:registry = Join-Path $TestDrive ('registry-' + [guid]::NewGuid().ToString('N'))
        $root = Join-Path $script:registry 'avm' 'res' 'example' 'module'
        $null = New-Item -ItemType Directory -Path (Split-Path $root) -Force
        Move-Item -LiteralPath $script:fixture.Root -Destination $root
        $script:fixture.Root = $root
        $script:fixture.Directory = Join-Path $root 'tests' 'e2e' 'defaults'
        $script:options.Path = $root
        $script:providerMap = Join-Path $script:registry '.required-resource-providers.json'
        Set-Content -LiteralPath $script:providerMap -Value '{"avm/res/example/module":["Microsoft.Compute"]}'
        InModuleScope Avm.Authoring {
            $script:providerScenario = @{ State = 'Registered'; FeatureState = 'Registered' }
            $script:resolveNativeTokens = (Get-Command Resolve-AvmBicepTestToken).ScriptBlock
            Mock Resolve-AvmBicepTestToken {
                $script:nativeWorkflow.Calls.Add('tokens')
                & $script:resolveNativeTokens @PesterBoundParameters
            }
            $script:resolveNativeParameterTokens = (Get-Command Resolve-AvmBicepParameterToken).ScriptBlock
            Mock Resolve-AvmBicepParameterToken {
                $script:nativeWorkflow.Calls.Add('parameter-tokens')
                & $script:resolveNativeParameterTokens @PesterBoundParameters
            }
            Mock Assert-AvmBicepAzureIdentity {
                $script:nativeWorkflow.Calls.Add('identity')
                $SubscriptionId | Should -Be $script:nativeWorkflow.CurrentSubscription
                $TenantId | Should -Be $script:nativeWorkflow.CurrentTenant
                if ($script:nativeWorkflow.IdentityMismatch) { throw [AvmConfigurationException]::new('Test identity mismatch.') }
            }
            Mock Resolve-AvmAzureCli { [pscustomobject]@{ Path = 'fake-az'; ArgumentPrefix = [string[]]@(); EnvVars = @{} } }
            Mock Invoke-AvmProcess {
                param($ArgumentList)
                $fixture = $script:nativeWorkflow
                $kind = $ArgumentList[0]
                $operation = $ArgumentList[1]
                $namespace = $ArgumentList[[array]::IndexOf($ArgumentList, '--namespace') + 1]
                $subscription = $ArgumentList[[array]::IndexOf($ArgumentList, '--subscription') + 1]
                $subscription | Should -BeExactly $fixture.CurrentSubscription
                $fixture.Calls[-1] | Should -BeExactly 'identity'
                $fixture.Calls.Add("${kind}:${operation}:${subscription}:$namespace")
                if ($operation -eq 'register') {
                    if ($kind -eq 'feature') { $script:providerScenario.FeatureState = 'Registered' }
                    else { $script:providerScenario.State = 'Registered' }
                    return [pscustomobject]@{ StdOut = ''; ExitCode = 0 }
                }
                $response = if ($kind -eq 'feature') {
                    $name = $ArgumentList[[array]::IndexOf($ArgumentList, '--name') + 1]
                    @{
                        id = "/subscriptions/$subscription/providers/Microsoft.Features/providers/$namespace/features/$name"
                        name = "$namespace/$name"; properties = @{ state = $script:providerScenario.FeatureState }
                    }
                }
                else {
                    @{
                        id = "/subscriptions/$subscription/providers/$namespace"
                        namespace = $namespace; registrationState = $script:providerScenario.State
                    }
                }
                [pscustomobject]@{ StdOut = $response | ConvertTo-Json -Depth 5 -Compress; ExitCode = 0 }
            } -ParameterFilter { $FilePath -eq 'fake-az' }
        }
    }

    AfterEach { Remove-NativeBicepWorkflowFixture -Fixture $script:fixture }

    It 'registers providers after compilation and identity checks but before token replacement and validation' {
        $capability = (Get-Module Avm.Authoring).PrivateData.AvmCapabilities.BicepRequiredResourceProviders
        $capability | Should -BeOfType ([int])
        $capability | Should -Be 1
        InModuleScope Avm.Authoring { $script:providerScenario.State = 'NotRegistered' }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $registration = "provider:register:$($script:options.SubscriptionId):Microsoft.Compute"
        $script:fixture.Calls | Should -Contain $registration
        $script:fixture.Calls.IndexOf('compile') | Should -BeLessThan $script:fixture.Calls.IndexOf($registration)
        $script:fixture.Calls.IndexOf($registration) | Should -BeLessThan $script:fixture.Calls.IndexOf('tokens')
        $script:fixture.Calls.IndexOf('tokens') | Should -BeLessThan $script:fixture.Calls.IndexOf('validate')
        $script:fixture.Calls.IndexOf($registration) | Should -BeLessThan $script:fixture.Calls.IndexOf('parameter-tokens')
        $script:fixture.Calls.IndexOf('parameter-tokens') | Should -BeLessThan $script:fixture.Calls.IndexOf('validate')
        $script:fixture.Calls | Should -Contain 'create'
        Should -Invoke Assert-AvmBicepAzureIdentity -ModuleName Avm.Authoring -ParameterFilter {
            $SubscriptionId -eq '00000000-0000-0000-0000-000000000001' -and $TenantId -eq '00000000-0000-0000-0000-000000000002'
        }
    }

    It 'completes feature propagation before provider requirements without a second registration' {
        Set-Content -LiteralPath (Join-Path $script:registry '.required-features.json') `
            -Value '{"avm/res/example/module":["Microsoft.Compute/TestFeature"]}'
        InModuleScope Avm.Authoring {
            $script:providerScenario.FeatureState = 'NotRegistered'
            $script:providerScenario.State = 'NotRegistered'
        }
        (Invoke-AvmTestE2e @script:options).Status | Should -Be 'pass'
        $events = @($script:fixture.Calls | Where-Object { $_ -match '^(feature|provider):' } |
                ForEach-Object { ($_ -split ':')[0..1] -join ':' })
        $events | Should -Be @('feature:show', 'feature:register', 'feature:show', 'provider:register', 'provider:show', 'provider:show')
        $script:fixture.Calls.IndexOf('tokens') | Should -BeGreaterThan (
            $script:fixture.Calls.LastIndexOf("provider:show:$($script:options.SubscriptionId):Microsoft.Compute"))
    }

    It 'stops before token replacement or any resource mutation after a <Kind> failure' -ForEach @(
        @{ Kind = 'provider' }, @{ Kind = 'feature' }
    ) {
        if ($Kind -eq 'feature') {
            Set-Content -LiteralPath (Join-Path $script:registry '.required-features.json') `
                -Value '{"avm/res/example/module":["Microsoft.Compute/TestFeature"]}'
        }
        InModuleScope Avm.Authoring -Parameters @{ Kind = $Kind } {
            param($Kind)
            if ($Kind -eq 'feature') { $script:providerScenario.FeatureState = 'Pending' }
            else { $script:providerScenario.State = 'Pending' }
        }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        $result.Issues.Code | Should -Contain "avm.bicep.e2e-$Kind-registration-failed"
        foreach ($event in @('tokens', 'parameter-tokens', 'validate', 'create', 'group-create', 'pester', 'post')) {
            $script:fixture.Calls | Should -Not -Contain $event
        }
        if ($Kind -eq 'feature') { @($script:fixture.Calls | Where-Object { $_ -like 'provider:*' }).Count | Should -Be 0 }
        Test-Path -LiteralPath $script:fixture.StatePath | Should -BeFalse
    }

    It 'rejects an invalid unselected provider entry before dependency preparation or compilation' {
        Set-Content -LiteralPath $script:providerMap -Value '{"avm/res/example/module":[],"avm/res/other/module":["bad"]}'
        { Invoke-AvmTestE2e @script:options } | Should -Throw '*avm/res/other/module*'
        Should -Invoke Assert-AvmBicepAzureDependency -ModuleName Avm.Authoring -Exactly 0
        Should -Invoke Invoke-AvmBicepAzureContext -ModuleName Avm.Authoring -Exactly 0
        $script:fixture.Calls.Count | Should -Be 0
    }

    It 'validates WhatIf without preparing dependencies, replacing tokens or calling Azure' {
        $result = Invoke-AvmTestE2e @script:options -WhatIf
        $result.Status | Should -Be 'skipped'
        Should -Invoke Assert-AvmBicepAzureDependency -ModuleName Avm.Authoring -Exactly 0
        Should -Invoke Invoke-AvmBicepAzureContext -ModuleName Avm.Authoring -Exactly 0
        $script:fixture.Calls.Count | Should -Be 0
    }

    It 'rejects a malformed <Identity> before registration' -ForEach @(
        @{ Identity = 'SubscriptionId' }, @{ Identity = 'TenantId' }
    ) {
        $script:options[$Identity] = 'not-a-guid'
        { Invoke-AvmTestE2e @script:options } | Should -Throw
        $script:fixture.Calls.Count | Should -Be 0
    }

    It 'does not run registration when the selected login identity cannot be verified' {
        $script:fixture.IdentityMismatch = $true
        { Invoke-AvmTestE2e @script:options } | Should -Throw '*identity mismatch*'
        @($script:fixture.Calls | Where-Object { $_ -match '^(feature|provider):|^tokens$' }).Count | Should -Be 0
    }

    It 'registers once per selected target across multiple cases: <Targets>' -ForEach @(
        @{ Targets = 'same subscription'; Reads = 1 }
        @{ Targets = 'separate subscriptions'; Reads = 2 }
    ) {
        $other = Join-Path $script:fixture.Root 'tests' 'e2e' 'other'
        $null = New-Item -ItemType Directory -Path $other
        Copy-Item -LiteralPath (Join-Path $script:fixture.Directory 'main.test.bicep') -Destination $other
        $script:options.Recurse = $true
        $script:options.Remove('CleanupStatePath')
        $script:fixture.StatePath = ''
        if ($Targets -eq 'separate subscriptions') {
            $script:options.Remove('SubscriptionId')
            $script:options.TestSubscriptionIds =
                '[{"id":"00000000-0000-0000-0000-000000000001","name":"one"},{"id":"00000000-0000-0000-0000-000000000003","name":"two"}]'
        }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'pass'
        $result.RunsTotal | Should -Be 2
        @($script:fixture.Calls | Where-Object { $_ -like 'provider:show:*' }).Count | Should -Be $Reads
    }

    It 'does not read manifests or register providers during Complete or cleanup' {
        (Invoke-AvmTestE2e @script:options -Phase Deploy).Status | Should -Be 'pass'
        $events = @($script:fixture.Calls | Where-Object { $_ -like 'provider:*' -or $_ -eq 'tokens' })
        Set-Content -LiteralPath $script:providerMap -Value '{invalid'
        $result = Invoke-AvmTestE2e -Path $script:fixture.Root -Phase Complete -CleanupStatePath $script:fixture.StatePath `
            -SubscriptionId $script:options.SubscriptionId -TenantId $script:options.TenantId -SkipModuleVersionCheck
        $result.Status | Should -Be 'pass'
        @($script:fixture.Calls | Where-Object { $_ -like 'provider:*' -or $_ -eq 'tokens' }) | Should -Be $events
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw | ConvertFrom-Json).status | Should -Be 'Complete'
    }
}
