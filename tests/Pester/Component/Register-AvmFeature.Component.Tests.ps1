#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $script:subscription = '11111111-2222-4333-8444-555555555555'
    $script:otherSubscription = '99999999-2222-4333-8444-555555555555'
    $script:originalSubscription = $env:ARM_SUBSCRIPTION_ID

    function script:Set-RequiredFeatures {
        param([string] $Content)
        Set-Content -LiteralPath (Join-Path $script:moduleRoot '.required-features.json') `
            -Value $Content -Encoding utf8NoBOM
    }
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

Describe 'Register-AvmFeature with a local manifest and mocked Azure CLI' -Tag Component {
    BeforeEach {
        $script:moduleRoot = Join-Path $TestDrive ('module-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:moduleRoot -Force
        Set-Content -LiteralPath (Join-Path $script:moduleRoot 'terraform.tf') `
            -Value 'terraform {}' -Encoding utf8NoBOM
        $env:ARM_SUBSCRIPTION_ID = $script:subscription

        $script:scenario = [pscustomobject]@{
            AccountId     = $script:subscription
            FeatureStates = [System.Collections.Generic.Queue[string]]::new()
            ProviderStates = [System.Collections.Generic.Queue[string]]::new()
            FeatureId     = ''
            FeatureOutput = ''
            FailCommand   = ''
            FailException = InModuleScope Avm.Authoring {
                [AvmProcessException]::new('AuthorizationFailed: registration denied')
            }
            Calls         = [System.Collections.Generic.List[object]]::new()
        }
        $scenario = $script:scenario
        Mock Test-AvmModuleVersion -ModuleName Avm.Authoring {}
        Mock Resolve-AvmAzureCli -ModuleName Avm.Authoring {
            [pscustomobject]@{
                Path = 'mock-az'; ArgumentPrefix = [string[]]@(); EnvVars = @{}
            }
        }

        Mock Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith ({
                param($FilePath, $ArgumentList)
                $scenario.Calls.Add([string[]]@($ArgumentList))
                $command = "$($ArgumentList[0]) $($ArgumentList[1])"
                if ($scenario.FailCommand -ceq $command) {
                    throw $scenario.FailException
                }
                $stdout = switch ($command) {
                    'account show' {
                        $scenario.AccountId
                        break
                    }
                    'feature show' {
                        if ($scenario.FeatureOutput) {
                            $scenario.FeatureOutput
                            break
                        }
                        $namespace = $ArgumentList[[array]::IndexOf($ArgumentList, '--namespace') + 1]
                        $name = $ArgumentList[[array]::IndexOf($ArgumentList, '--name') + 1]
                        $id = if ($scenario.FeatureId) {
                            $scenario.FeatureId
                        }
                        else {
                            "/subscriptions/$($scenario.AccountId)/providers/Microsoft.Features/providers/$namespace/features/$name"
                        }
                        $state = if ($scenario.FeatureStates.Count -gt 0) {
                            $scenario.FeatureStates.Dequeue()
                        }
                        else {
                            'Registered'
                        }
                        ConvertTo-Json -Compress -Depth 4 -InputObject @{
                            id = $id; name = "$namespace/$name"; properties = @{ state = $state }
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
                        throw [System.InvalidOperationException]::new("Unexpected Azure CLI call: $command")
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = [string]$stdout; StdErr = '' }
            }.GetNewClosure())
        Mock Start-Sleep -ModuleName Avm.Authoring {}
    }

    It 'exports the approved-verb cmdlet and routes avm register-features to it' {
        Get-Command Register-AvmFeature -Module Avm.Authoring | Should -Not -BeNullOrEmpty
        $entry = InModuleScope Avm.Authoring {
            Get-AvmVerbRegistry | Where-Object { $_.Path -join ' ' -ceq 'register-features' }
        }
        $entry.Cmdlet | Should -BeExactly 'Register-AvmFeature'
    }

    It 'skips an absent manifest without resolving Azure CLI or invoking a process' {
        $result = Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription
        $result.Status | Should -BeExactly 'skipped'
        $result.FeaturesTotal | Should -Be 0
        Should -Invoke Resolve-AvmAzureCli -ModuleName Avm.Authoring -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'skips an empty array without checking Azure' {
        Set-RequiredFeatures '[]'
        $result = Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription
        $result.Status | Should -BeExactly 'skipped'
        $result.FeaturesTotal | Should -Be 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'validates a nonempty manifest offline under -WhatIf' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $result = Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription -WhatIf
        $result.Status | Should -BeExactly 'skipped'
        $result.FeaturesTotal | Should -Be 1
        Should -Invoke Resolve-AvmAzureCli -ModuleName Avm.Authoring -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'dispatches avm register-features with CLI-shaped flags and passes through an offline preview' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $result = avm register-features --path $script:moduleRoot `
            --subscription-id $script:subscription --what-if --passthru
        $result.FeaturesTotal | Should -Be 1
        $result.Status | Should -BeExactly 'skipped'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects malformed or suspicious manifest content before any Azure operation (<Case>)' -ForEach @(
        @{ Case = 'invalid JSON'; Content = '[' }
        @{ Case = 'object root'; Content = '{"feature":"Microsoft.Compute/EncryptionAtHost"}' }
        @{ Case = 'string root'; Content = '"Microsoft.Compute/EncryptionAtHost"' }
        @{ Case = 'null root'; Content = 'null' }
        @{ Case = 'nested array'; Content = '[["Microsoft.Compute/EncryptionAtHost"]]' }
        @{ Case = 'null element'; Content = '[null]' }
        @{ Case = 'numeric element'; Content = '[42]' }
        @{ Case = 'duplicate with different case'; Content = '["Microsoft.Compute/EncryptionAtHost","microsoft.compute/encryptionathost"]' }
        @{ Case = 'extra slash'; Content = '["Microsoft.Compute/EncryptionAtHost/other"]' }
        @{ Case = 'space'; Content = '["Microsoft.Compute/Bad Name"]' }
        @{ Case = 'command argument'; Content = '["Microsoft.Compute/Feature;--subscription"]' }
        @{ Case = 'relative segment'; Content = '["Microsoft.Compute/../Feature"]' }
        @{ Case = 'empty feature'; Content = '["Microsoft.Compute/"]' }
        @{ Case = 'missing namespace'; Content = '["Compute/EncryptionAtHost"]' }
    ) {
        Set-RequiredFeatures $Content
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw
        Should -Invoke Resolve-AvmAzureCli -ModuleName Avm.Authoring -Exactly 0
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects an incorrectly cased manifest consistently across operating systems' {
        Set-Content -LiteralPath (Join-Path $script:moduleRoot '.Required-Features.json') `
            -Value '["Microsoft.Compute/EncryptionAtHost"]' -Encoding utf8NoBOM
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw "*named exactly '.required-features.json'*"
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'limits a manifest to 32 entries before accessing Azure' {
        $content = ConvertTo-Json -Compress -InputObject @(
            1..33 | ForEach-Object { "Microsoft.Compute/Feature$_" }
        )
        Set-RequiredFeatures $content
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw '*no more than 32*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects a malformed subscription GUID before Azure access' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId 'production' } |
            Should -Throw '*explicit, nonempty subscription GUID*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'fails closed when the effective Terraform subscription differs from the explicit test subscription' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $env:ARM_SUBSCRIPTION_ID = $script:otherSubscription
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw '*effective ARM_SUBSCRIPTION_ID does not match*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0
    }

    It 'fails before showing a feature when Azure CLI is selected to a different subscription' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.AccountId = $script:otherSubscription
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw '*Azure CLI is not selected to subscription*'
        $script:scenario.Calls.Count | Should -Be 1
        $script:scenario.Calls[0] -join ' ' | Should -BeExactly 'account show --query id --output tsv --only-show-errors'
    }

    It 'leaves already Registered features and their provider untouched' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $result = Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription
        $result.Status | Should -BeExactly 'pass'
        $result.FeaturesTotal | Should -Be 1
        $result.AlreadyRegisteredFeatures | Should -Be @('Microsoft.Compute/EncryptionAtHost')
        $result.RegisteredFeatures.Count | Should -Be 0
        $script:scenario.Calls.Count | Should -Be 2
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[1] -eq 'register'
        }
    }

    It 'registers a missing feature, polls both states, and refreshes its provider with explicit subscription arguments' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.FeatureStates.Enqueue('NotRegistered')
        $script:scenario.FeatureStates.Enqueue('Registering')
        $script:scenario.FeatureStates.Enqueue('Registered')
        $script:scenario.ProviderStates.Enqueue('Registering')
        $script:scenario.ProviderStates.Enqueue('Registered')

        $result = Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription
        $result.Status | Should -BeExactly 'pass'
        $result.RegisteredFeatures | Should -Be @('Microsoft.Compute/EncryptionAtHost')
        $result.AlreadyRegisteredFeatures.Count | Should -Be 0
        ($script:scenario.Calls | ForEach-Object { $_[0..1] -join ' ' }) -join ',' |
            Should -BeExactly 'account show,feature show,feature register,feature show,feature show,provider register,provider show,provider show'
        foreach ($call in $script:scenario.Calls) {
            if ($call[0] -notin @('feature', 'provider')) { continue }
            $index = [array]::IndexOf($call, '--subscription')
            $index | Should -BeGreaterThan 0
            $call[$index + 1] | Should -BeExactly $script:subscription
            $call -join ' ' | Should -Not -Match 'unregister|--federated-token|secret-sentinel'
        }
    }

    It 'waits for an already Registering feature without registering it again' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.FeatureStates.Enqueue('Registering')
        $script:scenario.FeatureStates.Enqueue('Registered')
        $result = Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription
        $result.Status | Should -BeExactly 'pass'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[0] -eq 'feature' -and $ArgumentList[1] -eq 'register'
        }
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -eq 'provider' -and $ArgumentList[1] -eq 'register'
        }
    }

    It 'does not refresh a provider for an already registered second feature' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost","Microsoft.Compute/OtherFeature"]'
        $script:scenario.FeatureStates.Enqueue('NotRegistered')
        $script:scenario.FeatureStates.Enqueue('Registered')
        $script:scenario.FeatureStates.Enqueue('Registered')
        $result = Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription
        $result.FeaturesTotal | Should -Be 2
        $result.RegisteredFeatures.Count | Should -Be 1
        $result.AlreadyRegisteredFeatures.Count | Should -Be 1
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -eq 'provider' -and $ArgumentList[1] -eq 'register'
        }
    }

    It 'stops immediately with an approval hint for a Pending feature' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.FeatureStates.Enqueue('Pending')
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw '*Request access*'
        $script:scenario.Calls.Count | Should -Be 2
    }

    It 'stops if a feature becomes Pending after registration' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.FeatureStates.Enqueue('NotRegistered')
        $script:scenario.FeatureStates.Enqueue('Pending')
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw '*may require service approval*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[0] -eq 'provider'
        }
    }

    It 'fails with a bounded timeout when feature registration never finishes' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.FeatureStates.Enqueue('NotRegistered')
        $script:scenario.FeatureStates.Enqueue('Registering')
        $script:scenario.FeatureStates.Enqueue('Registering')
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription `
                -MaximumPolls 2 -PollIntervalSeconds 1 } |
            Should -Throw '*did not reach Registered*after 2 checks*'
        Should -Invoke Start-Sleep -ModuleName Avm.Authoring -Exactly 1
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[0] -eq 'provider'
        }
    }

    It 'stops with a bounded timeout if provider propagation never finishes' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.FeatureStates.Enqueue('Unregistered')
        $script:scenario.FeatureStates.Enqueue('Registered')
        $script:scenario.ProviderStates.Enqueue('Registering')
        $script:scenario.ProviderStates.Enqueue('Registering')
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription `
                -MaximumPolls 2 -PollIntervalSeconds 1 } |
            Should -Throw '*Provider Microsoft.Compute did not reach Registered*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -eq 'provider' -and $ArgumentList[1] -eq 'register'
        }
    }

    It 'surfaces Azure permission failures with required access and stops' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.FeatureStates.Enqueue('NotRegistered')
        $script:scenario.FailCommand = 'feature register'
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw '*Microsoft.Features/*AuthorizationFailed*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[0] -eq 'provider'
        }
    }

    It 'surfaces provider permission failures with required access and stops' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.FeatureStates.Enqueue('NotRegistered')
        $script:scenario.FeatureStates.Enqueue('Registered')
        $script:scenario.FailCommand = 'provider register'
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw '*/register/action*AuthorizationFailed*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[0] -eq 'provider' -and $ArgumentList[1] -eq 'show'
        }
    }

    It 'propagates an earlier registration even when a later feature is Pending' {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost","Microsoft.Compute/OtherFeature"]'
        $script:scenario.FeatureStates.Enqueue('NotRegistered')
        $script:scenario.FeatureStates.Enqueue('Registered')
        $script:scenario.FeatureStates.Enqueue('Pending')
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw '*Pending*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -eq 'provider' -and $ArgumentList[1] -eq 'register'
        }
    }

    It 'does not accept malformed or cross-subscription feature responses' -ForEach @(
        @{ Case = 'bad JSON'; Output = 'not-json'; Id = '' }
        @{ Case = 'another subscription'; Output = ''; Id = '/subscriptions/99999999-2222-4333-8444-555555555555/providers/Microsoft.Features/providers/Microsoft.Compute/features/EncryptionAtHost' }
    ) {
        Set-RequiredFeatures '["Microsoft.Compute/EncryptionAtHost"]'
        $script:scenario.FeatureOutput = $Output
        $script:scenario.FeatureId = $Id
        { Register-AvmFeature -Path $script:moduleRoot -SubscriptionId $script:subscription } |
            Should -Throw
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter {
            $ArgumentList[1] -eq 'register'
        }
    }
}

