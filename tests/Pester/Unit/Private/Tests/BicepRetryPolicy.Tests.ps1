#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep retry policy validation and generic matching' {
    It 'loads a bounded packaged policy with both explicit retry modes' {
        InModuleScope Avm.Authoring {
            $policy = Get-AvmBicepRetryPolicy
            $policy['limits']['deploymentAttempts'] | Should -Be 3
            $policy['limits']['regionAttempts'] | Should -Be 3
            $policy['reads']['attempts'] | Should -Be 3
            $policy['observation']['timeoutSeconds'] | Should -Be 3600
            $policy['modes']['InPlace']['location'] | Should -BeExactly 'Preserve'
            $policy['modes']['Fresh']['location'] | Should -BeExactly 'NextEligible'
            @($policy['rules'] | ForEach-Object { $_['mode'] } | Sort-Object -Unique) | Should -Be @('Fresh', 'InPlace')
            $validated = Get-AvmBicepRetryPolicy -InputObject $policy
            ($validated | ConvertTo-Json -Depth 40 -Compress) | Should -BeExactly ($policy | ConvertTo-Json -Depth 40 -Compress)
        }
    }

    It 'rejects invalid configuration before execution: <Invalid>' -ForEach @(
        @{ Invalid = 'unknown field' }, @{ Invalid = 'unknown mode' }, @{ Invalid = 'moving in-place mode' }
        @{ Invalid = 'missing mode' }, @{ Invalid = 'zero attempts' }, @{ Invalid = 'too many attempts' }
        @{ Invalid = 'too many regions' }, @{ Invalid = 'negative delay' }, @{ Invalid = 'too many reads' }
        @{ Invalid = 'unbounded observation' }, @{ Invalid = 'duplicate rule' }, @{ Invalid = 'invalid regex' }
        @{ Invalid = 'absent capture' }, @{ Invalid = 'missing target types' }, @{ Invalid = 'ambiguous empty code' }
        @{ Invalid = 'contradictory targets' }, @{ Invalid = 'contradictory parent' }
        @{ Invalid = 'missing JSON evidence' }, @{ Invalid = 'invalid numeric bounds' }, @{ Invalid = 'case-duplicate field' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Invalid = $Invalid } {
            param($Invalid)
            $policy = Get-AvmBicepRetryPolicy
            switch ($Invalid) {
                'unknown field' { $policy['execute'] = 'arbitrary command' }
                'unknown mode' { $policy['rules'][0]['mode'] = 'CleanAndReplay' }
                'moving in-place mode' { $policy['modes']['InPlace']['location'] = 'NextEligible' }
                'missing mode' { $policy['modes'].Remove('Fresh') }
                'zero attempts' { $policy['limits']['deploymentAttempts'] = 0 }
                'too many attempts' { $policy['limits']['deploymentAttempts'] = 4 }
                'too many regions' { $policy['limits']['regionAttempts'] = 4 }
                'negative delay' { $policy['limits']['delaySeconds'] = -1 }
                'too many reads' { $policy['reads']['attempts'] = 4 }
                'unbounded observation' { $policy['observation']['timeoutSeconds'] = 3601 }
                'duplicate rule' { $policy['rules'] += $policy['rules'][0] }
                'invalid regex' { $policy['rules'][0]['messagePatterns'] = @('[') }
                'absent capture' { $policy['rules'][0]['regionCapture'] = 'absent' }
                'missing target types' { $policy['rules'][0].Remove('targetTypes') }
                'ambiguous empty code' { $policy['rules'][0]['code'] = '' }
                'contradictory targets' { $policy['rules'][0]['forbidTarget'] = $true }
                'contradictory parent' { $policy['rules'][0]['parentWithoutTarget'] = $true }
                'missing JSON evidence' { $policy['rules'][0]['jsonMessagePattern'] = '\S' }
                'invalid numeric bounds' { $policy['rules'][1]['numberCaptures']['cpu']['maximum'] = 0 }
                'case-duplicate field' {
                    $copy = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
                    foreach ($key in $policy.psbase.Keys) { $copy.Add($key, $policy[$key]) }
                    $copy.Add('SchemaVersion', 1)
                    $policy = $copy
                }
            }
            { Get-AvmBicepRetryPolicy -InputObject $policy } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }

    It 'uses configured code, message and mode rather than service branches' {
        InModuleScope Avm.Authoring {
            $policy = Get-AvmBicepRetryPolicy
            $policy['rules'] = @(@{
                    id = 'fixture-consistency'; mode = 'InPlace'; code = 'FixtureNotReady'
                    messagePatterns = @('\AThe fixture is not ready\.\z')
                })
            $policy = Get-AvmBicepRetryPolicy -InputObject $policy
            $node = @{ code = 'FixtureNotReady'; message = 'The fixture is not ready.' }
            Test-AvmBicepRetryErrorNode -Node $node -Policy $policy -RetryKind Transient | Should -BeTrue
            Test-AvmBicepRetryErrorNode -Node $node -Policy $policy -RetryKind Regional | Should -BeFalse
            $policy['rules'][0]['mode'] = 'Fresh'
            Test-AvmBicepRetryErrorNode -Node $node -Policy $policy -RetryKind Regional | Should -BeTrue
            Test-AvmBicepRetryErrorNode -Node $node -Policy $policy -RetryKind Transient | Should -BeFalse
            $node.message = 'The fixture is not ready. Authorization denied.'
            Test-AvmBicepRetryErrorNode -Node $node -Policy $policy | Should -BeFalse
            $node = @{ code = 'AllocationFailed'; message = 'Insufficient capacity in the region.' }
            Test-AvmBicepRetryErrorNode -Node $node -Policy $policy | Should -BeFalse
        }
    }

    It 'never makes authentication or cancellation retryable through configuration: <Code>' -ForEach @(
        @{ Code = 'AuthorizationFailed' }, @{ Code = 'AuthenticationFailed' }
        @{ Code = 'OperationCancelled' }, @{ Code = 'PermissionDenied' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Code = $Code } {
            param($Code)
            $policy = Get-AvmBicepRetryPolicy
            $policy['rules'] = @(@{ id = 'unsafe'; mode = 'Fresh'; code = $Code; messagePatterns = @('\S') })
            $policy = Get-AvmBicepRetryPolicy -InputObject $policy
            Test-AvmBicepRetryErrorNode -Node @{ code = $Code; message = 'Capacity unavailable.' } -Policy $policy |
                Should -BeFalse
        }
    }

    It 'rejects unknown SDK evidence and independent inner failures' {
        InModuleScope Avm.Authoring {
            $node = [InvalidOperationException]::new('Insufficient capacity in the region.')
            $node | Add-Member -NotePropertyName Code -NotePropertyValue 'AllocationFailed'
            Test-AvmBicepRetryErrorNode -Node $node | Should -BeTrue
            $node | Add-Member -NotePropertyName unexpected -NotePropertyValue 'evidence'
            Test-AvmBicepRetryErrorNode -Node $node | Should -BeFalse
            $node = [InvalidOperationException]::new('Insufficient capacity in the region.', [UnauthorizedAccessException]::new())
            $node | Add-Member -NotePropertyName Code -NotePropertyValue 'AllocationFailed'
            Test-AvmBicepRetryErrorNode -Node $node | Should -BeFalse
        }
    }

    It 'lets authorization wording on a wrapper veto otherwise eligible child evidence' {
            InModuleScope Avm.Authoring {
                $node = @{
                    code = 'InvalidTemplateDeployment'
                    message = "The template deployment failed with error: 'Authorization failed for template resource.'"
                    details = @(@{ code = 'AllocationFailed'; message = 'Insufficient capacity in the region.' })
                }
                foreach ($kind in @('Regional', 'Transient')) {
                    Test-AvmBicepRetryErrorNode -Node $node -RetryKind $kind | Should -BeFalse
            }
        }
    }
}
