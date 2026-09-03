#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmConftestOverrideWarning' {
    It 'reports one warning per rule and exception file' {
        $root = Join-Path $TestDrive 'conftest-warning-root'
        $exceptions = Join-Path $root 'examples' 'default' 'exceptions'
        New-Item -ItemType Directory -Path $exceptions -Force | Out-Null
        @'
package avmsec

exception contains rules if {
  rules = ["AVM_SEC_223", "AVM_SEC_224"]
}

exception contains rules if {
  rules = ["AVM_SEC_223"]
}

allow if {
  rules = ["NOT_AN_EXCEPTION"]
}
'@ | Set-Content -LiteralPath (Join-Path $exceptions 'avmsec.rego') -Encoding utf8

        $warnings = InModuleScope 'Avm.Authoring' -Parameters @{
            R = $root
            E = @(Join-Path $root 'examples' 'default')
        } {
            param($R, $E)
            Get-AvmConftestOverrideWarning -Root $R -ExamplePath $E
        }

        @($warnings).Count | Should -Be 2
        $warnings[0].File | Should -Be 'examples/default/exceptions/avmsec.rego'
        $warnings[0].Rule | Should -Be 'AVM_SEC_223'
        $warnings[1].File | Should -Be 'examples/default/exceptions/avmsec.rego'
        $warnings[1].Rule | Should -Be 'AVM_SEC_224'
    }

    It 'uses a distinct message when exception rules cannot be parsed' {
        $root = Join-Path $TestDrive 'conftest-unknown-warning-root'
        $exceptions = Join-Path $root 'examples' 'default' 'exceptions'
        New-Item -ItemType Directory -Path $exceptions -Force | Out-Null
        @'
package avmsec

exception contains rules if {
  rule_set = input.rules
}
'@ | Set-Content -LiteralPath (Join-Path $exceptions 'unknown.rego') -Encoding utf8

        $warnings = InModuleScope 'Avm.Authoring' -Parameters @{
            R = $root
            E = @(Join-Path $root 'examples' 'default')
        } {
            param($R, $E)
            Get-AvmConftestOverrideWarning -Root $R -ExamplePath $E
        }

        @($warnings).Count | Should -Be 1
        $warnings[0].File | Should -Be 'examples/default/exceptions/unknown.rego'
        $warnings[0].Rule | Should -Be ''
        $warnings[0].Message | Should -Be 'Conftest override file found, but no exempted rules could be parsed.'
    }
}

Describe 'Invoke-AvmTerraformCheckPolicy' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ('tf-mod-' + [guid]::NewGuid().ToString('N'))
        $script:exampleDir = Join-Path $script:moduleDir 'examples' 'default'
        $script:cacheDir = Join-Path $TestDrive ('cache-' + [guid]::NewGuid().ToString('N'))
        $script:aprlDir = Join-Path $TestDrive ('aprl-' + [guid]::NewGuid().ToString('N'))
        $script:avmsecDir = Join-Path $TestDrive ('avmsec-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:exampleDir -Force
        $null = New-Item -ItemType Directory -Path $script:cacheDir -Force
        $null = New-Item -ItemType Directory -Path $script:aprlDir -Force
        $null = New-Item -ItemType Directory -Path $script:avmsecDir -Force
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Value 'variable "x" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'terraform.tf') -Encoding utf8 -Value @'
terraform {
  required_providers {
    modtm = {
      source = "Azure/modtm"
    }
  }
}
'@
        Set-Content -LiteralPath (Join-Path $script:exampleDir 'main.tf') -Value 'module "test" { source = "../.." }' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:exampleDir 'terraform.tf') -Encoding utf8 -Value @'
terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

