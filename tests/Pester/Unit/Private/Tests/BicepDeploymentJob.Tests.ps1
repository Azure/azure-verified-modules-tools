#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    $script:armOperationPath = Join-Path $moduleRoot 'Private' 'Tests' 'Invoke-AvmBicepNativeArmOperation.ps1'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep in-process deployment job' {
    It 'executes synchronously with the same profile and supports the information stream' {
        $fixturePath = Join-Path $TestDrive 'DeploymentJobFixture.psm1'
        @(
            ". '$($script:armOperationPath.Replace("'", "''"))'"
            'function Write-AvmLog { param($Level, $Message) }'
            'function New-AzManagementGroupDeployment {'
            '    [CmdletBinding(SupportsShouldProcess)]'
            '    param($Name, $Location, $ManagementGroupId, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt, $DefaultProfile)'
            "    if (-not `$PSBoundParameters.ContainsKey('Confirm') -or `$PSBoundParameters.Confirm -or"
            "        -not `$PSBoundParameters.ContainsKey('WhatIf') -or `$PSBoundParameters.WhatIf) {"
            "        throw 'Implicit What-If would block submission.'"
            '    }'
            "    Write-Information 'deployment information' -InformationAction Continue"
            '    [pscustomobject]@{'
            '        Name = $Name'
            '        SameProfile = [object]::ReferenceEquals($DefaultProfile, $TemplateParameterObject.profile)'
            "        AsJobPassed = `$PSBoundParameters.ContainsKey('AsJob')"
            '    }'
            '}'
        ) | Set-Content -LiteralPath $fixturePath
        $profile = [pscustomobject]@{ Tenant = 'fixture' }
        InModuleScope Avm.Authoring -Parameters @{ FixturePath = $fixturePath; Profile = $profile } {
            param($FixturePath, $Profile)
            $inputOptions = @{
                Scope = 'mg'; ManagementGroupId = 'fixture-mg'; DeploymentName = 'fixture'
                TemplatePath = 'fixture.json'; MetadataLocation = 'westus'
                Parameters = @{ profile = $Profile }; DefaultProfile = $Profile
            }
            $submission = [hashtable]::Synchronized(@{ Invoked = $false })
            $job = Start-AvmBicepNativeDeploymentJob -ModulePath $FixturePath -DeploymentInput $inputOptions `
                -AzureModulePaths @() -SubmissionState $submission -Confirm:$false
            try {
                $null = Wait-Job -Job $job
                @($job.Information | Where-Object MessageData -eq 'deployment information').Count | Should -Be 1
                $result = Receive-Job -Job $job -ErrorAction Stop
                $job.State | Should -Be 'Completed'
                $result.Name | Should -Be 'fixture'
                $result.SameProfile | Should -BeTrue
                $result.AsJobPassed | Should -BeFalse
                $submission.Invoked | Should -BeTrue
            }
            finally {
                Remove-Job -Job $job -Force
            }
        }

    }

    It 'does not start a deployment job when WhatIf is requested' {
        InModuleScope Avm.Authoring {
            $job = Start-AvmBicepNativeDeploymentJob -ModulePath 'fixture.psm1' `
                -DeploymentInput @{ DeploymentName = 'fixture' } -AzureModulePaths @() `
                -SubmissionState @{ Invoked = $false } -WhatIf
            $job | Should -BeNullOrEmpty
        }
    }

    It 'does not mark submission when the Azure module cannot be imported' {
        InModuleScope Avm.Authoring {
            $submission = [hashtable]::Synchronized(@{ Invoked = $false })
            $job = Start-AvmBicepNativeDeploymentJob -ModulePath 'fixture.psm1' `
                -DeploymentInput @{ DeploymentName = 'fixture' } -AzureModulePaths @('missing-azure-module.psd1') `
                -SubmissionState $submission -Confirm:$false
            try {
                $null = Wait-Job $job
                { Receive-Job $job -ErrorAction Stop } | Should -Throw
                $submission.Invoked | Should -BeFalse
            }
            finally { Remove-Job $job -Force }
        }
    }

    It 'does not mark submission when the deployment cmdlet fails parameter binding' {
        $fixturePath = Join-Path $TestDrive 'BindingFixture.psm1'
        @(
            ". '$($script:armOperationPath.Replace("'", "''"))'"
            'function Write-AvmLog { param($Level, $Message) }'
            'function New-AzSubscriptionDeployment { [CmdletBinding()] param() }'
        ) | Set-Content -LiteralPath $fixturePath
        InModuleScope Avm.Authoring -Parameters @{ FixturePath = $fixturePath } {
            param($FixturePath)
            $submission = [hashtable]::Synchronized(@{ Invoked = $false })
            $job = Start-AvmBicepNativeDeploymentJob -ModulePath $FixturePath `
                -DeploymentInput @{ Scope = 'sub'; DeploymentName = 'fixture'; TemplatePath = 'fixture.json'; MetadataLocation = 'westus' } `
                -AzureModulePaths @() -SubmissionState $submission -Confirm:$false
            try {
                $null = Wait-Job $job
                { Receive-Job $job -ErrorAction Stop } | Should -Throw
                $submission.Invoked | Should -BeFalse
            }
            finally { Remove-Job $job -Force }
        }
    }

    It 'keeps submission ambiguous when a binding exception occurs inside the command' {
        $fixturePath = Join-Path $TestDrive 'InvokedBindingFixture.psm1'
        @(
            ". '$($script:armOperationPath.Replace("'", "''"))'"
            'function Write-AvmLog { param($Level, $Message) }'
            'function New-AzSubscriptionDeployment {'
            '    [CmdletBinding(SupportsShouldProcess)]'
            '    param($Name, $Location, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt)'
            "    throw [System.Management.Automation.ParameterBindingException]::new('failure after invocation')"
            '}'
        ) | Set-Content -LiteralPath $fixturePath
        InModuleScope Avm.Authoring -Parameters @{ FixturePath = $fixturePath } {
            param($FixturePath)
            $submission = [hashtable]::Synchronized(@{ Invoked = $false })
            $job = Start-AvmBicepNativeDeploymentJob -ModulePath $FixturePath `
                -DeploymentInput @{ Scope = 'sub'; DeploymentName = 'fixture'; TemplatePath = 'fixture.json'; MetadataLocation = 'westus' } `
                -AzureModulePaths @() -SubmissionState $submission -Confirm:$false
            try {
                $null = Wait-Job $job
                { Receive-Job $job -ErrorAction Stop } | Should -Throw
                $submission.Invoked | Should -BeTrue
            }
            finally { Remove-Job $job -Force }
        }
    }
}
