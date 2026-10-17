#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep JSON value fidelity' -Tag Component {
    It 'preserves an explicitly case-sensitive PowerShell hashtable during token replacement' {
        InModuleScope Avm.Authoring {
            $source = [hashtable]::new([StringComparer]::Ordinal)
            $source.Add('Name', 'upper')
            $source.Add('name', '#_value_#')
            $tokens = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
            $tokens.Add('value', 'lower')

            $result = Resolve-AvmBicepParameterToken -Value $source -Tokens $tokens

            $result.psbase.Count | Should -Be 2
            $result['Name'] | Should -BeExactly 'upper'
            $result['name'] | Should -BeExactly 'lower'
            $source['name'] | Should -BeExactly '#_value_#'
        }
    }

    It 'preserves authored and substituted timestamp strings: <Timestamp>' -ForEach @(
        @{ Timestamp = '2026-10-17T10:30:00.1234567+05:45' }
        @{ Timestamp = '2026-10-17T10:30:00.1234567Z' }
        @{ Timestamp = '2026-10-17T10:30:00-07:30' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Timestamp = $Timestamp } {
            param($Timestamp)
            $tokens = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
            $tokens.Add('timestamp', $Timestamp)
            $source = [System.Management.Automation.OrderedHashtable]::new()
            $source.Add('Name', $Timestamp)
            $source.Add('name', '#_timestamp_#')
            $source.Add('nested', (, @($Timestamp, '#_timestamp_#')))
            $result = Resolve-AvmBicepParameterToken -Value $source -Tokens $tokens

            $result.psbase.Count | Should -Be 3
            $result['Name'] | Should -BeOfType ([string])
            $result['Name'] | Should -BeExactly $Timestamp
            $result['name'] | Should -BeExactly $Timestamp
            $result['nested'][0][0] | Should -BeOfType ([string])
            $result['nested'][0][1] | Should -BeExactly $Timestamp
            $source['name'] | Should -BeExactly '#_timestamp_#'
        }
    }

    It 'preserves timestamp strings loaded from a token file' {
        $path = Join-Path $TestDrive 'tokens.json'
        $text = '{"timestamp":"2026-10-17T10:30:00.1234567+05:45"}'
        [IO.File]::WriteAllText($path, $text)
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive; Path = $path } {
            param($Root, $Path)
            $tokens = Get-AvmBicepTestTokenMap -Root $Root -SubscriptionId '11111111-1111-4111-8111-111111111111' -TokenFile $Path
            $tokens['timestamp'] | Should -BeExactly '2026-10-17T10:30:00.1234567+05:45'
        }
        [IO.File]::ReadAllText($path) | Should -BeExactly $text
    }

    It 'preserves native parameter-file strings and case-sensitive object keys through token replacement' {
        $path = Join-Path $TestDrive 'parameters.json'
        $text = '{"parameters":{"date":{"value":"2026-10-17T10:30:00.1234567+05:45"},"object":{"value":{"Name":"upper","name":"lower","nested":["2026-10-17T10:30:00Z"]}},"empty":{"value":[]},"nil":{"value":null}}}'
        [IO.File]::WriteAllText($path, $text)
        InModuleScope Avm.Authoring -Parameters @{ Path = $path } {
            param($Path)
            $tokens = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
            $native = Get-AvmBicepNativeParameter -ParameterPath $Path
            $result = Resolve-AvmBicepParameterToken -Value $native -Tokens $tokens
            $result.date | Should -BeOfType ([string])
            $result.date | Should -BeExactly '2026-10-17T10:30:00.1234567+05:45'
            $result.object['Name'] | Should -BeExactly 'upper'
            $result.object['name'] | Should -BeExactly 'lower'
            $result.object.nested[0] | Should -BeOfType ([string])
            ($result.empty -is [array]) | Should -BeTrue
            $result.empty.Count | Should -Be 0
            ($null -eq $result.nil) | Should -BeTrue
        }
        [IO.File]::ReadAllText($path) | Should -BeExactly $text
    }

    It 'preserves opt-in workflow timestamp strings before CI parameter type conversion' {
        $names = @('AVM_CI_VARIABLES', 'AVM_CI_SECRETS')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            $env:AVM_CI_VARIABLES = '{"CI_DATE":"2026-10-17T10:30:00.1234567+05:45"}'
            $env:AVM_CI_SECRETS = '{}'
            InModuleScope Avm.Authoring {
                $environment = Get-AvmBicepWorkflowEnvironment -Enabled
                $environment.Variables.CI_DATE | Should -BeOfType ([string])
                $result = Get-AvmBicepCiParameter -TemplateParameters @{ date = @{ type = 'string' } } `
                    -Variables $environment.Variables -Secrets $environment.Secrets
                $result.date | Should -BeExactly '2026-10-17T10:30:00.1234567+05:45'
            }
        }
        finally {
            foreach ($name in $names) {
                $value = if ($null -eq $saved[$name]) { [NullString]::Value } else { $saved[$name] }
                [Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
        }
    }

    It 'preserves timestamp strings inside CI <Type> values' -ForEach @(
        @{ Type = 'object'; Json = '{"date":"2026-10-17T10:30:00.1234567+05:45","empty":[]}' }
        @{ Type = 'secureObject'; Json = '{"date":"2026-10-17T10:30:00.1234567+05:45","empty":[]}' }
        @{ Type = 'array'; Json = '[{"date":"2026-10-17T10:30:00.1234567+05:45","empty":[]}]' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Type = $Type; Json = $Json } {
            param($Type, $Json)
            $result = Get-AvmBicepCiParameter -TemplateParameters @{ input = @{ type = $Type } } `
                -Variables @{ CI_INPUT = $Json }
            $value = if ($Type -eq 'array') { $result.input[0] } else { $result.input }
            $value.date | Should -BeOfType ([string])
            $value.date | Should -BeExactly '2026-10-17T10:30:00.1234567+05:45'
            ($value.empty -is [array]) | Should -BeTrue
            $value.empty.Count | Should -Be 0
        }
    }

    It 'preserves timestamp literals in compiled test templates without rewriting their bytes' {
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive } {
            param($Root)
            $script:compiled = '{"$schema":"https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#","parameters":{"date":{"type":"string","defaultValue":"2026-10-17T10:30:00.1234567+05:45"}},"resources":[]}'
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $script:compiled; StdErr = '' } }
            $tokens = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
            $path = Join-Path $Root 'compiled.json'
            $result = New-AvmBicepTestTemplate -SourcePath (Join-Path $Root 'main.test.bicep') `
                -DestinationPath $path -BicepPath 'fixture-bicep' -Tokens $tokens -Confirm:$false
            $result.Template.parameters.date.defaultValue | Should -BeOfType ([string])
            $result.Template.parameters.date.defaultValue | Should -BeExactly '2026-10-17T10:30:00.1234567+05:45'
            [IO.File]::ReadAllText($path) | Should -BeExactly $script:compiled
        }
    }

    It 'rejects invalid <Surface> <Shape> values without leaking their contents' -ForEach @(
        @{ Surface = 'token file'; Shape = 'JSON'; Json = '{"date":"private-sentinel"' }
        @{ Surface = 'token file'; Shape = 'root'; Json = '["private-sentinel"]' }
        @{ Surface = 'parameter file'; Shape = 'JSON'; Json = '{"parameters":{"date":{"value":"private-sentinel"}}' }
        @{ Surface = 'parameter file'; Shape = 'root'; Json = '["private-sentinel"]' }
        @{ Surface = 'CI object'; Shape = 'JSON'; Json = '{"date":"private-sentinel"' }
        @{ Surface = 'CI object'; Shape = 'root'; Json = '["private-sentinel"]' }
    ) {
        $path = Join-Path $TestDrive 'invalid.json'
        [IO.File]::WriteAllText($path, $Json)
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive; Path = $path; Surface = $Surface; Json = $Json } {
            param($Root, $Path, $Surface, $Json)
            $failure = {
                switch ($Surface) {
                    'token file' {
                        Get-AvmBicepTestTokenMap -Root $Root -SubscriptionId '11111111-1111-4111-8111-111111111111' -TokenFile $Path
                    }
                    'parameter file' { Get-AvmBicepNativeParameter -ParameterPath $Path }
                    'CI object' {
                        Get-AvmBicepCiParameter -TemplateParameters @{ input = @{ type = 'object' } } -Secrets @{ CI_INPUT = $Json }
                    }
                }
            } | Should -Throw -PassThru
            $failure.Exception.Message | Should -Not -Match 'private-sentinel'
        }
    }

    It 'rejects malformed assertion outputs before authored scripts: <Shape>' -ForEach @(
        @{ Shape = 'invalid JSON'; Json = '{"properties":{"outputs":"private-sentinel"' }
        @{ Shape = 'array root'; Json = '[{"properties":{"outputs":{"date":{"value":"private-sentinel"}}}}]' }
        @{ Shape = 'missing properties'; Json = '{"other":"private-sentinel"}' }
        @{ Shape = 'nonobject outputs'; Json = '{"properties":{"outputs":"private-sentinel"}}' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Json = $Json } {
            param($Json)
            Mock Invoke-AvmBicepPesterSuite { throw 'Authored assertions must not run for malformed outputs.' }
            $issues = [Collections.Generic.List[object]]::new()
            $item = [pscustomobject]@{
                Case = [pscustomobject]@{
                    Path = 'main.test.bicep'
                    RelativePath = 'tests/e2e/defaults/main.test.bicep'
                    RelativeDirectory = 'tests/e2e/defaults'
                }
                AssertionFiles = @('outputs.Tests.ps1')
            }
            $result = Invoke-AvmBicepTestE2eAssertion -Item $item -DeploymentName 'fixture' `
                -DeploymentOutput $Json -RepositoryRoot $TestDrive -Issues $issues -InProcess
            $result.Status | Should -BeExactly 'fail'
            $issues | Should -HaveCount 1
            $issues[0].Message | Should -Not -Match 'private-sentinel'
            Should -Invoke Invoke-AvmBicepPesterSuite -Exactly 0
        }
    }
}
