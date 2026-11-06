#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    $script:savedActions = $env:GITHUB_ACTIONS
    $script:savedWorkspace = $env:GITHUB_WORKSPACE
}

AfterAll {
    $env:GITHUB_ACTIONS = $script:savedActions
    $env:GITHUB_WORKSPACE = $script:savedWorkspace
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Assert-AvmCommandSuccess annotations' {
    BeforeEach {
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_WORKSPACE = ''
    }

    AfterEach {
        $env:GITHUB_ACTIONS = ''
        $env:GITHUB_WORKSPACE = ''
    }

    It 'F41: emits exactly one annotation, anchored on the failing position' {
        $messages = InModuleScope 'Avm.Authoring' {
            $captured = @()
            $result = [pscustomobject]@{
                Status = 'fail'
                Issues = @(
                    [pscustomobject]@{ Severity = 'error'; File = 'tests\unit\a.tftest.hcl'; Line = 0; Column = 0; Message = "test run 'x' fail" },
                    [pscustomobject]@{ Severity = 'error'; File = 'tests\unit\a.tftest.hcl'; Line = 17; Column = 21; Message = 'Test assertion failed' }
                )
            }
            try {
                Assert-AvmCommandSuccess -Verb 'test unit' -Status 'fail' -Result $result -InformationVariable captured
            }
            catch {
                # the terminating error is the point of the helper; the log is what is under test
            }
            @($captured | ForEach-Object { [string]$_.MessageData })
        }

        $annotations = @($messages | Where-Object { $_ -like '::error*' })
        $annotations.Count | Should -Be 1
        $annotations[0] | Should -BeExactly '::error file=tests/unit/a.tftest.hcl,line=17,col=21::error tests\unit\a.tftest.hcl:17:21 Test assertion failed'
        @($messages) | Should -Contain 'avm test unit failed (fail).'
    }

    It 'F41: still annotates when the failure carries no position' {
        $messages = InModuleScope 'Avm.Authoring' {
            $captured = @()
            try {
                Assert-AvmCommandSuccess -Verb 'lint' -Status 'fail' -Result ([pscustomobject]@{ Status = 'fail' }) -InformationVariable captured
            }
            catch {
                # expected
            }
            @($captured | ForEach-Object { [string]$_.MessageData })
        }

        $annotations = @($messages | Where-Object { $_ -like '::error*' })
        $annotations.Count | Should -Be 1
        $annotations[0] | Should -BeExactly '::error::avm lint failed (fail).'
    }

    It 'F41: leaves the unanchored fallback in place for a positionless diagnostic' {
        $messages = InModuleScope 'Avm.Authoring' {
            $captured = @()
            $result = [pscustomobject]@{
                Status = 'fail'
                Issues = @([pscustomobject]@{ Severity = 'error'; Message = 'something broke' })
            }
            try {
                Assert-AvmCommandSuccess -Verb 'format' -Status 'fail' -Result $result -InformationVariable captured
            }
            catch {
                # expected
            }
            @($captured | ForEach-Object { [string]$_.MessageData })
        }

        $annotations = @($messages | Where-Object { $_ -like '::error*' })
        $annotations.Count | Should -Be 1
        $annotations[0] | Should -BeExactly '::error::error something broke'
    }

    It 'keeps the diagnostic and result on the exception without replaying them in the terminating error' {
        InModuleScope 'Avm.Authoring' {
            $detail = "Process exited with code 1: terraform plan`n  InvalidAuthenticationTokenTenant"
            $result = [pscustomobject]@{
                Status = 'error'
                Steps = @([pscustomobject]@{ Step = 'check policy'; Status = 'error'; Error = $detail })
            }
            $captured = @()
            $caught = $null
            try {
                Assert-AvmCommandSuccess -Verb 'pr-check' -Status 'error' -Result $result -InformationVariable captured
            }
            catch {
                $caught = $_
            }
            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.GetType().Name | Should -Be 'AvmCommandException'
            $caught.FullyQualifiedErrorId | Should -Match 'AVM1040'
            [object]::ReferenceEquals($caught.Exception.Result, $result) | Should -BeTrue
            $caught.Exception.Message | Should -Match 'InvalidAuthenticationTokenTenant'
            $caught.ErrorDetails.Message | Should -BeExactly 'avm pr-check failed (error).'
            $annotations = @($captured | ForEach-Object { [string]$_.MessageData } | Where-Object { $_ -like '::error*' })
            $annotations | Should -HaveCount 1
            $annotations[0] | Should -Match 'InvalidAuthenticationTokenTenant'
        }
    }

    Describe 'Gauntlet failure narration' {
        It 'narrates only the headline and retains full failure detail for <Command>' -ForEach @(
            @{ Command = 'Invoke-AvmPrCheck' }
            @{ Command = 'Invoke-AvmPreCommit' }
        ) {
            InModuleScope 'Avm.Authoring' -Parameters @{ Command = $Command } {
                param($Command)
                Mock Get-AvmModuleContextInternal { [pscustomobject]@{ Root = 'fixture'; Ecosystem = 'bicep' } }
                Mock Test-AvmDisableSentinel {}
                Mock Assert-AvmGitWorkingTreeClean {}
                Mock Resolve-AvmCommandTool { @() }
                Mock Test-AvmMetadataModules { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmSync { [pscustomobject]@{ Status = 'pass' } }
                Mock Invoke-AvmFormat { throw [System.Exception]::new("Tool failed`nDetailed failure cause") }
                Mock Write-AvmLog {}

                $result = & $Command -Path fixture -Ecosystem bicep -SkipModuleVersionCheck

                $result.Status | Should -Be 'error'
                $result.Steps[-1].Error | Should -BeExactly "Tool failed`nDetailed failure cause"
                Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter { $Message -eq '  format: Tool failed' }
                Should -Invoke Write-AvmLog -Exactly 0 -ParameterFilter { $Message -match 'Detailed failure cause' }
            }
        }
    }
}
