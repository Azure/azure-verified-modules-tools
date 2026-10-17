#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Native Terraform qualification mock boundary' -Tag Component {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
        . (Join-Path $PSScriptRoot '..' 'Helpers' 'TerraformQualification.ps1')
    }

    AfterAll { Remove-Module Avm.Authoring -Force }

    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $unit = Join-Path $script:root 'tests' 'unit'
        $null = New-Item -ItemType Directory -Path $unit -Force
        Set-Content -LiteralPath (Join-Path $unit 'fixture.tftest.hcl') -Value 'run "root" { command = plan }'
        $script:test = @{
            providers = @{}
            mock_providers = @{ azapi = @{}; terraform = @{}; 'azapi.unit' = @{} }
            runs = @{ root = @{ mptf = @{ attributes = @{} } } }
            run_modules = @{ root = @{ kind = 'root'; dir = $script:root } }
        }
        $script:sources = @('registry.terraform.io/azure/azapi', 'terraform.io/builtin/terraform')
        $script:required = @{
            azapi = @{ source = 'Azure/azapi' }
            terraform = @{ source = 'terraform.io/builtin/terraform' }
        }
        $script:parameters = @{
            Root = $script:root
            TerraformPath = Join-Path $TestDrive 'terraform'
            MapotfPath = Join-Path $TestDrive 'mapotf'
            ProfilesRoot = Join-Path $TestDrive 'profiles'
            ArgumentList = @('test', '-no-color', '-test-directory=tests/unit')
            Environment = @{}
        }
        Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
            ConvertFrom-Json -InputObject $Options.EnvVars.QUALIFICATION_REQUIREMENTS_JSON -AsHashtable
        }
        Mock Get-AvmTerraformUnitTestInspection -ModuleName Avm.Authoring {
            @{ test = ConvertFrom-Json -InputObject $Options.EnvVars.QUALIFICATION_TEST_JSON -AsHashtable }
        }
        Mock ConvertFrom-AvmTerraformProviderTree -ModuleName Avm.Authoring {
            ConvertFrom-Json -InputObject $Text
        }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring {
            [pscustomobject]@{
                ExitCode = 0
                StdOut = if ($ArgumentList[0] -ceq 'providers') { $EnvVars.QUALIFICATION_SOURCES_JSON } else { 'mocked test passed' }
                StdErr = ''
            }
        }
        function Set-QualificationEvidence {
            $script:parameters.Environment = @{
                QUALIFICATION_TEST_JSON = $script:test | ConvertTo-Json -Depth 20 -Compress
                QUALIFICATION_SOURCES_JSON = ConvertTo-Json -InputObject $script:sources -Compress
                QUALIFICATION_REQUIREMENTS_JSON = $script:required | ConvertTo-Json -Depth 10 -Compress
            }
        }
    }

    It 'executes only known default and same-provider alias mocks with isolated credentials and endpoints' {
        $script:test.runs.root.mptf.attributes.providers = '{ azapi = azapi.unit, terraform = terraform }'
        Set-QualificationEvidence
        $script:parameters.Environment.ARM_CLIENT_ID = 'synthetic-inherited-value'
        $script:parameters.Environment.AZURE_CLIENT_ID = 'synthetic-inherited-value'
        $script:parameters.Environment.TF_CLI_ARGS_test = '-filter=uninspected.tftest.hcl'
        $script:parameters.Environment.NO_PROXY = '*'
        $result = Invoke-MockedTerraformQualification @script:parameters
        $result.StdOut | Should -BeExactly 'mocked test passed'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter {
            $ArgumentList[0] -ceq 'test' -and
            $null -eq $EnvVars.ARM_CLIENT_ID -and $null -eq $EnvVars.AZURE_CLIENT_ID -and
            $null -eq $EnvVars.TF_CLI_ARGS_test -and $EnvVars.ARM_USE_CLI -ceq 'false' -and
            $EnvVars.ARM_USE_MSI -ceq 'false' -and $EnvVars.ARM_USE_OIDC -ceq 'false' -and
            $EnvVars.HTTP_PROXY -ceq 'http://127.0.0.1:1' -and $EnvVars.NO_PROXY -ceq '' -and
            $EnvVars.MODTM_ENDPOINT -ceq 'http://127.0.0.1:1/never-production' -and $EnvVars.CHECKPOINT_DISABLE -ceq '1'
        }
    }

    It 'returns the checked runtime environment without executing when used at a public-command boundary' {
        Set-QualificationEvidence
        $environment = Invoke-MockedTerraformQualification @script:parameters -InspectOnly
        $environment.HTTP_PROXY | Should -BeExactly 'http://127.0.0.1:1'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'test' }
    }

    It 'accepts unambiguous native built-in source proof for a plan with <Mapping> mocks' -TestCases @(
        @{ Mapping = 'default'; Mapped = $false }
        @{ Mapping = 'explicitly mapped'; Mapped = $true }
    ) {
        param($Mapped)
        $script:required.Remove('terraform')
        $script:test.runs.root.mptf.attributes.command = 'plan'
        if ($Mapped) {
            $script:test.runs.root.mptf.attributes.providers = '{ azapi = azapi.unit, terraform = terraform }'
        }
        Set-QualificationEvidence
        (Invoke-MockedTerraformQualification @script:parameters).StdOut | Should -BeExactly 'mocked test passed'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter { $ArgumentList[0] -ceq 'test' }
    }

    It 'rejects ambiguous native built-in source proof even for a plan-only run' {
        $script:required.Remove('terraform')
        $script:sources += 'registry.terraform.io/hashicorp/terraform'
        $script:test.runs.root.mptf.attributes.command = 'plan'
        Set-QualificationEvidence
        { Invoke-MockedTerraformQualification @script:parameters } |
            Should -Throw '*ambiguous built-in and registry provider evidence*'
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'test' }
    }

    It 'does not let plan-only source proof cover a separate <Command> apply run' -TestCases @(
        @{ Command = 'explicit'; Attributes = @{ command = 'apply' } }
        @{ Command = 'default'; Attributes = @{} }
        @{ Command = 'computed'; Attributes = @{ command = 'var.command' } }
        @{ Command = 'unrecognized'; Attributes = @{ command = 'refresh-only' } }
        @{ Command = 'incorrectly cased'; Attributes = @{ command = 'Plan' } }
        @{ Command = 'non-string'; Attributes = @{ command = @('plan') } }
    ) {
        param($Attributes)
        $script:required.Remove('terraform')
        $script:test.runs = [ordered]@{
            root = @{ mptf = @{ attributes = @{ command = 'plan' } } }
            apply = @{ mptf = @{ attributes = $Attributes } }
        }
        $script:test.run_modules.apply = @{ kind = 'root'; dir = $script:root }
        Set-QualificationEvidence
        { Invoke-MockedTerraformQualification @script:parameters } |
            Should -Throw "*requires a default mock for 'terraform.io/builtin/terraform'*run 'apply'*"
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'test' }
    }

    It 'checks each selected local target instead of imposing the root provider set on a setup run' {
        $helper = Join-Path $script:root 'tests' 'setup'
        $script:parameters.ModuleTargets = @(
            [pscustomobject]@{ Path = $script:root }
            [pscustomobject]@{ Path = $helper }
        )
        $script:test.run_modules.setup = @{ kind = 'local'; dir = $helper }
        $script:test.runs.setup = @{ mptf = @{ attributes = @{ providers = '{ azapi = azapi }' } } }
        Set-QualificationEvidence
        Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring { @('registry.terraform.io/azure/azapi') }
        Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
            @{ azapi = @{ source = 'Azure/azapi' } }
        } -ParameterFilter { $Path -ceq $helper }
        (Invoke-MockedTerraformQualification @script:parameters).StdOut | Should -BeExactly 'mocked test passed'
        Should -Invoke Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring -Exactly 1 -ParameterFilter { $Path -ceq $helper }
    }

    It 'rejects an unmocked provider used only by a selected local target' {
        $helper = Join-Path $script:root 'tests' 'setup'
        $script:parameters.ModuleTargets = @(
            [pscustomobject]@{ Path = $script:root }
            [pscustomobject]@{ Path = $helper }
        )
        $script:test.run_modules.root = @{ kind = 'local'; dir = $helper }
        Set-QualificationEvidence
        Mock Get-AvmTerraformUnitTestProviderSource -ModuleName Avm.Authoring { @('registry.terraform.io/hashicorp/random') }
        Mock Get-AvmTerraformUnitTestRequiredProvider -ModuleName Avm.Authoring {
            @{ random = @{ source = 'hashicorp/random' } }
        } -ParameterFilter { $Path -ceq $helper }
        { Invoke-MockedTerraformQualification @script:parameters } |
            Should -Throw "*requires a default mock for 'registry.terraform.io/hashicorp/random'*"
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'test' }
    }

    It 'rejects <Unsafe> before Terraform test execution' -ForEach @(
        @{ Unsafe = 'a real provider configuration'; Expected = '*rejects real provider configurations*' }
        @{ Unsafe = 'a missing Azure mock'; Expected = "*requires a default mock for 'registry.terraform.io/azure/azapi'*" }
        @{ Unsafe = 'a missing built-in mock'; Expected = "*requires a default mock for 'terraform.io/builtin/terraform'*" }
        @{ Unsafe = 'a missing explicit built-in source'; Expected = "*requires a default mock for 'terraform.io/builtin/terraform'*" }
        @{ Unsafe = 'a mismatched built-in source'; Expected = "*requires a default mock for 'terraform.io/builtin/terraform'*" }
        @{ Unsafe = 'an unmocked dependency'; Expected = "*requires a default mock for 'registry.terraform.io/azure/modtm'*" }
        @{ Unsafe = 'an ALZ runtime fixture'; Expected = '*ALZ library fixtures are preservation-only*' }
        @{ Unsafe = 'an omitted built-in mapping'; Expected = '*requires complete known same-provider mock mappings*' }
        @{ Unsafe = 'an omitted Azure mapping'; Expected = '*requires complete known same-provider mock mappings*' }
        @{ Unsafe = 'an unknown alias'; Expected = '*requires complete known same-provider mock mappings*' }
        @{ Unsafe = 'a cross-provider binding'; Expected = '*requires complete known same-provider mock mappings*' }
        @{ Unsafe = 'an aliased target key'; Expected = '*requires complete known same-provider mock mappings*' }
        @{ Unsafe = 'a computed mapping'; Expected = '*requires complete known same-provider mock mappings*' }
        @{ Unsafe = 'an unknown selected target'; Expected = '*requires a known local target*' }
        @{ Unsafe = 'JSON test configuration'; Expected = '*cannot establish mock coverage for JSON tests*' }
        @{ Unsafe = 'an uninspected root test'; Expected = '*rejects uninspected root test files*' }
        @{ Unsafe = 'a different test directory'; Expected = '*requires the inspected tests/unit directory*' }
        @{ Unsafe = 'a duplicate test directory'; Expected = '*requires the inspected tests/unit directory*' }
        @{ Unsafe = 'a direct apply command'; Expected = '*requires the inspected tests/unit directory*' }
    ) {
        switch ($Unsafe) {
            'a real provider configuration' { $script:test.providers.azapi = @{} }
            'a missing Azure mock' { $script:test.mock_providers.Remove('azapi') }
            'a missing built-in mock' { $script:test.mock_providers.Remove('terraform') }
            'a missing explicit built-in source' { $script:required.Remove('terraform') }
            'a mismatched built-in source' { $script:required.terraform = @{ source = 'hashicorp/terraform' } }
            'an unmocked dependency' { $script:sources += 'registry.terraform.io/azure/modtm' }
            'an ALZ runtime fixture' { $script:sources += 'registry.terraform.io/azure/alz' }
            'an omitted built-in mapping' { $script:test.runs.root.mptf.attributes.providers = '{ azapi = azapi.unit }' }
            'an omitted Azure mapping' { $script:test.runs.root.mptf.attributes.providers = '{ terraform = terraform }' }
            'an unknown alias' { $script:test.runs.root.mptf.attributes.providers = '{ azapi = azapi.unknown }' }
            'a cross-provider binding' { $script:test.runs.root.mptf.attributes.providers = '{ azapi = terraform }' }
            'an aliased target key' { $script:test.runs.root.mptf.attributes.providers = '{ azapi.unit = azapi }' }
            'a computed mapping' { $script:test.runs.root.mptf.attributes.providers = 'var.providers' }
            'an unknown selected target' { $script:test.run_modules.root.dir = Join-Path $script:root 'uninspected' }
            'JSON test configuration' { Set-Content -LiteralPath (Join-Path $script:root 'tests' 'unit' 'extra.tftest.json') -Value '{}' }
            'an uninspected root test' { Set-Content -LiteralPath (Join-Path $script:root 'extra.tftest.hcl') -Value 'run "extra" {}' }
            'a different test directory' { $script:parameters.ArgumentList = @('test', '-test-directory=other') }
            'a duplicate test directory' { $script:parameters.ArgumentList += '-test-directory=other' }
            'a direct apply command' { $script:parameters.ArgumentList = @('apply', '-test-directory=tests/unit') }
        }
        Set-QualificationEvidence
        { Invoke-MockedTerraformQualification @script:parameters } | Should -Throw $Expected
        Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 -ParameterFilter { $ArgumentList[0] -ceq 'test' }
    }
}
