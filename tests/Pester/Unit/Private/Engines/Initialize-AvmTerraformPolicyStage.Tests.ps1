#Requires -Version 7.4

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    Import-Module $manifest -Force

    function New-PolicyProviderSchema {
        param([string] $Mode = 'modern')
        $attributes = @{ skip_provider_registration = @{ type = 'bool'; optional = $true } }
        if ($Mode -ne 'legacy') {
            $attributes.resource_provider_registrations = @{ type = 'string'; optional = $true }
            $attributes.resource_providers_to_register = @{ type = @('list', 'string'); optional = $true }
        }
        if ($Mode -eq 'future') { $attributes.Remove('skip_provider_registration') }
        return @{
            provider_schemas = @{
                'registry.terraform.io/hashicorp/azurerm' = @{ provider = @{ block = @{ attributes = $attributes } } }
                'registry.terraform.io/azure/azapi' = @{
                    provider = @{ block = @{ attributes = @{ skip_provider_registration = @{ type = 'bool'; optional = $true } } } }
                }
            }
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Terraform policy provider schema safeguards' {
    It 'selects safe settings from the <Mode> AzureRM schema and AzAPI' -ForEach @(
        @{ Mode = 'legacy' }, @{ Mode = 'modern' }, @{ Mode = 'future' }
    ) {
        $payload = New-PolicyProviderSchema -Mode $Mode | ConvertTo-Json -Depth 20
        $settings = InModuleScope Avm.Authoring -Parameters @{ Payload = $payload } {
            param($Payload)
            Get-AvmTerraformPolicyProviderSetting -Payload $Payload
        }
        $settings['registry.terraform.io/azure/azapi'].skip_provider_registration | Should -BeTrue
        $azureRm = $settings['registry.terraform.io/hashicorp/azurerm']
        if ($Mode -eq 'legacy') {
            $azureRm.skip_provider_registration | Should -BeTrue
            $azureRm.Count | Should -Be 1
        }
        else {
            $azureRm.resource_provider_registrations | Should -Be 'none'
            $azureRm.resource_providers_to_register | Should -HaveCount 0
            if ($Mode -eq 'modern') { $azureRm.skip_provider_registration | Should -BeFalse }
            else { $azureRm.ContainsKey('skip_provider_registration') | Should -BeFalse }
        }
    }

    It 'rejects an unsupported provider schema: <Case>' -ForEach @(
        @{ Case = 'invalid JSON'; Payload = '{' }
        @{ Case = 'missing schemas'; Payload = '{}' }
        @{ Case = 'missing provider'; Payload = '{"provider_schemas":{"registry.terraform.io/azure/azapi":{}}}' }
        @{ Case = 'wrong provider shape'; Payload = '{"provider_schemas":{"registry.terraform.io/azure/azapi":{"provider":"bad"}}}' }
        @{ Case = 'unknown source'; Payload = '{"provider_schemas":{"example.org/vendor/azapi":{}}}' }
        @{ Case = 'missing control'; Payload = '{"provider_schemas":{"registry.terraform.io/azure/azapi":{"provider":{"block":{"attributes":{}}}}}}' }
        @{ Case = 'wrong control type'; Payload = '{"provider_schemas":{"registry.terraform.io/azure/azapi":{"provider":{"block":{"attributes":{"skip_provider_registration":{"type":"string","optional":true}}}}}}}' }
        @{ Case = 'computed-only control'; Payload = '{"provider_schemas":{"registry.terraform.io/azure/azapi":{"provider":{"block":{"attributes":{"skip_provider_registration":{"type":"bool","computed":true}}}}}}}' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Payload = $Payload } {
            param($Payload)
            { Get-AvmTerraformPolicyProviderSetting -Payload $Payload } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }

    It 'rejects a modern AzureRM schema without a safe explicit registration-list control' {
        $schema = New-PolicyProviderSchema
        $schema.provider_schemas['registry.terraform.io/hashicorp/azurerm'].provider.block.attributes.Remove('resource_providers_to_register')
        InModuleScope Avm.Authoring -Parameters @{ Payload = ($schema | ConvertTo-Json -Depth 20) } {
            param($Payload)
            { Get-AvmTerraformPolicyProviderSetting -Payload $Payload } | Should -Throw '*resource_providers_to_register*'
        }
    }
}

Describe 'Terraform policy isolated environment' {
    It 'overrides contradictory registration and data flags without changing auth, inputs, or the caller environment' {
        $inputEnv = @{
            ARM_SKIP_PROVIDER_REGISTRATION = 'false'; ARM_RESOURCE_PROVIDER_REGISTRATIONS = 'all'
            ARM_TENANT_ID = 'fixture-tenant'; ARM_SUBSCRIPTION_ID = 'fixture-subscription'
            TF_DATA_DIR = 'outside-stage'; TF_VAR_location = 'fixture-region'
        }
        $environment = InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive; InputEnv = $inputEnv } {
            param($Root, $InputEnv)
            Get-AvmTerraformPolicyEnvironment -StageRoot $Root -Environment $InputEnv
        }
        $environment.ARM_SKIP_PROVIDER_REGISTRATION | Should -Be 'true'
        $environment.ARM_RESOURCE_PROVIDER_REGISTRATIONS | Should -Be 'legacy'
        $environment.TF_DATA_DIR | Should -Be (Join-Path $TestDrive 'data')
        $environment.ARM_TENANT_ID | Should -Be 'fixture-tenant'
        $environment.ARM_SUBSCRIPTION_ID | Should -Be 'fixture-subscription'
        $environment.TF_VAR_location | Should -Be 'fixture-region'
        $inputEnv.ARM_SKIP_PROVIDER_REGISTRATION | Should -Be 'false'
        $inputEnv.TF_DATA_DIR | Should -Be 'outside-stage'
    }

    It 'rejects injected <Name> arguments before initialization' -ForEach @(
        @{ Name = 'TF_CLI_ARGS' }, @{ Name = 'TF_CLI_ARGS_init' }, @{ Name = 'TF_CLI_ARGS_providers' }
        @{ Name = 'TF_CLI_ARGS_validate' }, @{ Name = 'TF_CLI_ARGS_plan' }, @{ Name = 'TF_CLI_ARGS_show' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive; Name = $Name } {
            param($Root, $Name)
            { Get-AvmTerraformPolicyEnvironment -StageRoot $Root -Environment @{ $Name = '-chdir=elsewhere' } } |
                Should -Throw "*$Name*"
        }
    }
}

Describe 'Terraform policy configuration inspection and targeted overrides' {
    BeforeEach {
        $script:stage = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:stage
    }

    It 'preserves auth/features and empty proxy inheritance while protecting renamed, default and aliased configurations' {
        $source = @{
            terraform = @{ required_providers = @{ azure = @{ source = 'hashicorp/azurerm' }; azapi = @{ source = 'Azure/azapi' } } }
            provider = @{
                azure = @(@{ alias = 'east'; features = @{}; subscription_id = '${var.subscription_id}'; resource_provider_registrations = 'all'; resource_providers_to_register = @('Microsoft.Test') })
                azapi = @(@{ skip_provider_registration = $false; tenant_id = '${var.tenant_id}' }, @{ alias = 'inherited' })
            }
        } | ConvertTo-Json -Depth 20
        $file = Join-Path $script:stage 'main.tf.json'
        Set-Content -LiteralPath $file -Value $source -Encoding utf8NoBOM
        $result = InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage; Payload = (New-PolicyProviderSchema | ConvertTo-Json -Depth 20) } {
            param($Root, $Payload)
            $configuration = Read-AvmTerraformPolicyConfiguration -Path $Root -StageRoot $Root -ConftestPath 'unused'
            Set-AvmTerraformPolicyProviderOverride -Configuration $configuration -Settings (Get-AvmTerraformPolicyProviderSetting -Payload $Payload)
            Get-Content -LiteralPath (Join-Path $Root 'avm_provider_safety_override.tf.json') -Raw | ConvertFrom-Json -AsHashtable
        }
        (Get-Content -LiteralPath $file -Raw).TrimEnd() | Should -Be $source
        $result.Keys | Should -Be @('provider')
        $result.provider.azure[0].alias | Should -Be 'east'
        $result.provider.azure[0].Count | Should -Be 4
        $result.provider.azure[0].resource_providers_to_register | Should -HaveCount 0
        $result.provider.azure[0].resource_provider_registrations | Should -Be 'none'
        $result.provider.azure[0].skip_provider_registration | Should -BeFalse
        $result.provider.azapi | Should -HaveCount 1
        $result.provider.azapi[0].Count | Should -Be 1
        $result.provider.azapi[0].skip_provider_registration | Should -BeTrue
    }

    It 'creates no provider configuration for an implicit provider or inherited proxy block' {
        Set-Content -LiteralPath (Join-Path $script:stage 'main.tf.json') -Value '{"provider":{"azurerm":{"alias":"inherited"}}}' -Encoding utf8NoBOM
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage } {
            param($Root)
            $configuration = Read-AvmTerraformPolicyConfiguration -Path $Root -StageRoot $Root -ConftestPath 'unused'
            Set-AvmTerraformPolicyProviderOverride -Configuration $configuration -Settings @{}
            @(Get-ChildItem -LiteralPath $Root -Filter '*_override.tf.json').Count | Should -Be 0
        }
    }

    It 'sorts after authored override files without replacing them or losing the configured provider identity' {
        $text = '{"provider":{"azurerm":{"skip_provider_registration":false}}}'
        Set-Content -LiteralPath (Join-Path $script:stage 'main.tf.json') -Value $text -Encoding utf8NoBOM
        $authored = Join-Path $script:stage 'zz_override.tf.json'
        Set-Content -LiteralPath $authored -Value '{"provider":{"azurerm":{}}}' -Encoding utf8NoBOM
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage; Payload = (New-PolicyProviderSchema | ConvertTo-Json -Depth 20) } {
            param($Root, $Payload)
            $configuration = Read-AvmTerraformPolicyConfiguration -Path $Root -StageRoot $Root -ConftestPath 'unused'
            Set-AvmTerraformPolicyProviderOverride -Configuration $configuration -Settings (Get-AvmTerraformPolicyProviderSetting -Payload $Payload)
            Test-Path -LiteralPath (Join-Path $Root 'zz_override.tf.json.avm_override.tf.json') | Should -BeTrue
        }
        (Get-Content -LiteralPath $authored -Raw).Trim() | Should -Be '{"provider":{"azurerm":{}}}'
    }

    It 'rejects conflicting required-provider sources instead of guessing override precedence' {
        Set-Content -LiteralPath (Join-Path $script:stage 'main.tf.json') -Value '{"terraform":{"required_providers":{"azure":{"source":"hashicorp/azurerm"}}}}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:stage 'a_override.tf.json') -Value '{"terraform":{"required_providers":{"azure":{"source":"other/azurerm"}}}}' -Encoding utf8NoBOM
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage } {
            param($Root)
            { Read-AvmTerraformPolicyConfiguration -Path $Root -StageRoot $Root -ConftestPath 'unused' } | Should -Throw '*conflicting source*'
        }
    }

    It 'uses Terraform UTF-8 filename order rather than platform culture or UTF-16 order' {
        $earlier = ([string][char]0xe000) + '_override.tf.json'
        $later = [char]::ConvertFromUtf32(0x10000) + '_override.tf.json'
        foreach ($name in @($earlier, $later)) {
            Set-Content -LiteralPath (Join-Path $script:stage $name) -Value '{"provider":{"azurerm":{"skip_provider_registration":false}}}' -Encoding utf8NoBOM
        }
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage; Later = $later; Payload = (New-PolicyProviderSchema | ConvertTo-Json -Depth 20) } {
            param($Root, $Later, $Payload)
            $configuration = Read-AvmTerraformPolicyConfiguration -Path $Root -StageRoot $Root -ConftestPath 'unused'
            Set-AvmTerraformPolicyProviderOverride -Configuration $configuration -Settings (Get-AvmTerraformPolicyProviderSetting -Payload $Payload)
            Test-Path -LiteralPath (Join-Path $Root "$Later.avm_override.tf.json") | Should -BeTrue
        }
    }

    It 'rejects a linked module without writing through it' {
        $target = Join-Path $TestDrive 'linked-target'
        $null = New-Item -ItemType Directory -Path $target -Force
        $link = Join-Path $script:stage 'linked'
        $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $kind -Path $link -Target $target
        try {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage; LinkPath = $link } {
                param($Root, $LinkPath)
                { Read-AvmTerraformPolicyConfiguration -Path $LinkPath -StageRoot $Root -ConftestPath 'unused' } |
                    Should -Throw '*traverses a link*'
            }
            @(Get-ChildItem -LiteralPath $target -Force) | Should -HaveCount 0
        }
        finally {
            Remove-Item -LiteralPath $link -Force
        }
    }

    It 'rejects an escaped module directory before any parser or file write' {
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage; Outside = $TestDrive } {
            param($Root, $Outside)
            Mock Invoke-AvmProcess { throw 'parser must not run' }
            { Read-AvmTerraformPolicyConfiguration -Path $Outside -StageRoot $Root -ConftestPath 'unused' } | Should -Throw '*outside*'
            Should -Invoke Invoke-AvmProcess -Times 0
        }
    }

    It 'requires every file in the combined HCL parser result: <Case>' -ForEach @(
        @{ Case = 'missing'; Payload = '[]' }
        @{ Case = 'malformed'; Payload = '{' }
        @{ Case = 'wrong path'; Payload = '[{"path":"other.tf","contents":{}}]' }
        @{ Case = 'wrong shape'; Payload = '[{"path":"other.tf","contents":[]}]' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:stage 'main.tf') -Value 'provider "azapi" {}' -Encoding utf8NoBOM
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage; Payload = $Payload } {
            param($Root, $Payload)
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $Payload } }
            { Read-AvmTerraformPolicyConfiguration -Path $Root -StageRoot $Root -ConftestPath 'conftest' } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
        }
    }

    It 'accepts the native single-file combined HCL result without unwrapping its array' {
        $file = Join-Path $script:stage 'main.tf'
        Set-Content -LiteralPath $file -Value 'provider "azurerm" { features {} }' -Encoding utf8NoBOM
        $payload = ConvertTo-Json -InputObject @(@{ path = $file; contents = @{ provider = @{ azurerm = @(@{ features = @(@{}) }) } } }) -Depth 20
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage; Payload = $payload } {
            param($Root, $Payload)
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $Payload } }
            $configuration = Read-AvmTerraformPolicyConfiguration -Path $Root -StageRoot $Root -ConftestPath 'conftest'
            $configuration.Providers | Should -HaveCount 1
            $configuration.Providers[0].Configured | Should -BeTrue
        }
    }

    It 'includes hash-prefixed Terraform files but ignores hidden files and editor backups' {
        foreach ($name in @('#provider.tf.json', 'provider.tf.json', '.hidden.tf.json', '#backup.tf.json#', 'backup.tf.json~', 'uppercase.TF.JSON')) {
            Set-Content -LiteralPath (Join-Path $script:stage $name) -Value '{}' -Encoding utf8NoBOM
        }
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage } {
            param($Root)
            $configuration = Read-AvmTerraformPolicyConfiguration -Path $Root -StageRoot $Root -ConftestPath 'unused'
            @($configuration.Files.Name | Sort-Object) | Should -Be @('#provider.tf.json', 'provider.tf.json')
        }
    }
}