Describe 'Terraform workflow required-feature preflight' -Tag Component {
    BeforeAll {
        $workflowPath = Join-Path $script:repoRoot '.github' 'workflows' 'terraform-module.yml'
        $lines = @(Get-Content -LiteralPath $workflowPath)
        $start = [array]::IndexOf($lines, '        run: &check-required-features |')
        if ($start -lt 0) {
            throw [System.InvalidOperationException]::new('The required-feature preflight anchor was not found.')
        }
        $end = $start + 1
        while ($end -lt $lines.Count -and $lines[$end] -notmatch '^      - name: ') {
            $end++
        }
        $body = @($lines[($start + 1)..($end - 1)] | ForEach-Object { $_ -replace '^ {10}', '' })
        $script:preflight = [scriptblock]::Create($body -join "`n")
    }

    BeforeEach {
        $script:previousLocation = (Get-Location).Path
        $script:previousSelected = $env:SELECTED_SUBSCRIPTION_ID
        $script:previousOutput = $env:GITHUB_OUTPUT
        $script:previousClientId = $env:ARM_CLIENT_ID
        $script:previousTenantId = $env:ARM_TENANT_ID
        $script:previousModulePath = $env:PSModulePath
        $script:preflightRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:preflightRoot
        Set-Location -LiteralPath $script:preflightRoot
        $env:PSModulePath = "$(Join-Path $script:repoRoot 'src')$([IO.Path]::PathSeparator)$env:PSModulePath"
        $env:GITHUB_OUTPUT = Join-Path $script:preflightRoot 'output.txt'
        $env:SELECTED_SUBSCRIPTION_ID = $script:subscription
        $env:ARM_SUBSCRIPTION_ID = $script:otherSubscription
        $env:ARM_CLIENT_ID = 'fake-test-client'
        $env:ARM_TENANT_ID = 'fake-test-tenant'
        Mock Test-AvmModuleVersion -ModuleName Avm.Authoring {}
        Mock Resolve-AvmAzureCli -ModuleName Avm.Authoring {
            throw 'Feature preflight must not resolve Azure CLI.'
        }
        Mock Invoke-AvmAzureCli -ModuleName Avm.Authoring {
            throw 'Feature preflight must not call Azure CLI.'
        }
    }

    AfterEach {
        Set-Location -LiteralPath $script:previousLocation
        $env:SELECTED_SUBSCRIPTION_ID = $script:previousSelected
        $env:GITHUB_OUTPUT = $script:previousOutput
        $env:ARM_CLIENT_ID = $script:previousClientId
        $env:ARM_TENANT_ID = $script:previousTenantId
        $env:PSModulePath = $script:previousModulePath
    }

    It 'does not signal Azure login for a module without the manifest' {
        $log = @(& $script:preflight 6>&1) | Out-String
        $log | Should -Match 'No \.required-features\.json found; feature-specific Azure login and registration will be skipped\.'
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'does not signal Azure login for an empty manifest' {
        Set-Content -LiteralPath '.required-features.json' -Value '[]' -Encoding utf8NoBOM
        $log = @(& $script:preflight 6>&1) | Out-String
        $log | Should -Match '\.required-features\.json declares no features; feature-specific Azure login and registration will be skipped\.'
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'rejects a nonempty manifest targeting an overridden subscription before signaling login' {
        Set-Content -LiteralPath '.required-features.json' `
            -Value '["Microsoft.Compute/EncryptionAtHost"]' -Encoding utf8NoBOM
        { & $script:preflight } | Should -Throw '*effective ARM_SUBSCRIPTION_ID does not match*'
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'validates every declared feature offline and announces that Azure registration follows login' {
        Set-Content -LiteralPath 'terraform.tf' -Value 'terraform {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath '.required-features.json' -Encoding utf8NoBOM -Value (
            '["Microsoft.Compute/EncryptionAtHost","Microsoft.Network/AllowTestFeature"]'
        )
        $env:ARM_SUBSCRIPTION_ID = $script:subscription

        $log = @(& $script:preflight 6>&1) | Out-String

        (Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw).Trim() | Should -BeExactly 'required=true'
        $log | Should -Match 'Validated all 2 required Azure feature\(s\) in \.required-features\.json'
        $log | Should -Match "effective selected test subscription $($script:subscription)"
        $log | Should -Match 'No Azure calls or feature registration occurred; Azure login and registration run in the following steps\.'
        $log | Should -Not -Match 'register-features: skipped'
        Should -Invoke Resolve-AvmAzureCli -ModuleName Avm.Authoring -Exactly 0
        Should -Invoke Invoke-AvmAzureCli -ModuleName Avm.Authoring -Exactly 0
    }

    It 'rejects a later invalid feature before allowing Azure login' {
        Set-Content -LiteralPath 'terraform.tf' -Value 'terraform {}' -Encoding utf8NoBOM
        Set-Content -LiteralPath '.required-features.json' -Encoding utf8NoBOM -Value (
            '["Microsoft.Compute/EncryptionAtHost","Microsoft.Network/Invalid Feature"]'
        )
        $env:ARM_SUBSCRIPTION_ID = $script:subscription

        { & $script:preflight } | Should -Throw

        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
        Should -Invoke Resolve-AvmAzureCli -ModuleName Avm.Authoring -Exactly 0
        Should -Invoke Invoke-AvmAzureCli -ModuleName Avm.Authoring -Exactly 0
    }
}
