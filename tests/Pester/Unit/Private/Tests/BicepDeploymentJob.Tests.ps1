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
            'function New-AzSubscriptionDeployment {'
            '    [CmdletBinding(SupportsShouldProcess)]'
            '    param($Name, $Location, $TemplateFile, $TemplateParameterObject, $SkipTemplateParameterPrompt, $DefaultProfile)'
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
                Scope = 'sub'; DeploymentName = 'fixture'; TemplatePath = 'fixture.json'; MetadataLocation = 'westus'
                Parameters = @{ profile = $Profile }; DefaultProfile = $Profile
            }
            $job = Start-AvmBicepNativeDeploymentJob -ModulePath $FixturePath -DeploymentInput $inputOptions
            try {
                $null = Wait-Job -Job $job
                @($job.Information | Where-Object MessageData -eq 'deployment information').Count | Should -Be 1
                $result = Receive-Job -Job $job -ErrorAction Stop
                $job.State | Should -Be 'Completed'
                $result.Name | Should -Be 'fixture'
                $result.SameProfile | Should -BeTrue
                $result.AsJobPassed | Should -BeFalse
            }
            finally {
                Remove-Job -Job $job -Force
            }
        }
    }
}
