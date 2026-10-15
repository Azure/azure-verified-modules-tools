#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')).Path
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    function New-TflintClassFixture {
        param([string] $Name, [string] $CanonicalType, [string] $Prefix)

        $root = Join-Path $TestDrive ($Name + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $root -Force
        [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), "terraform {}`n")
        $metadata = [ordered]@{
            '$schema'         = 'https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json'
            moduleDisplayName = 'Class fixture'
            moduleDescription = 'Tests the TFLint rule scope.'
            canonicalType     = $CanonicalType
            owners            = @('module-owner')
        }
        if ($Prefix) {
            $metadata.telemetryIdPrefix = $Prefix
        }
        [System.IO.File]::WriteAllText((Join-Path $root 'metadata.json'),
            (ConvertTo-Json -InputObject $metadata -Depth 5) + "`n")
        return $root
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'TFLint root module class' {
    BeforeEach {
        $script:previousRepoId = [System.Environment]::GetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', 'Process')
        [System.Environment]::SetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', [NullString]::Value, 'Process')
    }

    AfterEach {
        if ($null -eq $script:previousRepoId) {
            [System.Environment]::SetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', [NullString]::Value, 'Process')
        }
        else {
            [System.Environment]::SetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', $script:previousRepoId, 'Process')
        }
    }

    It 'keeps an unknown checkout on the resource default' {
        $root = Join-Path $TestDrive 'repository'
        $null = New-Item -ItemType Directory -Path $root
        InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
        } | Should -BeExactly 'resource'
    }

    It 'keeps a named resource root on the resource default without requiring metadata in lint' {
        $root = Join-Path $TestDrive 'terraform-azurerm-avm-res-mock'
        $null = New-Item -ItemType Directory -Path $root
        InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
        } | Should -BeExactly 'resource'
    }

    It 'uses a named pattern root only after validating its metadata' {
        $root = New-TflintClassFixture -Name 'terraform-azure-avm-ptn-mock' `
            -CanonicalType 'aiml-ai-gateway' -Prefix '46d3xtrf.ptn.a1b2c3d'
        InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
        } | Should -BeExactly 'pattern'
    }

    It 'uses the validated repository ID for a generic utility checkout without telemetry' {
        $root = New-TflintClassFixture -Name 'repository' -CanonicalType 'regions'
        $env:AVM_MANAGED_FILES_REPO_ID = 'avm-utl-regions'
        InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
        } | Should -BeExactly 'utility'
    }

    It 'uses the Git origin for a generically named pattern checkout' -TestCases @(
        @{ GitItemType = 'Directory' }
        @{ GitItemType = 'File' }
    ) {
        param($GitItemType)
        $root = New-TflintClassFixture -Name 'worktree' `
            -CanonicalType 'aiml-ai-gateway' -Prefix '46d3xtrf.ptn.a1b2c3d'
        $null = New-Item -ItemType $GitItemType -Path (Join-Path $root '.git')
        InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = 'https://github.com/Azure/terraform-azure-avm-ptn-aiml-ai-gateway.git'
                    StdErr = ''
                }
            }
            Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $WorkingDirectory -eq $Root -and
                ($ArgumentList -join ' ') -eq 'config --get remote.origin.url'
            }
        } | Should -BeExactly 'pattern'
    }

    It 'uses an SSH Git origin for a utility checkout' {
        $root = New-TflintClassFixture -Name 'worktree' -CanonicalType 'regions'
        $null = New-Item -ItemType Directory -Path (Join-Path $root '.git')
        InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0; StdOut = 'git@github.com:Azure/terraform-azurerm-avm-utl-regions.git'; StdErr = ''
                }
            }
            Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
        } | Should -BeExactly 'utility'
    }

    It 'does not trust a telemetry prefix alone to exempt an unknown checkout' {
        $root = New-TflintClassFixture -Name 'repository' `
            -CanonicalType 'aiml-ai-gateway' -Prefix '46d3xtrf.ptn.a1b2c3d'
        InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
            param($Root)
            Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
        } | Should -BeExactly 'resource'
    }

    It 'rejects a resource Git origin even when the explicit identity and metadata say pattern' {
        $root = New-TflintClassFixture -Name 'repository' `
            -CanonicalType 'aiml-ai-gateway' -Prefix '46d3xtrf.ptn.a1b2c3d'
        $null = New-Item -ItemType Directory -Path (Join-Path $root '.git')
        $env:AVM_MANAGED_FILES_REPO_ID = 'avm-ptn-mock'
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                Mock Invoke-AvmProcess {
                    [pscustomobject]@{
                        ExitCode = 0; StdOut = 'https://github.com/Azure/terraform-azure-avm-res-mock'; StdErr = ''
                    }
                }
                Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
            }
        } | Should -Throw '*disagree on module class*'
    }

    It 'allows a named pattern checkout with no origin but fails a Git configuration error' -TestCases @(
        @{ ExitCode = 1; ShouldFail = $false }
        @{ ExitCode = 128; ShouldFail = $true }
    ) {
        param($ExitCode, $ShouldFail)
        $root = New-TflintClassFixture -Name 'terraform-azure-avm-ptn-mock' `
            -CanonicalType 'aiml-ai-gateway' -Prefix '46d3xtrf.ptn.a1b2c3d'
        $null = New-Item -ItemType Directory -Path (Join-Path $root '.git')
        $run = {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root; Code = $ExitCode } {
                param($Root, $Code)
                $script:tflintGitExit = $Code
                Mock Invoke-AvmProcess {
                    [pscustomobject]@{ ExitCode = $script:tflintGitExit; StdOut = ''; StdErr = 'No identity returned.' }
                }
                Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
            }
        }
        if ($ShouldFail) {
            $run | Should -Throw '*Cannot read the Terraform repository identity*'
        }
        else {
            & $run | Should -BeExactly 'pattern'
        }
    }

    It 'rejects conflicting repository identities instead of exempting a resource root' {
        $root = Join-Path $TestDrive 'terraform-azurerm-avm-res-conflicting'
        $null = New-Item -ItemType Directory -Path $root
        $env:AVM_MANAGED_FILES_REPO_ID = 'avm-ptn-mock'
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
            }
        } | Should -Throw '*disagree on module class*'
    }

    It 'rejects an invalid explicit repository ID rather than trusting its metadata' {
        $root = New-TflintClassFixture -Name 'repository' `
            -CanonicalType 'aiml-ai-gateway' -Prefix '46d3xtrf.ptn.a1b2c3d'
        $env:AVM_MANAGED_FILES_REPO_ID = 'not-a-module'
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
            }
        } | Should -Throw '*must identify an AVM Terraform*'
    }

    It 'rejects a non-resource root without valid metadata' {
        $root = Join-Path $TestDrive 'terraform-azure-avm-ptn-missing'
        $null = New-Item -ItemType Directory -Path $root
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
            }
        } | Should -Throw '*Cannot apply TFLint module_class*'
    }

    It 'rejects a pattern identity with resource metadata' {
        $root = New-TflintClassFixture -Name 'terraform-azure-avm-ptn-mock' `
            -CanonicalType 'Microsoft.Storage/storageAccounts' -Prefix '46d3xtrf.res.a1b2c3d'
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                Get-AvmTflintRootModuleClass -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
            }
        } | Should -Throw '*Cannot apply TFLint module_class*'
    }
}

Describe 'TFLint staged root class configuration' {
    BeforeEach {
        $script:previousHome = [System.Environment]::GetEnvironmentVariable('AVM_HOME', 'Process')
        $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        $script:root = Join-Path $TestDrive 'class-root'
        $script:base = Join-Path $TestDrive 'class-config'
        $null = New-Item -ItemType Directory -Path $script:root, $script:base -Force
        @'
rule "avm_output_resource_id_required" {
  enabled = true
}
'@ | Set-Content -LiteralPath (Join-Path $script:base 'avm.tflint.hcl') -Encoding utf8NoBOM
    }

    AfterEach {
        if ($null -eq $script:previousHome) {
            [System.Environment]::SetEnvironmentVariable('AVM_HOME', [NullString]::Value, 'Process')
        }
        else {
            [System.Environment]::SetEnvironmentVariable('AVM_HOME', $script:previousHome, 'Process')
        }
    }

    It 'reuses the original config for a resource root with no override' {
        $result = InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Base = $script:base } {
            param($Root, $Base)
            New-AvmTflintConfigSet -Root $Root -BaseConfigDir $Base `
                -Scopes @([pscustomobject]@{ RelPath = '.'; Config = (Join-Path $Base 'avm.tflint.hcl') })
        }
        $result.ConfigDir | Should -BeExactly $script:base
        $result.StageDir | Should -BeNullOrEmpty
    }

    It 'generates an isolated root class config for <Class> without warning on its own setting' -TestCases @(
        @{ Class = 'pattern' }
        @{ Class = 'utility' }
    ) {
        param($Class)
        $result = InModuleScope Avm.Authoring -Parameters @{
            Root = $script:root; Base = $script:base; ModuleClass = $Class
        } {
            param($Root, $Base, $ModuleClass)
            New-AvmTflintConfigSet -Root $Root -BaseConfigDir $Base `
                -Scopes @([pscustomobject]@{ RelPath = '.'; Config = (Join-Path $Base 'avm.tflint.hcl') }) `
                -RootModuleClass $ModuleClass
        }
        $result.ConfigDir | Should -Not -BeExactly $script:base
        $result.OverridePaths | Should -BeNullOrEmpty
        $config = Get-Content -LiteralPath (Join-Path $result.ConfigDir 'avm.tflint.hcl') -Raw
        $config | Should -Match ('module_class\s*=\s*"{0}"' -f $Class)
        $config | Should -Match 'enabled\s*=\s*true'
    }

    It 'does not copy a root class into child or example profiles' {
        foreach ($name in @('avm.tflint_module.hcl', 'avm.tflint_example.hcl')) {
            Copy-Item -LiteralPath (Join-Path $script:base 'avm.tflint.hcl') -Destination (Join-Path $script:base $name)
        }
        $result = InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Base = $script:base } {
            param($Root, $Base)
            New-AvmTflintConfigSet -Root $Root -BaseConfigDir $Base -RootModuleClass pattern -Scopes @(
                [pscustomobject]@{ RelPath = '.'; Config = (Join-Path $Base 'avm.tflint.hcl') }
                [pscustomobject]@{ RelPath = 'modules/child'; Config = (Join-Path $Base 'avm.tflint_module.hcl') }
                [pscustomobject]@{ RelPath = 'examples/default'; Config = (Join-Path $Base 'avm.tflint_example.hcl') })
        }
        foreach ($name in @('avm.tflint_module.hcl', 'avm.tflint_example.hcl')) {
            Get-Content -LiteralPath (Join-Path $result.ConfigDir $name) -Raw | Should -Not -Match 'module_class'
        }
    }

    It 'adds the required enabled field only when the base has no resource-ID rule' -TestCases @(
        @{ ExistingRule = $false; ExpectedEnabled = 'true' }
        @{ ExistingRule = $true; ExpectedEnabled = 'false' }
    ) {
        param($ExistingRule, $ExpectedEnabled)
        $baseText = if ($ExistingRule) {
            "rule `"avm_output_resource_id_required`" {`n  enabled = false`n}`n"
        }
        else {
            "plugin `"avm`" {`n  enabled = true`n  version = `"1.2.0`"`n}`n"
        }
        Set-Content -LiteralPath (Join-Path $script:base 'avm.tflint.hcl') -Value $baseText -Encoding utf8NoBOM
        $result = InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Base = $script:base } {
            param($Root, $Base)
            New-AvmTflintConfigSet -Root $Root -BaseConfigDir $Base -RootModuleClass pattern `
                -Scopes @([pscustomobject]@{ RelPath = '.'; Config = (Join-Path $Base 'avm.tflint.hcl') })
        }
        $config = Get-Content -LiteralPath (Join-Path $result.ConfigDir 'avm.tflint.hcl') -Raw
        $config | Should -Match (
            '(?s)rule "avm_output_resource_id_required"\s*\{[^}]*enabled\s*=\s*' + $ExpectedEnabled)
        $config | Should -Match 'module_class\s*=\s*"pattern"'
    }

    It 'rejects an authored class that contradicts the repository identity' {
        @'
rule "avm_output_resource_id_required" {
  module_class = "utility"
}
'@ | Set-Content -LiteralPath (Join-Path $script:root 'avm.tflint.override.hcl') -Encoding utf8NoBOM
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Base = $script:base } {
                param($Root, $Base)
                New-AvmTflintConfigSet -Root $Root -BaseConfigDir $Base -RootModuleClass pattern `
                    -Scopes @([pscustomobject]@{ RelPath = '.'; Config = (Join-Path $Base 'avm.tflint.hcl') })
            }
        } | Should -Throw '*does not match repository class*'
    }

    It 'rejects an exempting class in a custom base config for a resource root' {
        @'
rule "avm_output_resource_id_required" {
  enabled = true
  module_class = "pattern"
}
'@ | Set-Content -LiteralPath (Join-Path $script:base 'avm.tflint.hcl') -Encoding utf8NoBOM
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Base = $script:base } {
                param($Root, $Base)
                New-AvmTflintConfigSet -Root $Root -BaseConfigDir $Base `
                    -Scopes @([pscustomobject]@{ RelPath = '.'; Config = (Join-Path $Base 'avm.tflint.hcl') })
            }
        } | Should -Throw '*does not match repository class*'
    }

    It 'rejects a plugin downgrade in the effective root configuration' -TestCases @(
        @{ Version = '1.0.0' }
        @{ Version = '1.1.0' }
    ) {
        param($Version)
        "plugin `"avm`" {`n  version = `"$Version`"`n}`n" |
            Set-Content -LiteralPath (Join-Path $script:root 'avm.tflint.override.hcl') -Encoding utf8NoBOM
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Base = $script:base } {
                param($Root, $Base)
                New-AvmTflintConfigSet -Root $Root -BaseConfigDir $Base -RootModuleClass pattern `
                    -Scopes @([pscustomobject]@{ RelPath = '.'; Config = (Join-Path $Base 'avm.tflint.hcl') })
            }
        } | Should -Throw '*requires AVM ruleset 1.2.0 or later*'
    }

    It 'applies an authored disabling override after the generated pattern class' {
        @'
rule "avm_output_resource_id_required" {
  enabled = false
}
'@ | Set-Content -LiteralPath (Join-Path $script:root 'avm.tflint.override.hcl') -Encoding utf8NoBOM
        $result = InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Base = $script:base } {
            param($Root, $Base)
            New-AvmTflintConfigSet -Root $Root -BaseConfigDir $Base `
                -Scopes @([pscustomobject]@{ RelPath = '.'; Config = (Join-Path $Base 'avm.tflint.hcl') }) `
                -RootModuleClass pattern
        }
        $config = Get-Content -LiteralPath (Join-Path $result.ConfigDir 'avm.tflint.hcl') -Raw
        $config | Should -Match 'module_class\s*=\s*"pattern"'
        $config | Should -Match 'enabled\s*=\s*false'
        @($result.OverridePaths) | Should -Be @((Join-Path $script:root 'avm.tflint.override.hcl'))
        $warnings = InModuleScope Avm.Authoring -Parameters @{ Root = $script:root; Paths = $result.OverridePaths } {
            param($Root, $Paths)
            Get-AvmTflintOverrideWarning -Root $Root -OverridePaths @($Paths)
        }
        @($warnings).Count | Should -Be 1
        $warnings[0].Rule | Should -BeExactly 'avm_output_resource_id_required'
    }
}
