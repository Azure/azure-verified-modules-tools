#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
    $script:subscription = '11111111-2222-4333-8444-555555555555'
    $script:otherSubscription = '99999999-2222-4333-8444-555555555555'
    $script:originalSubscription = $env:ARM_SUBSCRIPTION_ID
}

AfterAll {
    if ($null -eq $script:originalSubscription) {
        Remove-Item Env:\ARM_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
    }
    else {
        $env:ARM_SUBSCRIPTION_ID = $script:originalSubscription
    }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Register-AvmFeature unit orchestration without filesystem or Azure access' {
    BeforeEach {
        $env:ARM_SUBSCRIPTION_ID = $script:subscription
        $script:scenario = [pscustomobject]@{
            Manifest       = '["Microsoft.Compute/EncryptionAtHost"]'
            AccountId      = $script:subscription
            FeatureStates  = [System.Collections.Generic.Queue[string]]::new()
            ProviderStates = [System.Collections.Generic.Queue[string]]::new()
            Failure        = ''
            Calls          = [System.Collections.Generic.List[object]]::new()
        }
        $script:scenario.FeatureStates.Enqueue('NotRegistered')
        $script:scenario.FeatureStates.Enqueue('Registering')
        $script:scenario.FeatureStates.Enqueue('Registered')
        $script:scenario.ProviderStates.Enqueue('Registering')
        $script:scenario.ProviderStates.Enqueue('Registered')
        $scenario = $script:scenario

        Mock Test-AvmModuleVersion -ModuleName Avm.Authoring {}
        Mock Get-AvmModuleContext -ModuleName Avm.Authoring {
            [pscustomobject]@{ Root = 'virtual-module-root' }
        }
        Mock Get-ChildItem -ModuleName Avm.Authoring {
            [pscustomobject]@{
                Name = '.required-features.json'; FullName = 'virtual-feature-manifest'; Length = 128
            }
        }
        Mock Get-Content -ModuleName Avm.Authoring -MockWith ({
                $scenario.Manifest
            }.GetNewClosure())
        Mock Resolve-AvmAzureCli -ModuleName Avm.Authoring {
            [pscustomobject]@{ Path = 'mock-az'; ArgumentPrefix = [string[]]@(); EnvVars = @{} }
        }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith ({
                param($FilePath, $ArgumentList)
                $scenario.Calls.Add([string[]]@($ArgumentList))
                $command = "$($ArgumentList[0]) $($ArgumentList[1])"
                if ($scenario.Failure -ceq $command) {
                    $failure = InModuleScope Avm.Authoring {
                        [AvmProcessException]::new('AuthorizationFailed: test identity denied')
                    }
                    throw $failure
                }
                $stdout = switch ($command) {
                    'account show' {
                        $scenario.AccountId
                        break
                    }
                    'feature show' {
                        $namespace = $ArgumentList[[array]::IndexOf($ArgumentList, '--namespace') + 1]
                        $name = $ArgumentList[[array]::IndexOf($ArgumentList, '--name') + 1]
                        $state = if ($scenario.FeatureStates.Count -gt 0) {
                            $scenario.FeatureStates.Dequeue()
                        }
                        else {
                            'Registered'
                        }
                        ConvertTo-Json -Compress -Depth 4 -InputObject @{
                            id = "/subscriptions/$($scenario.AccountId)/providers/Microsoft.Features/providers/$namespace/features/$name"
                            name = "$namespace/$name"
                            properties = @{ state = $state }
                        }
                        break
                    }
                    'provider show' {
                        $namespace = $ArgumentList[[array]::IndexOf($ArgumentList, '--namespace') + 1]
                        $state = if ($scenario.ProviderStates.Count -gt 0) {
                            $scenario.ProviderStates.Dequeue()
                        }
                        else {
                            'Registered'
                        }
                        ConvertTo-Json -Compress -InputObject @{
                            namespace = $namespace; registrationState = $state
                        }
                        break
                    }
                    { $_ -in @('feature register', 'provider register') } {
                        ''
                        break
                    }
                    default {
                        throw [System.InvalidOperationException]::new("Unexpected Azure CLI command: $command")
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = [string]$stdout; StdErr = '' }
            }.GetNewClosure())
        Mock Start-Sleep -ModuleName Avm.Authoring {}
    }

    It 'validates, registers, polls, propagates, and reports the selected feature' {
        $result = Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription
        $result.Status | Should -BeExactly 'pass'
        $result.FeaturesTotal | Should -Be 1
        $result.RegisteredFeatures | Should -Be @('Microsoft.Compute/EncryptionAtHost')
        $result.AlreadyRegisteredFeatures.Count | Should -Be 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -eq 'feature' -and $ArgumentList[1] -eq 'register' -and
            $ArgumentList -contains '--subscription'
        }
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -eq 'provider' -and $ArgumentList[1] -eq 'register' -and
            $ArgumentList -contains '--subscription'
        }
    }

    It 'skips an absent manifest before resolving Azure CLI' {
        Mock Get-ChildItem -ModuleName Avm.Authoring {}
        $result = Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription
        $result.Status | Should -BeExactly 'skipped'
        $result.FeaturesTotal | Should -Be 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'skips an empty array before resolving Azure CLI' {
        $script:scenario.Manifest = '[]'
        $result = Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription
        $result.Status | Should -BeExactly 'skipped'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'validates the manifest with WhatIf without touching Azure' {
        $result = Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription -WhatIf
        $result.Status | Should -BeExactly 'skipped'
        $result.FeaturesTotal | Should -Be 1
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'leaves already Registered features and providers unchanged' {
        $script:scenario.FeatureStates.Clear()
        $script:scenario.FeatureStates.Enqueue('Registered')
        $result = Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription
        $result.Status | Should -BeExactly 'pass'
        $result.AlreadyRegisteredFeatures | Should -Be @('Microsoft.Compute/EncryptionAtHost')
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[1] -eq 'register'
        }
    }

    It 'rejects invalid manifest shapes before any process invocation (<Case>)' -ForEach @(
        @{ Case = 'object'; Manifest = '{}' }
        @{ Case = 'missing feature'; Manifest = '["Microsoft.Compute/"]' }
        @{ Case = 'duplicate'; Manifest = '["Microsoft.Compute/EncryptionAtHost","microsoft.compute/encryptionathost"]' }
        @{ Case = 'non-string'; Manifest = '[null]' }
        @{ Case = 'broken JSON'; Manifest = '[' }
    ) {
        $script:scenario.Manifest = $Manifest
        { Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription } |
            Should -Throw
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects a mismatched ARM_SUBSCRIPTION_ID before any Azure operation' {
        $env:ARM_SUBSCRIPTION_ID = $script:otherSubscription
        { Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription } |
            Should -Throw '*does not match*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects an Azure CLI account selected to another subscription' {
        $script:scenario.AccountId = $script:otherSubscription
        { Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription } |
            Should -Throw '*Azure CLI is not selected*'
        $script:scenario.Calls.Count | Should -Be 1
    }

    It 'requires approval for a Pending feature instead of attempting registration' {
        $script:scenario.FeatureStates.Clear()
        $script:scenario.FeatureStates.Enqueue('Pending')
        { Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription } |
            Should -Throw '*Pending*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[1] -eq 'register'
        }
    }

    It 'terminates after bounded provider polling' {
        $script:scenario.FeatureStates.Clear()
        $script:scenario.FeatureStates.Enqueue('NotRegistered')
        $script:scenario.FeatureStates.Enqueue('Registered')
        $script:scenario.ProviderStates.Clear()
        $script:scenario.ProviderStates.Enqueue('Registering')
        $script:scenario.ProviderStates.Enqueue('Registering')
        { Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription `
                -MaximumPolls 2 -PollIntervalSeconds 1 } |
            Should -Throw '*Provider Microsoft.Compute did not reach Registered*'
        Should -Invoke Start-Sleep -ModuleName Avm.Authoring -Exactly 1
    }

    It 'surfaces feature registration permission failures with scope guidance' {
        $script:scenario.Failure = 'feature register'
        { Register-AvmFeature -Path 'virtual-module-root' -SubscriptionId $script:subscription } |
            Should -Throw '*Microsoft.Features/*AuthorizationFailed*'
    }
}
