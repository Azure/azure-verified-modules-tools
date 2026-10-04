#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Get-AvmBicepSafeErrorCode' {
    It 'returns nested validation codes in order from an SDK-shaped validation record' {
        InModuleScope Avm.Authoring {
            $body = @([pscustomobject]@{
                    Code = 'InvalidTemplateDeployment'; Message = 'do-not-print-secret'
                    Details = @([pscustomobject]@{ Code = 'AllocationFailed'; Message = 'do-not-print-secret' })
                })
            $record = [System.Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Validation failed.'), 'AvmBicepTemplateValidationFailed', 'InvalidResult', $body)
            Get-AvmBicepSafeErrorCode -ErrorRecord $record | Should -Be @('InvalidTemplateDeployment', 'AllocationFailed')
        }
    }

    It 'reads lowercase JSON details and innererror, deduplicates and ignores text that is not an error code' {
        InModuleScope Avm.Authoring {
            $record = [System.Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Deployment failed.'), 'NativeDeploymentError', 'InvalidResult', $null)
            $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new((ConvertTo-Json -Depth 10 -InputObject @{
                        error = @{ code = 'DeploymentFailed'; details = @(
                                @{ code = 'Conflict' }, @{ code = 'conflict' }, @{ code = 'has spaces secret=1' }, @{ code = 42 })
                                innererror = @{ code = 'InnerFailure' } }
                    }))
            Get-AvmBicepSafeErrorCode -ErrorRecord $record | Should -Be @('DeploymentFailed', 'InnerFailure', 'Conflict')
        }
    }

    It 'returns nothing for unstructured errors and stops at the limit and on cycles' {
        InModuleScope Avm.Authoring {
            $plain = [System.Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('Code=Leaked; secret'), 'Other', 'InvalidResult', $null)
            @(Get-AvmBicepSafeErrorCode -ErrorRecord $plain).Count | Should -Be 0
            $plain.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('not json')
            @(Get-AvmBicepSafeErrorCode -ErrorRecord $plain).Count | Should -Be 0

            $cycle = @{ code = 'Outer' }
            $cycle.details = @($cycle, @{ code = 'Inner' })
            $record = [System.Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new('x'), 'AvmBicepTemplateValidationFailed', 'InvalidResult', $cycle)
            Get-AvmBicepSafeErrorCode -ErrorRecord $record | Should -Be @('Outer', 'Inner')
            Get-AvmBicepSafeErrorCode -ErrorRecord $record -Limit 1 | Should -Be @('Outer')
        }
    }
}