provider "azapi" {
  alias = "secondary"
}
'@
        Set-Content -LiteralPath (Join-Path $script:avmsecDir 'avm_exceptions.rego.bak') -Value 'package avmsec' -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }
    }

    It 'rejects a non-terraform context' {
        $bicepContext = [pscustomobject]@{ Root = $TestDrive; Ecosystem = 'bicep' }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bicepContext } {
                param($C)
                Invoke-AvmTerraformCheckPolicy -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'runs the complete plan-JSON lifecycle for every active example' {
        $preHook = Join-Path $script:exampleDir 'pre.ps1'
        $postHook = Join-Path $script:exampleDir 'post.ps1'
        $exceptionsDir = Join-Path $script:exampleDir 'exceptions'
        $ignoredDir = Join-Path $script:moduleDir 'examples' 'ignored'
        $null = New-Item -ItemType Directory -Path $exceptionsDir -Force
        $null = New-Item -ItemType Directory -Path $ignoredDir -Force
        Set-Content -LiteralPath $preHook -Value '$null = 1' -Encoding utf8
        Set-Content -LiteralPath $postHook -Value '$null = 1' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $exceptionsDir 'custom.rego') -Value 'package avmsec' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $ignoredDir 'main.tf') -Value 'variable "ignored" {}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $ignoredDir '.e2eignore') -Value '' -Encoding utf8

        $probe = InModuleScope 'Avm.Authoring' -Parameters @{
            C = $script:context
            Cache = $script:cacheDir
            Aprl = $script:aprlDir
            Avmsec = $script:avmsecDir
        } {
            param($C, $Cache, $Aprl, $Avmsec)
            $calls = [System.Collections.Generic.List[object]]::new()
            $script:providerCacheLock = $null
            Mock Resolve-AvmTool {
                if ($Name -eq 'conftest') {
                    [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Source = 'cache'; Path = '/fake/conftest' }
                }
                else {
                    [pscustomobject]@{ Name = 'terraform'; Version = '1.15.8'; Source = 'cache'; Path = '/fake/terraform' }
                }
            }
            Mock Resolve-AvmPolicyBundle {
                if ($Name -eq 'avm-policy-aprl') {
                    [pscustomobject]@{ Name = $Name; Path = $Aprl }
                }
                else {
                    [pscustomobject]@{ Name = $Name; Path = $Avmsec }
                }
            }
            Mock Get-AvmFolder { $Cache }
            Mock Lock-AvmTerraformPluginCache {
                $script:providerCacheLock = [System.IO.MemoryStream]::new()
                $script:providerCacheLock
            }
            Mock Invoke-AvmProcess {
                $calls.Add([pscustomobject]@{
                        FilePath         = $FilePath
                        Arguments        = @($ArgumentList)
                        WorkingDirectory = $WorkingDirectory
                        EnvVars          = if ($EnvVars -is [hashtable]) { @{} + $EnvVars } else { @{} }
                        PlanJsonExists   = Test-Path -LiteralPath (Join-Path $WorkingDirectory 'tfplan.json')
                        PlanJson         = if (Test-Path -LiteralPath (Join-Path $WorkingDirectory 'tfplan.json')) {
                            Get-Content -LiteralPath (Join-Path $WorkingDirectory 'tfplan.json') -Raw
                        }
                        else {
                            ''
                        }
                        PolicyTest       = if ($FilePath -eq '/fake/terraform' -and $ArgumentList[0] -eq 'test') {
                            Get-ChildItem -LiteralPath $WorkingDirectory -Recurse -File -Filter '*.tftest.hcl' |
                                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
                        }
                        else {
                            ''
                        }
                        CacheLockHeld    = (
                            $null -ne $script:providerCacheLock -and
                            $script:providerCacheLock.CanRead
                        )
                    })
                if ($ArgumentList[-1] -like '*pre.ps1') {
                    Set-Content -LiteralPath (Join-Path $WorkingDirectory '.env') -Value 'ARM_SUBSCRIPTION_ID=example-sub' -Encoding utf8
                }
                if ($FilePath -eq '/fake/terraform' -and $ArgumentList[0] -eq 'test') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = @(
                            '{"type":"version","terraform":"1.15.8"}'
                            '{"type":"test_plan","test_plan":{"plan_format_version":"1.2","resource_changes":[],"provider_schemas":{}}}'
                        ) -join "`n"
                        StdErr   = ''
                    }
                }
                if ($FilePath -eq '/fake/conftest' -and $ArgumentList[0] -eq 'parse') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = '[{"path":"main.tf","contents":{"terraform":[{"required_providers":[{"azapi":{"source":"Azure/azapi"},"modtm":{"source":"Azure/modtm"},"random":{"source":"hashicorp/random"}}]}],"provider":{"azapi":[{},{"alias":"secondary"}]},"resource":{"azapi_resource":{"example":[{"parent_id":"${one(azapi_resource.parent[*].output.id)}","private_service_connection":[{"private_connection_resource_id":"${azapi_resource.parent.output.id}"}]}]}}}}]'
                        StdErr = ''
                    }
                }
                if ($FilePath -eq '/fake/conftest') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = '[{"filename":"tfplan.json","namespace":"policy","successes":130}]'
                        StdErr   = ''
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            $result = Invoke-AvmTerraformCheckPolicy -Context $C
            [pscustomobject]@{
                Result = $result
                Calls  = $calls.ToArray()
                Cache  = $Cache
            }
        }

        $probe.Result.Status | Should -Be 'pass'
        $probe.Result.Evaluated | Should -Be 260
        $probe.Result.Issues.Count | Should -Be 0
        $preCall = @($probe.Calls | Where-Object { $_.Arguments[-1] -like '*pre.ps1' })[0]
        $postCall = @($probe.Calls | Where-Object { $_.Arguments[-1] -like '*post.ps1' })[0]
        $terraformCalls = @($probe.Calls | Where-Object FilePath -eq '/fake/terraform')
        $parseCalls = @($probe.Calls | Where-Object {
                $_.FilePath -eq '/fake/conftest' -and $_.Arguments[0] -eq 'parse'
            })
        $policyCalls = @($probe.Calls | Where-Object {
                $_.FilePath -eq '/fake/conftest' -and $_.Arguments[0] -eq 'test'
            })

        $preCall | Should -Not -BeNullOrEmpty
        $postCall | Should -Not -BeNullOrEmpty
        $terraformCalls.Count | Should -Be 2
        $terraformCalls[0].Arguments[0..3] | Should -Be @('init', '-upgrade', '-input=false', '-no-color')
        $terraformCalls[0].Arguments[4] | Should -BeLike '-test-directory=.avm-policy-tests-*'
        $terraformCalls[1].Arguments[0..3] | Should -Be @('test', '-json', '-verbose', '-no-color')
        $terraformCalls[1].Arguments[4] | Should -BeLike '-test-directory=.avm-policy-tests-*'
        foreach ($terraformCall in $terraformCalls) {
            $terraformCall.CacheLockHeld | Should -BeTrue
        }
        $terraformCalls[1].PolicyTest | Should -Match 'mock_provider "azapi" \{\s+override_during = plan'
        $terraformCalls[1].PolicyTest | Should -Match 'mock_provider "azapi" \{\s+alias = "secondary"'
        $terraformCalls[1].PolicyTest | Should -Match 'alias = "secondary"\s+override_during = plan'
        $terraformCalls[1].PolicyTest | Should -Match 'mock_provider "modtm" \{\s+override_during = plan'
        $terraformCalls[1].PolicyTest | Should -Match 'mock_provider "random" \{\s+override_during = plan'
        $parseCalls.Count | Should -BeGreaterThan 0
        $parseCalls[0].Arguments | Should -Contain '--parser'
        $parseCalls[0].Arguments | Should -Contain 'hcl2'
        $policyCalls.Count | Should -Be 2
        foreach ($policyCall in $policyCalls) {
            $policyCall.CacheLockHeld | Should -BeFalse
            $policyCall.Arguments | Should -Contain '--all-namespaces'
            $policyCall.Arguments | Should -Contain '--output'
            $policyCall.Arguments | Should -Contain 'json'
            $policyCall.Arguments[-1] | Should -Be 'tfplan.json'
            $policyCall.PlanJsonExists | Should -BeTrue
            $planJson = $policyCall.PlanJson | ConvertFrom-Json
            $planJson.format_version | Should -Be '1.2'
            $planJson.terraform_version | Should -Be '1.15.8'
            $planJson.configuration.root_module.resources[0].address | Should -Be 'azapi_resource.example'
            $planJson.configuration.root_module.resources[0].expressions.parent_id.references |
                Should -Contain 'azapi_resource.parent.output.id'
            $planJson.configuration.root_module.resources[0].expressions.private_service_connection[0].private_connection_resource_id.references |
                Should -Contain 'azapi_resource.parent.output.id'
            $policyCall.EnvVars['ARM_SUBSCRIPTION_ID'] | Should -Be 'example-sub'
            @($policyCall.Arguments | Where-Object { $_ -like '*default_exceptions*' }).Count | Should -Be 1
            @($policyCall.Arguments | Where-Object { $_ -like '*examples*default*exceptions' }).Count | Should -Be 1
        }
        @($probe.Calls | Where-Object WorkingDirectory -like '*ignored*').Count | Should -Be 0
        $policyCalls[0].Arguments | Should -Contain $script:aprlDir
        $policyCalls[0].Arguments | Should -Not -Contain $script:avmsecDir
        $policyCalls[1].Arguments | Should -Contain $script:avmsecDir
        $policyCalls[1].Arguments | Should -Not -Contain $script:aprlDir
        Test-Path -LiteralPath (Join-Path $probe.Cache 'policy-stage') |
            Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $probe.Cache 'policy-stage') -Force).Count |
            Should -Be 0
    }

    It 'emits warnings for local conftest exception overrides' {
        $exceptionsDir = Join-Path $script:exampleDir 'exceptions'
        $null = New-Item -ItemType Directory -Path $exceptionsDir -Force
        @'
package avmsec

exception contains rules if {
  rules = ["AVM_SEC_223"]
}
'@ | Set-Content -LiteralPath (Join-Path $exceptionsDir 'avmsec.rego') -Encoding utf8

        InModuleScope 'Avm.Authoring' -Parameters @{
            C = $script:context
            Cache = $script:cacheDir
            Aprl = $script:aprlDir
            Avmsec = $script:avmsecDir
        } {
            param($C, $Cache, $Aprl, $Avmsec)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmPolicyBundle {
                [pscustomobject]@{ Name = $Name; Path = $(if ($Name -eq 'avm-policy-aprl') { $Aprl } else { $Avmsec }) }
            }
            Mock Get-AvmFolder { $Cache }
            Mock Write-AvmLog
            Mock Invoke-AvmProcess {
                if ($FilePath -eq '/fake/conftest') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
                }
                if ($ArgumentList[0] -eq 'show') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            $null = Invoke-AvmTerraformCheckPolicy -Context $C

            Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter {
                $Level -eq 'Warning' -and
                $File -eq 'examples/default/exceptions/avmsec.rego' -and
                $Message -eq "Conftest override exempts rule 'AVM_SEC_223'."
            }
        }
    }

    It 'keeps local policy exceptions scoped to their own example' {
        $secondExample = Join-Path $script:moduleDir 'examples' 'secondary'
        $firstExceptions = Join-Path $script:exampleDir 'exceptions'
        $secondExceptions = Join-Path $secondExample 'exceptions'
        $null = New-Item -ItemType Directory -Path $firstExceptions -Force
        $null = New-Item -ItemType Directory -Path $secondExceptions -Force
        Set-Content -LiteralPath (Join-Path $secondExample 'main.tf') -Value 'module "test" { source = "../.." }' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $firstExceptions 'first.rego') -Value 'package first' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $secondExceptions 'second.rego') -Value 'package second' -Encoding utf8

        $calls = InModuleScope 'Avm.Authoring' -Parameters @{
            C = $script:context
            Cache = $script:cacheDir
            Aprl = $script:aprlDir
            Avmsec = $script:avmsecDir
        } {
            param($C, $Cache, $Aprl, $Avmsec)
            $seen = [System.Collections.Generic.List[object]]::new()
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmPolicyBundle {
                [pscustomobject]@{ Name = $Name; Path = $(if ($Name -eq 'avm-policy-aprl') { $Aprl } else { $Avmsec }) }
            }
            Mock Get-AvmFolder { $Cache }
            Mock Invoke-AvmProcess {
                if ($FilePath -eq '/fake/conftest' -and $ArgumentList[0] -eq 'parse') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
                }
                if ($FilePath -eq '/fake/conftest') {
                    $seen.Add([pscustomobject]@{ WorkingDirectory = $WorkingDirectory; Arguments = @($ArgumentList) })
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
                }
                if ($FilePath -eq '/fake/terraform' -and $ArgumentList[0] -eq 'test') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = '{"type":"test_plan","test_plan":{"plan_format_version":"1.2"}}'
                        StdErr = ''
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            $null = Invoke-AvmTerraformCheckPolicy -Context $C
            $seen.ToArray()
        }

        $calls.Count | Should -Be 4
        foreach ($call in $calls) {
            $call.Arguments[6] | Should -Be '--policy'
            $localExceptions = $call.Arguments[7]
            $stageRoot = Split-Path -Path (Split-Path -Path $call.WorkingDirectory -Parent) -Parent
            $localExceptions | Should -Be (Join-Path $call.WorkingDirectory 'exceptions')
            $localExceptions | Should -BeLike "$stageRoot*"
            $localExceptions | Should -Not -BeLike "$($script:moduleDir)*"
            [System.IO.Path]::GetPathRoot($localExceptions) |
                Should -Be ([System.IO.Path]::GetPathRoot($stageRoot))
        }
    }

    It 'surfaces real conftest failures against the example plan JSON' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            C = $script:context
            Cache = $script:cacheDir
            Aprl = $script:aprlDir
            Avmsec = $script:avmsecDir
        } {
            param($C, $Cache, $Aprl, $Avmsec)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmPolicyBundle {
                [pscustomobject]@{ Name = $Name; Path = $(if ($Name -eq 'avm-policy-aprl') { $Aprl } else { $Avmsec }) }
            }
            Mock Get-AvmFolder { $Cache }
            Mock Invoke-AvmProcess {
                if ($FilePath -eq '/fake/conftest' -and $ArgumentList[0] -eq 'parse') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
                }
                if ($FilePath -eq '/fake/conftest' -and $ArgumentList -contains $Aprl) {
                    return [pscustomobject]@{
                        ExitCode = 1
                        StdOut   = '[{"filename":"tfplan.json","namespace":"Azure_Proactive_Resiliency_Library_v2","successes":129,"failures":[{"msg":"zone redundancy required"}]}]'
                        StdErr   = ''
                    }
                }
                if ($FilePath -eq '/fake/conftest') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = '[{"filename":"tfplan.json","namespace":"avmsec","successes":100}]'
                        StdErr   = ''
                    }
                }
                if ($FilePath -eq '/fake/terraform' -and $ArgumentList[0] -eq 'test') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = '{"type":"test_plan","test_plan":{"plan_format_version":"1.2"}}'
                        StdErr = ''
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            Invoke-AvmTerraformCheckPolicy -Context $C
        }

        $result.Status | Should -Be 'fail'
        $result.Evaluated | Should -Be 230
        $result.Issues.Count | Should -Be 1
        $result.Issues[0].Code | Should -Be 'Azure_Proactive_Resiliency_Library_v2'
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].File | Should -Be 'examples/default/tfplan.json'
        $result.Issues[0].Message | Should -Be 'zone redundancy required'
    }

    It 'preserves a Terraform plan failure when the post hook also fails' {
        Set-Content -LiteralPath (Join-Path $script:exampleDir 'post.ps1') -Value '$null = 1' -Encoding utf8
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{
            C = $script:context
            Cache = $script:cacheDir
            Aprl = $script:aprlDir
            Avmsec = $script:avmsecDir
        } {
            param($C, $Cache, $Aprl, $Avmsec)
            $script:postRan = $false
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmPolicyBundle {
                [pscustomobject]@{ Name = $Name; Path = $(if ($Name -eq 'avm-policy-aprl') { $Aprl } else { $Avmsec }) }
            }
            Mock Get-AvmFolder { $Cache }
            Mock Write-AvmLog
            Mock Invoke-AvmProcess {
                if ($FilePath -eq '/fake/conftest' -and $ArgumentList[0] -eq 'parse') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
                }
                if ($ArgumentList[-1] -like '*post.ps1') {
                    $script:postRan = $true
                    throw [AvmConfigurationException]::new('post hook failed')
                }
                if ($FilePath -eq '/fake/terraform' -and $ArgumentList[0] -eq 'test') {
                    throw [AvmProcessException]::new('terraform policy test failed')
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            $caught = $null
            try {
                $null = Invoke-AvmTerraformCheckPolicy -Context $C
            }
            catch {
                $caught = $_
            }
            [pscustomobject]@{
                ErrorName = $caught.Exception.GetType().Name
                Message   = $caught.Exception.Message
                PostRan   = $script:postRan
            }

            Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter {
                $Level -eq 'Warning' -and
                $File -like '*examples*default*post.ps1' -and
                $Message -match 'post hook failed' -and
                $Message -match 'preserving the primary error'
            }
        }

        $probe.ErrorName | Should -Be 'AvmProcessException'
        $probe.Message | Should -Match 'terraform policy test failed'
        $probe.Message | Should -Not -Match 'post hook failed'
        $probe.PostRan | Should -BeTrue
    }

    It 'surfaces a post hook failure when policy evaluation succeeds' {
        Set-Content -LiteralPath (Join-Path $script:exampleDir 'post.ps1') -Value '$null = 1' -Encoding utf8
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{
            C = $script:context
            Cache = $script:cacheDir
            Aprl = $script:aprlDir
            Avmsec = $script:avmsecDir
        } {
            param($C, $Cache, $Aprl, $Avmsec)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmPolicyBundle {
                [pscustomobject]@{ Name = $Name; Path = $(if ($Name -eq 'avm-policy-aprl') { $Aprl } else { $Avmsec }) }
            }
            Mock Get-AvmFolder { $Cache }
            Mock Invoke-AvmProcess {
                if ($ArgumentList[-1] -like '*post.ps1') {
                    throw [AvmConfigurationException]::new('post hook failed')
                }
                if ($FilePath -eq '/fake/terraform' -and $ArgumentList[0] -eq 'test') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut = '{"type":"test_plan","test_plan":{"plan_format_version":"1.2"}}'
                        StdErr = ''
                    }
                }
                if ($FilePath -eq '/fake/conftest' -and $ArgumentList[0] -eq 'parse') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
                }
                if ($FilePath -eq '/fake/conftest') {
                    return [pscustomobject]@{
                        ExitCode = 0
                        StdOut   = '[{"filename":"tfplan.json","namespace":"main","successes":1}]'
                        StdErr   = ''
                    }
                }
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }

            try {
                $null = Invoke-AvmTerraformCheckPolicy -Context $C
            }
            catch {
                [pscustomobject]@{
                    ErrorName = $_.Exception.GetType().Name
                    Message   = $_.Exception.Message
                }
            }
        }

        $probe.ErrorName | Should -Be 'AvmConfigurationException'
        $probe.Message | Should -Match 'post hook failed'
    }

    It 'rejects all shell hooks before process execution' {
        foreach ($hookName in @('pre', 'post')) {
            Set-Content -LiteralPath (Join-Path $script:exampleDir "$hookName.sh") -Value '#!/bin/sh' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $script:exampleDir "$hookName.ps1") -Value '$null = 1' -Encoding utf8
        }
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{
            C = $script:context
            Cache = $script:cacheDir
            Aprl = $script:aprlDir
            Avmsec = $script:avmsecDir
        } {
            param($C, $Cache, $Aprl, $Avmsec)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmPolicyBundle {
                [pscustomobject]@{ Name = $Name; Path = $(if ($Name -eq 'avm-policy-aprl') { $Aprl } else { $Avmsec }) }
            }
            Mock Get-AvmFolder { $Cache }
            Mock Invoke-AvmProcess {
                throw 'A shell hook must fail before any process starts.'
            }

            try {
                $null = Invoke-AvmTerraformCheckPolicy -Context $C
            }
            catch {
                [pscustomobject]@{
                    ErrorName = $_.Exception.GetType().Name
                    Message = $_.Exception.Message
                }
            }

            Should -Invoke Invoke-AvmProcess -Exactly 0
        }

        $probe.ErrorName | Should -Be 'AvmConfigurationException'
        $probe.Message | Should -Match 'Refactor'
        $probe.Message | Should -Match '\.ps1'
        $probe.Message | Should -Match 'pre\.sh'
        $probe.Message | Should -Match 'post\.sh'
    }

    It 'returns skipped when every example is ignored' {
        Set-Content -LiteralPath (Join-Path $script:exampleDir '.e2eignore') -Value '' -Encoding utf8
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            C = $script:context
            Aprl = $script:aprlDir
            Avmsec = $script:avmsecDir
        } {
            param($C, $Aprl, $Avmsec)
            Mock Resolve-AvmTool {
                [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
            }
            Mock Resolve-AvmPolicyBundle {
                [pscustomobject]@{ Name = $Name; Path = $(if ($Name -eq 'avm-policy-aprl') { $Aprl } else { $Avmsec }) }
            }
            Mock Invoke-AvmProcess { throw 'should not run' }
            Invoke-AvmTerraformCheckPolicy -Context $C
        }

        $result.Status | Should -Be 'skipped'
        $result.Evaluated | Should -Be 0
        $result.Issues.Count | Should -Be 0
        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 0
        }
    }

    It 'rejects a pinned AVMSEC bundle without its default exemption policy' {
        Remove-Item -LiteralPath (Join-Path $script:avmsecDir 'avm_exceptions.rego.bak') -Force
        $exceptionName = ''
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{
                C = $script:context
                Aprl = $script:aprlDir
                Avmsec = $script:avmsecDir
            } {
                param($C, $Aprl, $Avmsec)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
                }
                Mock Resolve-AvmPolicyBundle {
                    [pscustomobject]@{ Name = $Name; Path = $(if ($Name -eq 'avm-policy-aprl') { $Aprl } else { $Avmsec }) }
                }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }
        }
        catch {
            $exceptionName = $_.Exception.GetType().Name
        }
        $exceptionName | Should -Be 'AvmConfigurationException'
    }

    It 'rejects conflicting provider source declarations before terraform init' {
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'terraform.tf') -Encoding utf8 -Value @'
terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
  }
}
'@
        Set-Content -LiteralPath (Join-Path $script:exampleDir 'terraform.tf') -Encoding utf8 -Value @'
