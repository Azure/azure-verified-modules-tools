#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    & (Get-Module Avm.Authoring) {
        function script:Invoke-AzRestMethod {
            [CmdletBinding()] param($Method, $Path)
            throw 'Unexpected Azure request.'
        }
        function script:Get-AzResourceGroup {
            [CmdletBinding()] param($Name)
            throw 'Unexpected Azure lookup.'
        }
    }
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep authorization propagation reads' {
    BeforeEach {
        InModuleScope Avm.Authoring {
            $script:calls = 0
            Mock Start-Sleep {}
        }
    }

    It 'retries a transient AuthorizationFailed response on an opted-in read' {
        InModuleScope Avm.Authoring {
            $response = Invoke-AvmBicepRead -Activity 'Owned deployment read' -RetryAuthorizationPropagation -Read {
                $script:calls++
                if ($script:calls -lt 3) {
                    return @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
                }
                @{ StatusCode = 200; Content = '{"value":[]}' }
            }
            $response.StatusCode | Should -Be 200
            $script:calls | Should -Be 3
            Should -Invoke Start-Sleep -Exactly 2
        }
    }

    It 'returns the persistent 403 after a bounded number of reads' {
        InModuleScope Avm.Authoring {
            $response = Invoke-AvmBicepRead -Activity 'Owned deployment read' -RetryAuthorizationPropagation -Read {
                $script:calls++
                @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
            }
            $response.StatusCode | Should -Be 403
            $script:calls | Should -Be 61
            Should -Invoke Start-Sleep -Exactly 60
        }
    }

    It 'uses configured propagation status and code for responses and exceptions' {
        InModuleScope Avm.Authoring {
            $policy = Get-AvmBicepRetryPolicy
            $policy['authorizationPropagation']['statusCode'] = 429
            $policy['authorizationPropagation']['errorCode'] = 'FixturePropagation'
            $policy = Get-AvmBicepRetryPolicy -InputObject $policy
            $response = @{ StatusCode = 429; Content = '{"error":{"code":"FixturePropagation"}}' }
            Test-AvmBicepAuthorizationFailed -Response $response -Policy $policy | Should -BeTrue
            Test-AvmBicepAuthorizationFailed -Response @{
                StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}'
            } -Policy $policy | Should -BeFalse
            $fault = [InvalidOperationException]::new('Denied.')
            $fault | Add-Member -NotePropertyName Response -NotePropertyValue $response
            $record = [Management.Automation.ErrorRecord]::new($fault, 'Fixture', 'PermissionDenied', $null)
            Test-AvmBicepAuthorizationFailed -ErrorRecord $record -Policy $policy | Should -BeTrue
        }
    }

    It 'uses configured attempts and poll interval for opted-in reads' {
        InModuleScope Avm.Authoring {
            $script:retryPolicy = Get-AvmBicepRetryPolicy
            $script:retryPolicy['authorizationPropagation']['attempts'] = 3
            $script:retryPolicy['authorizationPropagation']['pollIntervalSeconds'] = 2
            $script:retryPolicy = Get-AvmBicepRetryPolicy -InputObject $script:retryPolicy
            Mock Get-AvmBicepRetryPolicy { $script:retryPolicy }
            $response = Invoke-AvmBicepRead -Activity 'Owned deployment read' -RetryAuthorizationPropagation -Read {
                $script:calls++
                @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
            }
            $response.StatusCode | Should -Be 403
            $script:calls | Should -Be 3
            Should -Invoke Start-Sleep -Exactly 2 -ParameterFilter { $Seconds -eq 2 }
        }
    }

    It 'uses the configured propagation window for opted-in reads' {
        InModuleScope Avm.Authoring {
            $script:retryPolicy = Get-AvmBicepRetryPolicy
            $script:retryPolicy['authorizationPropagation']['timeoutSeconds'] = 3
            $script:retryPolicy['authorizationPropagation']['pollIntervalSeconds'] = 1
            $script:retryPolicy = Get-AvmBicepRetryPolicy -InputObject $script:retryPolicy
            $script:clock = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            Mock Get-AvmBicepRetryPolicy { $script:retryPolicy }
            Mock Get-Date { $script:clock }
            Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
            $response = Invoke-AvmBicepRead -Activity 'Owned deployment read' -RetryAuthorizationPropagation -Read {
                $script:calls++
                @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
            }
            $response.StatusCode | Should -Be 403
            $script:calls | Should -Be 3
            $script:clock | Should -Be ([datetime]::new(2026, 1, 1, 0, 0, 3, [DateTimeKind]::Utc))
        }
    }

    It 'respects configured non-retryable categories while allowing permission-denied records' {
        InModuleScope Avm.Authoring {
            $policy = Get-AvmBicepRetryPolicy
            $fault = [InvalidOperationException]::new('Denied.')
            $fault | Add-Member -NotePropertyName Response -NotePropertyValue @{
                StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}'
            }
            foreach ($category in @('AuthenticationError', 'SecurityError', 'PermissionDenied')) {
                $record = [Management.Automation.ErrorRecord]::new($fault, 'Fixture', $category, $null)
                Test-AvmBicepAuthorizationFailed -ErrorRecord $record -Policy $policy |
                    Should -Be ($category -eq 'PermissionDenied')
            }
            $policy['authorizationPropagation']['nonRetryableCategories'] = @('PermissionDenied')
            Test-AvmBicepAuthorizationFailed -ErrorRecord $record -Policy $policy | Should -BeFalse
        }
    }

    It 'does not classify a conflicting response status as authorization propagation' {
        InModuleScope Avm.Authoring {
            $fault = [InvalidOperationException]::new('Denied.')
            $fault | Add-Member -NotePropertyName StatusCode -NotePropertyValue 403
            $fault | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 500 }
            $fault | Add-Member -NotePropertyName Body -NotePropertyValue @{ Code = 'AuthorizationFailed' }
            $record = [Management.Automation.ErrorRecord]::new($fault, 'Fixture', 'PermissionDenied', $null)
            Test-AvmBicepAuthorizationFailed -ErrorRecord $record | Should -BeFalse
        }
    }

    It 'completes owned deployment discovery when operation authorization propagates' {
        InModuleScope Avm.Authoring {
            $id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Resources/deployments/root'
            Mock Invoke-AzRestMethod {
                $script:calls++
                if ($script:calls -lt 3) {
                    return @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
                }
                @{ StatusCode = 200; Content = '{"value":[]}' }
            }
            $result = Get-AvmBicepDeploymentCleanupTarget -DeploymentIds @($id) -SearchRetryLimit 1
            $result.Issues.Count | Should -Be 0
            $result.Deployments[0].Status | Should -BeExactly 'Resolved'
            Should -Invoke Invoke-AzRestMethod -Exactly 3
            Should -Invoke Start-Sleep -Exactly 2
        }
    }

    It 'retries typed SDK AuthorizationFailed exceptions without losing their original failure' {
        InModuleScope Avm.Authoring {
            $action = {
                $script:calls++
                $fault = [InvalidOperationException]::new('Denied.')
                $fault | Add-Member -NotePropertyName Response -NotePropertyValue @{
                    StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}'
                }
                throw $fault
            }
            { Invoke-AvmBicepAuthorizationRead -Read $action } | Should -Throw '*Denied*'
            $script:calls | Should -Be 61
            Should -Invoke Start-Sleep -Exactly 60
        }
    }

    It 'retries a transient authorization error when looking up an owned group' {
        InModuleScope Avm.Authoring {
            Mock Get-AzResourceGroup {
                $script:calls++
                if ($script:calls -lt 3) {
                    $fault = [InvalidOperationException]::new('Denied.')
                    $fault | Add-Member -NotePropertyName Response -NotePropertyValue @{
                        StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}'
                    }
                    throw $fault
                }
                @{ ResourceId = '/subscriptions/example/resourceGroups/owned' }
            }
            $group = Invoke-AvmBicepCleanupLookup -Command Get-AzResourceGroup `
                -Parameters @{ Name = 'owned' } -RetryAuthorizationPropagation
            $group.ResourceId | Should -BeExactly '/subscriptions/example/resourceGroups/owned'
            Should -Invoke Get-AzResourceGroup -Exactly 3
            Should -Invoke Start-Sleep -Exactly 2
        }
    }

    It 'does not start another authorization read after the time budget' {
        InModuleScope Avm.Authoring {
            $script:clock = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            $script:startTimes = [Collections.Generic.List[datetime]]::new()
            Mock Get-Date { $script:clock }
            Mock Start-Sleep { $script:clock = $script:clock.AddSeconds($Seconds) }
            $response = Invoke-AvmBicepRead -Activity 'Owned deployment read' -RetryAuthorizationPropagation -Read {
                $script:startTimes.Add($script:clock)
                $script:clock = $script:clock.AddSeconds(19)
                @{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' }
            }
            $response.StatusCode | Should -Be 403
            $script:startTimes.Count | Should -Be 13
            $script:startTimes[-1] | Should -BeLessThan ([datetime]::new(2026, 1, 1, 0, 5, 0, [DateTimeKind]::Utc))
        }
    }

    It 'does not retry unapproved or ambiguous response <Case>' -ForEach @(
        @{ Case = 'non-opted-in 403'; Status = 403; Content = '{"error":{"code":"AuthorizationFailed"}}'; OptIn = $false }
        @{ Case = 'other 403'; Status = 403; Content = '{"error":{"code":"Forbidden"}}'; OptIn = $true }
        @{ Case = 'untyped 403'; Status = '403'; Content = '{"error":{"code":"AuthorizationFailed"}}'; OptIn = $true }
        @{ Case = '401'; Status = 401; Content = '{"error":{"code":"AuthorizationFailed"}}'; OptIn = $true }
        @{ Case = 'mixed details'; Status = 403; Content = '{"error":{"code":"AuthorizationFailed","details":[{"code":"Other"}]}}'; OptIn = $true }
        @{ Case = 'malformed message'; Status = 403; Content = '{"error":{"code":"AuthorizationFailed","message":["other"]}}'; OptIn = $true }
        @{ Case = 'invalid JSON'; Status = 403; Content = '{'; OptIn = $true }
    ) {
        InModuleScope Avm.Authoring -Parameters $_ {
            param($Status, $Content, $OptIn)
            $response = Invoke-AvmBicepRead -Activity 'Read' -RetryAuthorizationPropagation:$OptIn -Read {
                $script:calls++
                @{ StatusCode = $Status; Content = $Content }
            }
            $response.StatusCode | Should -Be $Status
            $script:calls | Should -Be 1
            Should -Invoke Start-Sleep -Exactly 0
        }
    }

    It 'does not retry authorization exceptions mixed with <Case>' -ForEach @(
        @{ Case = 'an unrelated inner cause' }, @{ Case = 'a sibling failure' }, @{ Case = 'cancellation' }
        @{ Case = 'pipeline cancellation' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Case = $Case } {
            param($Case)
            $inner = if ($Case -eq 'an unrelated inner cause') { [InvalidOperationException]::new('Other failure.') }
            elseif ($Case -eq 'cancellation') { [OperationCanceledException]::new('Cancelled.') }
            elseif ($Case -eq 'pipeline cancellation') { [Management.Automation.PipelineStoppedException]::new() }
            else { $null }
            $fault = [InvalidOperationException]::new('Denied.', $inner)
            $fault | Add-Member -NotePropertyName Response -NotePropertyValue @{
                StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}'
            }
            if ($Case -eq 'a sibling failure') {
                $fault = [AggregateException]::new([Exception[]]@($fault, [InvalidOperationException]::new('Other failure.')))
            }
            $record = [Management.Automation.ErrorRecord]::new($fault, 'Fixture', 'PermissionDenied', $null)
            Test-AvmBicepAuthorizationFailed -ErrorRecord $record | Should -BeFalse
        }
    }

    It 'never starts a read after its recovery deadline' {
        InModuleScope Avm.Authoring {
            $deadline = (Get-Date -AsUTC).AddSeconds(-1)
            { Invoke-AvmBicepAuthorizationRead -DeadlineUtc $deadline -Read { $script:calls++ } } |
                Should -Throw '*deadline*'
            $script:calls | Should -Be 0
        }
    }
}