Describe 'Terraform policy initialization ordering and module coverage' {
    BeforeEach {
        $script:stage = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:stage
        $script:payload = New-PolicyProviderSchema | ConvertTo-Json -Depth 20
    }

    It 'rejects <Kind> execution before init or provider schema acquisition' -ForEach @(
        @{ Kind = 'backend'; Text = '{"terraform":{"backend":{"local":{}}}}' }
        @{ Kind = 'cloud'; Text = '{"terraform":{"cloud":{}}}' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:stage 'main.tf.json') -Value $Text -Encoding utf8NoBOM
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage } {
            param($Root)
            Mock Invoke-AvmTerraformInit { throw 'init must not run' }
            Mock Invoke-AvmProcess { throw 'provider must not run' }
            { Initialize-AvmTerraformPolicyStage -WorkingDirectory $Root -StageRoot $Root -TerraformPath 'terraform' -ConftestPath 'conftest' `
                    -EnvVars (Get-AvmTerraformPolicyEnvironment -StageRoot $Root) } | Should -Throw '*backend or cloud*'
            Should -Invoke Invoke-AvmTerraformInit -Times 0
            Should -Invoke Invoke-AvmProcess -Times 0
        }
    }

    It 'rejects <File> before init because its provider configuration cannot be overridden safely' -ForEach @(
        @{ File = 'example.tfquery.hcl' }, @{ File = 'example.tfquery.json' }
        @{ File = 'example.tfmigrate.hcl' }, @{ File = 'example.tfmigrate.json' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:stage $File) -Value '' -Encoding utf8NoBOM
        InModuleScope Avm.Authoring -Parameters @{ FixtureStage = $script:stage } {
            param($FixtureStage)
            Mock Invoke-AvmTerraformInit { throw 'init must not run' }
            { Initialize-AvmTerraformPolicyStage -WorkingDirectory $FixtureStage -StageRoot $FixtureStage -TerraformPath 'terraform' -ConftestPath 'unused' `
                    -EnvVars (Get-AvmTerraformPolicyEnvironment -StageRoot $FixtureStage) } | Should -Throw '*query or state-migration*'
            Should -Invoke Invoke-AvmTerraformInit -Times 0
        }
    }

    It 'protects every reachable local/downloaded module before native validation and never configures providers through plan' {
        $root = Join-Path $script:stage 'module'
        $child = Join-Path $root 'child'
        $download = Join-Path $script:stage 'data' 'modules' 'downloaded'
        $null = New-Item -ItemType Directory -Path $child, $download -Force
        $text = '{"provider":{"azurerm":{"features":{}}}}'
        foreach ($directory in @($root, $child, $download)) {
            Set-Content -LiteralPath (Join-Path $directory 'main.tf.json') -Value $text -Encoding utf8NoBOM
        }
        InModuleScope Avm.Authoring -Parameters @{ FixtureRoot = $root; Stage = $script:stage; FixtureChild = $child; FixtureDownload = $download; SchemaPayload = $script:payload } {
            param($FixtureRoot, $Stage, $FixtureChild, $FixtureDownload, $SchemaPayload)
            $calls = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-AvmTerraformInit {
                $calls.Add('init')
                @{ Modules = @(@{ Key = ''; Dir = '.' }, @{ Key = 'child'; Dir = $FixtureChild }, @{ Key = 'downloaded'; Dir = $FixtureDownload }) } |
                    ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EnvVars.TF_DATA_DIR 'modules' 'modules.json') -Encoding utf8NoBOM
            }
            Mock Invoke-AvmProcess {
                $calls.Add(($ArgumentList -join ' '))
                if ($ArgumentList[0] -eq 'providers') {
                    foreach ($directory in @($FixtureRoot, $FixtureChild, $FixtureDownload)) {
                        Test-Path -LiteralPath (Join-Path $directory 'avm_provider_safety_override.tf.json') | Should -BeFalse
                    }
                    return [pscustomobject]@{ ExitCode = 0; StdOut = $SchemaPayload }
                }
                if ($ArgumentList[0] -eq 'validate') {
                    foreach ($directory in @($FixtureRoot, $FixtureChild, $FixtureDownload)) {
                        Test-Path -LiteralPath (Join-Path $directory 'avm_provider_safety_override.tf.json') | Should -BeTrue
                    }
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '{"valid":true}' }
                }
                throw 'Unexpected Terraform command'
            }
            Initialize-AvmTerraformPolicyStage -WorkingDirectory $FixtureRoot -StageRoot $Stage -TerraformPath 'terraform' -ConftestPath 'unused' `
                -EnvVars (Get-AvmTerraformPolicyEnvironment -StageRoot $Stage)
            $calls.ToArray() | Should -Be @('init', 'providers schema -json', 'validate -json')
        }
    }

    It 'rejects missing, malformed or escaped installed-module coverage: <Case>' -ForEach @(
        @{ Case = 'missing manifest'; Payload = $null; Message = '*did not produce*' }
        @{ Case = 'invalid JSON'; Payload = '{'; Message = '*not valid JSON*' }
        @{ Case = 'wrong root'; Payload = '{"Modules":[{"Key":"","Dir":".."}]}'; Message = '*does not identify*' }
        @{ Case = 'external child'; Payload = '{"Modules":[{"Key":"","Dir":"."},{"Key":"external","Dir":".."}]}'; Message = '*outside*' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:stage 'main.tf.json') -Value '{"module":{"external":{"source":"../outside"}}}' -Encoding utf8NoBOM
        InModuleScope Avm.Authoring -Parameters @{ FixtureStage = $script:stage; ManifestPayload = $Payload; Message = $Message } {
            param($FixtureStage, $ManifestPayload, $Message)
            Mock Invoke-AvmTerraformInit {
                if ($null -ne $ManifestPayload) {
                    $modules = Join-Path $EnvVars.TF_DATA_DIR 'modules'
                    $null = New-Item -ItemType Directory -Path $modules -Force
                    Set-Content -LiteralPath (Join-Path $modules 'modules.json') -Value $ManifestPayload -Encoding utf8NoBOM
                }
            }
            Mock Invoke-AvmProcess { throw 'provider process must not run' }
            { Initialize-AvmTerraformPolicyStage -WorkingDirectory $FixtureStage -StageRoot $FixtureStage -TerraformPath 'terraform' -ConftestPath 'unused' `
                    -EnvVars (Get-AvmTerraformPolicyEnvironment -StageRoot $FixtureStage) } | Should -Throw $Message
            Should -Invoke Invoke-AvmProcess -Times 0
        }
    }

    It 'uses modern implicit defaults when the installed AzureRM schema no longer exposes legacy skip' {
        $schema = New-PolicyProviderSchema -Mode future | ConvertTo-Json -Depth 20
        InModuleScope Avm.Authoring -Parameters @{ FixtureStage = $script:stage; SchemaPayload = $schema } {
            param($FixtureStage, $SchemaPayload)
            Mock Invoke-AvmTerraformInit {}
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'providers') { return [pscustomobject]@{ ExitCode = 0; StdOut = $SchemaPayload } }
                $EnvVars.ARM_RESOURCE_PROVIDER_REGISTRATIONS | Should -Be 'none'
                $EnvVars.ARM_SKIP_PROVIDER_REGISTRATION | Should -Be 'true'
                [pscustomobject]@{ ExitCode = 0; StdOut = '{"valid":true}' }
            }
            Initialize-AvmTerraformPolicyStage -WorkingDirectory $FixtureStage -StageRoot $FixtureStage -TerraformPath 'terraform' -ConftestPath 'unused' `
                -EnvVars (Get-AvmTerraformPolicyEnvironment -StageRoot $FixtureStage)
        }
    }

    It 'fails closed on <Case> validation output' -ForEach @(
        @{ Case = 'invalid JSON'; Payload = '{'; Exit = 0 }
        @{ Case = 'missing validity'; Payload = '{}'; Exit = 0 }
        @{ Case = 'invalid configuration'; Payload = '{"valid":false}'; Exit = 1 }
        @{ Case = 'contradictory exit'; Payload = '{"valid":true}'; Exit = 1 }
        @{ Case = 'string validity'; Payload = '{"valid":"true"}'; Exit = 0 }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:stage; Payload = $Payload; Exit = $Exit } {
            param($Root, $Payload, $Exit)
            Mock Invoke-AvmTerraformInit {}
            Mock Invoke-AvmProcess {
                if ($ArgumentList[0] -eq 'providers') { return [pscustomobject]@{ ExitCode = 0; StdOut = '{"provider_schemas":{}}' } }
                [pscustomobject]@{ ExitCode = $Exit; StdOut = $Payload }
            }
            { Initialize-AvmTerraformPolicyStage -WorkingDirectory $Root -StageRoot $Root -TerraformPath 'terraform' -ConftestPath 'unused' `
                    -EnvVars (Get-AvmTerraformPolicyEnvironment -StageRoot $Root) } |
                Should -Throw -ExceptionType ([AvmConfigurationException])
            Should -Invoke Invoke-AvmProcess -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'plan' }
        }
    }
}
