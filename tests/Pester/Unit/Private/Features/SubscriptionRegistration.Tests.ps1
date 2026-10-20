#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module $manifest -Force
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Subscription provider registration state machine' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:registration = @{
                States = [Collections.Generic.Queue[string]]::new()
                Calls = [Collections.Generic.List[object]]::new()
                Output = $null; OutputAt = 0; FailureAt = 0; Failure = $null; IdentityChecks = 0; RejectIdentityAt = 0
            }
            $script:registrationInput = @{
                Cli = [pscustomobject]@{ Path = 'mock-az'; ArgumentPrefix = [string[]]@(); EnvVars = @{} }
                Root = $TestDrive; SubscriptionId = '11111111-1111-4111-8111-111111111111'; Kind = 'Provider'
                Requirement = @(ConvertTo-AvmRequiredRegistration -Kind Provider -Entries @('Microsoft.Compute'))
                MaximumPolls = 2; PollIntervalSeconds = 0
                AssertIdentity = {
                    $script:registration.IdentityChecks++
                    if ($script:registration.IdentityChecks -eq $script:registration.RejectIdentityAt) {
                        throw [AvmConfigurationException]::new('Selected test identity changed.')
                    }
                }
            }
            Mock Start-Sleep {}
            Mock Invoke-AvmProcess {
                param($ArgumentList, $TimeoutSec)
                $TimeoutSec | Should -Be 60
                $script:registration.Calls.Add([string[]]$ArgumentList)
                if ($script:registration.Calls.Count -eq $script:registration.FailureAt) { throw $script:registration.Failure }
                if ($ArgumentList[1] -eq 'register') { return [pscustomobject]@{ StdOut = ''; ExitCode = 0 } }
                $output = $script:registration.Output
                if ($script:registration.OutputAt -gt 0 -and
                    $script:registration.Calls.Count -ne $script:registration.OutputAt) { $output = $null }
                if ($null -eq $output) {
                    $state = if ($script:registration.States.Count) { $script:registration.States.Dequeue() } else { 'Registered' }
                    $output = @{ namespace = 'Microsoft.Compute'; registrationState = $state } | ConvertTo-Json -Compress
                }
                [pscustomobject]@{ StdOut = $output; ExitCode = 0 }
            }
        }
    }

    It 'skips <Case> without identity checks or Azure calls' -ForEach @(
        @{ Case = 'empty requirements'; WhatIf = $false }
        @{ Case = 'WhatIf'; WhatIf = $true }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Preview = $WhatIf } {
            param($Preview)
            if (-not $Preview) { $script:registrationInput.Requirement = @() }
            $result = Invoke-AvmSubscriptionRegistration @script:registrationInput -WhatIf:$Preview
            $result.Registered.Count | Should -Be 0
            $script:registration.IdentityChecks | Should -Be 0
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }

    It 'handles <Initial> without resubmitting registrations' -ForEach @(
        @{ Initial = 'Registered'; RegisterCount = 0; Reads = 1 }
        @{ Initial = 'Registering'; RegisterCount = 0; Reads = 3 }
        @{ Initial = 'NotRegistered'; RegisterCount = 1; Reads = 3 }
        @{ Initial = 'Unregistered'; RegisterCount = 1; Reads = 3 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Initial = $Initial; RegisterCount = $RegisterCount; Reads = $Reads } {
            param($Initial, $RegisterCount, $Reads)
            foreach ($state in @($Initial, 'Registering', 'Registered')) { $script:registration.States.Enqueue($state) }
            $result = Invoke-AvmSubscriptionRegistration @script:registrationInput
            if ($Initial -eq 'Registered') { $result.AlreadyRegistered | Should -Be @('Microsoft.Compute') }
            else { $result.Registered | Should -Be @('Microsoft.Compute') }
            Should -Invoke Invoke-AvmProcess -Exactly $RegisterCount -ParameterFilter { $ArgumentList[1] -eq 'register' }
            Should -Invoke Invoke-AvmProcess -Exactly $Reads -ParameterFilter { $ArgumentList[1] -eq 'show' }
            $script:registration.IdentityChecks | Should -Be ($Reads + $RegisterCount)
            foreach ($call in $script:registration.Calls) {
                $call[[array]::IndexOf($call, '--subscription') + 1] | Should -BeExactly $script:registrationInput.SubscriptionId
                $call -join ' ' | Should -Not -Match 'consent|accept|unregister|account set|role'
            }
        }
    }

    It 'fails on <State> during <Phase> and never visits a later provider' -ForEach @(
        foreach ($state in @('Pending', 'Failed', 'Canceled', 'Cancelled', 'Unregistering', 'Unknown', 'registered')) {
            @{ State = $state; Phase = 'initial read'; Writes = 0 }
            @{ State = $state; Phase = 'poll'; Writes = 1 }
        }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ State = $State; Phase = $Phase; Writes = $Writes } {
            param($State, $Phase, $Writes)
            $script:registrationInput.Requirement += @(ConvertTo-AvmRequiredRegistration -Kind Provider -Entries @('Microsoft.Storage'))
            if ($Phase -eq 'poll') { $script:registration.States.Enqueue('NotRegistered') }
            $script:registration.States.Enqueue($State)
            { Invoke-AvmSubscriptionRegistration @script:registrationInput } | Should -Throw
            Should -Invoke Invoke-AvmProcess -Exactly $Writes -ParameterFilter { $ArgumentList[1] -eq 'register' }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList -contains 'Microsoft.Storage' }
        }
    }

    It 'ends at the exact polling budget without another submission' {
        InModuleScope Avm.Authoring {
            1..3 | ForEach-Object { $script:registration.States.Enqueue('Registering') }
            { Invoke-AvmSubscriptionRegistration @script:registrationInput } | Should -Throw '*after 2 checks*'
            Should -Invoke Invoke-AvmProcess -Exactly 3
            Should -Invoke Start-Sleep -Exactly 1
        }
    }

    It 'accepts one CLI namespace envelope with <Rows> resource-type rows without registering it again' -ForEach @(
        @{ Rows = 1 }
        @{ Rows = 3 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Rows = $Rows } {
            param($Rows)
            $types = @(foreach ($index in 1..$Rows) {
                    @{ resourceType = "type$index"; locations = @('East US'); apiVersions = @('2026-01-01') }
                })
            $script:registration.Output = @{
                namespace = 'Microsoft.Compute'
                id = '/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Compute'
                registrationState = 'Registered'
                resourceTypes = $types
            } | ConvertTo-Json -Depth 6 -Compress
            (Invoke-AvmSubscriptionRegistration @script:registrationInput).AlreadyRegistered | Should -Be @('Microsoft.Compute')
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[1] -eq 'show' }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList[1] -eq 'register' }
            $script:registration.IdentityChecks | Should -Be 1
        }
    }

    It 'rejects invalid provider responses: <Case>' -ForEach @(
        @{ Case = 'JSON'; Json = 'invalid' }
        @{ Case = 'singleton array'; Json = '[{"namespace":"Microsoft.Compute","registrationState":"Registered"}]' }
        @{ Case = 'PowerShell row array instead of CLI envelope'; Json = '[{"namespace":"Microsoft.Compute","registrationState":"Registered"},{"namespace":"Microsoft.Compute","registrationState":"Registered"}]' }
        @{ Case = 'duplicate property'; Json = '{"namespace":"Microsoft.Compute","namespace":"Microsoft.Compute","registrationState":"Registered"}' }
        @{ Case = 'namespace array'; Json = '{"namespace":["Microsoft.Compute"],"registrationState":"Registered"}' }
        @{ Case = 'wrong namespace'; Json = '{"namespace":"Microsoft.Storage","registrationState":"Registered"}' }
        @{ Case = 'state array'; Json = '{"namespace":"Microsoft.Compute","registrationState":["Registered"]}' }
        @{ Case = 'state number'; Json = '{"namespace":"Microsoft.Compute","registrationState":1}' }
        @{ Case = 'state null'; Json = '{"namespace":"Microsoft.Compute","registrationState":null}' }
        @{ Case = 'empty state'; Json = '{"namespace":"Microsoft.Compute","registrationState":""}' }
        @{ Case = 'missing state'; Json = '{"namespace":"Microsoft.Compute"}' }
        @{ Case = 'null id'; Json = '{"namespace":"Microsoft.Compute","registrationState":"Registered","id":null}' }
        @{ Case = 'foreign subscription'; Json = '{"namespace":"Microsoft.Compute","registrationState":"Registered","id":"/subscriptions/22222222-2222-4222-8222-222222222222/providers/Microsoft.Compute"}' }
        @{ Case = 'wrong id namespace'; Json = '{"namespace":"Microsoft.Compute","registrationState":"Registered","id":"/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Storage"}' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Json = $Json } {
            param($Json)
            $script:registration.Output = $Json
            { Invoke-AvmSubscriptionRegistration @script:registrationInput } | Should -Throw
            Should -Invoke Invoke-AvmProcess -Exactly 1
        }
    }

    It 'rejects invalid poll evidence after exactly one registration: <Case>' -ForEach @(
        @{ Case = 'malformed JSON'; Json = '{' }
        @{ Case = 'array'; Json = '[{"namespace":"Microsoft.Compute","registrationState":"Registered"}]' }
        @{ Case = 'escaped duplicate'; Json = '{"namespace":"Microsoft.Compute","registrationState":"Registered","registration\u0053tate":"Registered"}' }
        @{ Case = 'case duplicate'; Json = '{"namespace":"Microsoft.Compute","registrationState":"Registered","RegistrationState":"Registered"}' }
        @{ Case = 'foreign subscription'; Json = '{"namespace":"Microsoft.Compute","registrationState":"Registered","id":"/subscriptions/22222222-2222-4222-8222-222222222222/providers/Microsoft.Compute"}' }
        @{ Case = 'wrong namespace'; Json = '{"namespace":"Microsoft.Storage","registrationState":"Registered"}' }
        @{ Case = 'state array'; Json = '{"namespace":"Microsoft.Compute","registrationState":["Registered"]}' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Json = $Json } {
            param($Json)
            $script:registrationInput.Requirement += @(ConvertTo-AvmRequiredRegistration -Kind Provider -Entries @('Microsoft.Storage'))
            $script:registration.States.Enqueue('NotRegistered')
            $script:registration.Output = $Json
            $script:registration.OutputAt = 3
            { Invoke-AvmSubscriptionRegistration @script:registrationInput } | Should -Throw
            Should -Invoke Invoke-AvmProcess -Exactly 3
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter { $ArgumentList[1] -eq 'register' }
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList -contains 'Microsoft.Storage' }
        }
    }

    It 'accepts the exact optional provider id with case-insensitive Azure identity' {
        InModuleScope Avm.Authoring {
            $script:registration.Output = '{"namespace":"microsoft.compute","registrationState":"Registered","id":"/SUBSCRIPTIONS/11111111-1111-4111-8111-111111111111/providers/Microsoft.Compute"}'
            (Invoke-AvmSubscriptionRegistration @script:registrationInput).AlreadyRegistered | Should -Be @('Microsoft.Compute')
        }
    }

    It 'rechecks identity before <Phase>, preventing that Azure command' -ForEach @(
        @{ Phase = 'initial read'; At = 1 }
        @{ Phase = 'registration'; At = 2 }
        @{ Phase = 'poll'; At = 3 }
        @{ Phase = 'last poll'; At = 4 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ At = $At } {
            param($At)
            $script:registration.States.Enqueue('NotRegistered')
            $script:registration.States.Enqueue('Registering')
            $script:registration.RejectIdentityAt = $At
            { Invoke-AvmSubscriptionRegistration @script:registrationInput } | Should -Throw '*identity changed*'
            Should -Invoke Invoke-AvmProcess -Exactly ($At - 1)
        }
    }

    It 'propagates <Failure> at <Phase> without retrying or visiting a later provider' -ForEach @(
        foreach ($failure in @('native failure', 'timeout', 'cancellation')) {
            @{ Failure = $failure; Phase = 'read'; At = 1 }
            @{ Failure = $failure; Phase = 'registration'; At = 2 }
            @{ Failure = $failure; Phase = 'poll'; At = 3 }
        }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Failure = $Failure; At = $At } {
            param($Failure, $At)
            $script:registrationInput.Requirement += @(ConvertTo-AvmRequiredRegistration -Kind Provider -Entries @('Microsoft.Storage'))
            $script:registration.FailureAt = $At
            $script:registration.Failure = switch ($Failure) {
                'native failure' { [AvmProcessException]::new('Registration denied.') }
                'timeout' { [TimeoutException]::new('CLI command timed out.') }
                'cancellation' { [OperationCanceledException]::new('Registration cancelled.') }
            }
            $script:registration.States.Enqueue('NotRegistered')
            { Invoke-AvmSubscriptionRegistration @script:registrationInput } | Should -Throw
            Should -Invoke Invoke-AvmProcess -Exactly $At
            Should -Invoke Invoke-AvmProcess -Exactly 0 -ParameterFilter { $ArgumentList -contains 'Microsoft.Storage' }
        }
    }

    It 'stops an isolated pipeline cancelled during <Phase> without another provider or command' -ForEach @(
        @{ Phase = 'initial read'; At = 1 }, @{ Phase = 'registration'; At = 2 }, @{ Phase = 'poll'; At = 3 }
    ) {
        $probe = @{ Calls = 0; CancelAt = $At; Completed = $false }
        $pipeline = [powershell]::Create()
        try {
            $null = $pipeline.AddScript({
                    param($Manifest, $Probe)
                    Import-Module $Manifest -Force
                    & (Get-Module Avm.Authoring) {
                        param($Probe)
                        $script:providerCancellationProbe = $Probe
                        function script:Invoke-AvmProcess {
                            [CmdletBinding()]
                            param($FilePath, $ArgumentList, $WorkingDirectory, $EnvVars, $TimeoutSec, $Label)
                            $script:providerCancellationProbe.Calls++
                            if ($script:providerCancellationProbe.Calls -eq $script:providerCancellationProbe.CancelAt) {
                                throw [Management.Automation.PipelineStoppedException]::new('Registration pipeline cancelled.')
                            }
                            $json = '{"namespace":"Microsoft.Compute","registrationState":"NotRegistered"}'
                            [pscustomobject]@{ StdOut = $json; ExitCode = 0 }
                        }
                        $requirements = @(ConvertTo-AvmRequiredRegistration -Kind Provider -Entries @('Microsoft.Compute', 'Microsoft.Storage'))
                        $null = Invoke-AvmSubscriptionRegistration -Kind Provider -Requirement $requirements `
                            -Cli ([pscustomobject]@{ Path = 'stub-only'; ArgumentPrefix = [string[]]@(); EnvVars = @{} }) `
                            -Root 'unused' -SubscriptionId '11111111-1111-4111-8111-111111111111' `
                            -MaximumPolls 2 -PollIntervalSeconds 0 -Confirm:$false
                        $Probe.Completed = $true
                    } $Probe
                }).AddArgument($manifest).AddArgument($probe)
            $null = $pipeline.Invoke()
            $pipeline.HadErrors | Should -BeTrue
            $pipeline.InvocationStateInfo.State | Should -BeIn @(
                [Management.Automation.PSInvocationState]::Stopped, [Management.Automation.PSInvocationState]::Failed)
            $pipeline.InvocationStateInfo.Reason.GetBaseException() | Should -BeOfType ([Management.Automation.PipelineStoppedException])
            $probe.Calls | Should -Be $At
            $probe.Completed | Should -BeFalse
        }
        finally { $pipeline.Dispose() }
    }
}