terraform {
  required_providers {
    azapi = {
      source = "hashicorp/azapi"
    }
  }
}
'@

        $exceptionName = ''
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{
                Example = $script:exampleDir
                Root = $script:moduleDir
            } {
                param($Example, $Root)
                Mock Invoke-AvmProcess {
                    $stdout = if ($WorkingDirectory -eq $Root) {
                        '[{"path":"terraform.tf","contents":{"terraform":[{"required_providers":[{"azapi":{"source":"Azure/azapi"}}]}]}}]'
                    }
                    else {
                        '[{"path":"terraform.tf","contents":{"terraform":[{"required_providers":[{"azapi":{"source":"hashicorp/azapi"}}]}]}}]'
                    }
                    [pscustomobject]@{
                        ExitCode = 0
                        StdOut = $stdout
                        StdErr = ''
                    }
                }
                New-AvmTerraformPolicyTest `
                    -WorkingDirectory $Example `
                    -ModuleRoot $Root `
                    -ConftestPath '/fake/conftest'
            }
        }
        catch {
            $exceptionName = $_.Exception.GetType().Name
        }
        $exceptionName | Should -Be 'AvmConfigurationException'
    }

    It 'throws when conftest exits without a policy result' {
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{
                C = $script:context
                Cache = $script:cacheDir
                Aprl = $script:aprlDir
                Avmsec = $script:avmsecDir
            } {
                param($C, $Cache, $Aprl, $Avmsec)
                Mock Resolve-AvmTool {
                    [pscustomobject]@{ Name = $Name; Version = 'test'; Source = 'cache'; Path = "/fake/$Name" }
                }
                Mock Resolve-AvmPolicyBundle {
                    [pscustomobject]@{ Name = $Name; Path = $(if ($Name -eq 'avm-policy-aprl') { $Aprl } else { $Avmsec }) }
                }
                Mock Get-AvmFolder { $Cache }
                Mock Invoke-AvmProcess {
                    if ($FilePath -eq '/fake/conftest' -and $ArgumentList[0] -eq 'parse') {
                        return [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
                    }
                    if ($FilePath -eq '/fake/conftest') {
                        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'load failed' }
                    }
                    if ($FilePath -eq '/fake/terraform' -and $ArgumentList[0] -eq 'test') {
                        return [pscustomobject]@{
                            ExitCode = 0
                            StdOut = '{"type":"test_plan","test_plan":{"plan_format_version":"1.2"}}'
                            StdErr = ''
                        }
                    }
                    [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
                }
                $exception = $null
                try {
                    $null = Invoke-AvmTerraformCheckPolicy -Context $C
                }
                catch {
                    $exception = $_.Exception
                }
                $exception
            }
        $probe.GetType().Name | Should -Be 'AvmProcessException'
        $probe.Message | Should -Match 'load failed'
    }
}
