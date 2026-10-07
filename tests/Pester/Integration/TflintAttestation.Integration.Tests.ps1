#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: TFLint AVM plugin attestation' -Tag 'Integration' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $script:moduleManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
        $script:configPath = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Resources' 'tflint' 'avm.tflint.hcl'
        $pinsPath = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Resources' 'avm.pins.jsonc'
        $pins = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json
        $script:tflintVersion = [string]($pins.tools | Where-Object name -eq 'tflint' | Select-Object -First 1).version
        $script:avmRulesetVersion = [string]$pins.tflintPlugins.avm
        $script:terraformRulesetVersion = [string]$pins.tflintPlugins.terraform
        $script:originalAvmHome = $env:AVM_HOME
        $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        Import-Module $script:moduleManifest -Force
        if ($env:AVM_OFFLINE -ne '1') {
            Install-AvmTool -Name tflint -InformationAction Continue -ErrorAction Stop -SkipModuleVersionCheck
            Install-AvmTool -Name terraform -InformationAction Continue -ErrorAction Stop -SkipModuleVersionCheck
        }
    }

    BeforeEach {
        $script:originalRepoId = [System.Environment]::GetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', 'Process')
        [System.Environment]::SetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', [NullString]::Value, 'Process')
    }

    AfterEach {
        if ($null -eq $script:originalRepoId) {
            [System.Environment]::SetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', [NullString]::Value, 'Process')
        }
        else {
            [System.Environment]::SetEnvironmentVariable('AVM_MANAGED_FILES_REPO_ID', $script:originalRepoId, 'Process')
        }
    }

    AfterAll {
        if ($null -eq $script:originalAvmHome) {
            Remove-Item Env:\AVM_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_HOME = $script:originalAvmHome
        }
        Remove-Module -Name 'Avm.Authoring' -Force -ErrorAction SilentlyContinue
    }

    It 'installs and executes the pinned AVM ruleset with artifact attestation' -Skip:((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1')) {
        $requiredRoot = Join-Path $TestDrive 'required-interfaces'
        New-Item -ItemType Directory -Path $requiredRoot -Force | Out-Null
@'
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0.0, < 3.0.0"
    }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $requiredRoot 'terraform.tf') -Encoding utf8NoBOM
        @'
resource "azapi_resource" "example" {
  type = "Microsoft.Example/widgets@2024-01-01"
}
'@ | Set-Content -LiteralPath (Join-Path $requiredRoot 'main.tf') -Encoding utf8NoBOM
        @'
output "resource_id" {
  value = azapi_resource.example.id
}
'@ | Set-Content -LiteralPath (Join-Path $requiredRoot 'outputs.tf') -Encoding utf8NoBOM
        @'
variable "ignore_body_changes" {
  type        = map(list(string))
  default     = {}
  description = "An intentionally invalid ignore-body interface used to prove released AVM interface enforcement."
  nullable    = false
}
'@ | Set-Content -LiteralPath (Join-Path $requiredRoot 'variables.tf') -Encoding utf8NoBOM

        $canonicalRoot = Join-Path $script:repoRoot 'tests' 'fixtures' 'modules' 'terraform-azure-avm-res-mock'
        $deprecatedRoot = Join-Path $TestDrive 'deprecated-interface'
        Copy-Item -LiteralPath $canonicalRoot -Destination $deprecatedRoot -Recurse -Force
        $badTagsRoot = Join-Path $TestDrive 'missing-resource-tags'
        Copy-Item -LiteralPath $canonicalRoot -Destination $badTagsRoot -Recurse -Force
        $badTagsPath = Join-Path $badTagsRoot 'main.tf'
        $badTagsContent = Get-Content -LiteralPath $badTagsPath -Raw
        $tagAttribute = '(?m)^  tags[ \t]*=[ \t]*var\.tags[ \t]*\r?\n'
        [regex]::Matches($badTagsContent, $tagAttribute).Count | Should -Be 2
        $badTagsContent = [regex]::Replace($badTagsContent, $tagAttribute, '')
        Set-Content -LiteralPath $badTagsPath -Value $badTagsContent -Encoding utf8NoBOM -NoNewline
        @'

variable "lock" {
  type = object({
    kind = string
    name = optional(string, null)
  })
  default     = null
  description = "The legacy resource lock interface retained for the v0.19 migration window."
}

output "deprecated_lock" {
  value = var.lock
}
'@ | Add-Content -LiteralPath (Join-Path $deprecatedRoot 'variables.tf') -Encoding utf8NoBOM
        '# tflint-ignore: terraform_unused_declarations' |
            Set-Content -LiteralPath (Join-Path $deprecatedRoot 'manual-ignore.tf') -Encoding utf8NoBOM

        $run = InModuleScope 'Avm.Authoring' -Parameters @{
            BadTags    = $badTagsRoot
            Canonical  = $canonicalRoot
            Config     = $script:configPath
            Deprecated = $deprecatedRoot
            Required   = $requiredRoot
        } {
            param($BadTags, $Canonical, $Config, $Deprecated, $Required)

            $tool = Resolve-AvmTool -Name 'tflint'
            $init = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--init', '--no-color', '--config', $Config) `
                -WorkingDirectory $Required `
                -IgnoreExitCode
            $version = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--config', $Config, '--version') `
                -WorkingDirectory $Required `
                -IgnoreExitCode
            $requiredLint = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @(
                    '--config', $Config,
                    '--format=json',
                    '--minimum-failure-severity=warning',
                    '--only=avm_interface_ignore_body_changes'
                ) `
                -WorkingDirectory $Required `
                -IgnoreExitCode
            $canonicalLint = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--config', $Config, '--format=json', '--minimum-failure-severity=warning') `
                -WorkingDirectory $Canonical `
                -IgnoreExitCode
            $badTagsLint = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @(
                    '--config', $Config, '--format=json', '--minimum-failure-severity=warning',
                    '--only=avm_azapi_resource_tags_required'
                ) `
                -WorkingDirectory $BadTags `
                -IgnoreExitCode
            $deprecatedLint = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--config', $Config, '--format=json', '--minimum-failure-severity=warning') `
                -WorkingDirectory $Deprecated `
                -IgnoreExitCode
            $savedActions = $env:GITHUB_ACTIONS
            try {
                $env:GITHUB_ACTIONS = ''
                $deprecatedWarnings = @()
                $deprecatedResult = Invoke-AvmTerraformLint `
                    -Context ([pscustomobject]@{
                        Kind = 'terraform-module-repo'
                        Root = $Deprecated
                        Ecosystem = 'terraform'
                        Source = 'integration'
                    }) `
                    -ThrottleLimit 1 `
                    -WarningVariable deprecatedWarnings
                $deprecatedSummary = @(
                    Write-AvmResult -Result $deprecatedResult -Verb 'lint' 6>&1 |
                        ForEach-Object { [string]$_.MessageData }
                )

                $canonicalWarnings = @()
                $canonicalResult = Invoke-AvmTerraformLint `
                    -Context ([pscustomobject]@{
                        Kind = 'terraform-module-repo'
                        Root = $Canonical
                        Ecosystem = 'terraform'
                        Source = 'integration'
                    }) `
                    -ThrottleLimit 1 `
                    -WarningVariable canonicalWarnings
            }
            finally {
                $env:GITHUB_ACTIONS = $savedActions
            }

            [pscustomobject]@{
                BadTagsLint         = $badTagsLint
                CanonicalLint       = $canonicalLint
                CanonicalResult     = $canonicalResult
                CanonicalWarnings   = @($canonicalWarnings | ForEach-Object { [string]$_ })
                DeprecatedLint      = $deprecatedLint
                DeprecatedResult    = $deprecatedResult
                DeprecatedSummary   = $deprecatedSummary
                DeprecatedWarnings  = @($deprecatedWarnings | ForEach-Object { [string]$_ })
                Init                = $init
                RequiredLint        = $requiredLint
                ToolVersion         = $tool.Version
                Version             = $version
            }
        }

        $run.ToolVersion | Should -Be $script:tflintVersion
        $run.Init.ExitCode | Should -Be 0 -Because $run.Init.StdErr
        $run.Version.ExitCode | Should -Be 0 -Because $run.Version.StdErr
        $versionOutput = "$($run.Version.StdOut)`n$($run.Version.StdErr)"
        $versionOutput | Should -Match ('TFLint version {0}' -f [regex]::Escape($script:tflintVersion))
        $versionOutput | Should -Match ('ruleset\.avm \({0}\)' -f [regex]::Escape($script:avmRulesetVersion))
        $versionOutput | Should -Match ('ruleset\.terraform \({0}\)' -f [regex]::Escape($script:terraformRulesetVersion))

        $run.RequiredLint.ExitCode | Should -Be 0 -Because $run.RequiredLint.StdErr
        $requiredPayload = $run.RequiredLint.StdOut | ConvertFrom-Json
        $requiredIssue = @($requiredPayload.issues) |
            Where-Object { $_.rule.name -eq 'avm_interface_ignore_body_changes' }
        $requiredIssue | Should -Not -BeNullOrEmpty
        $requiredIssue.rule.severity | Should -Be 'info'

        $run.CanonicalLint.ExitCode | Should -Be 0 -Because "$($run.CanonicalLint.StdErr)`n$($run.CanonicalLint.StdOut)"
        $run.BadTagsLint.ExitCode | Should -Be 2 -Because "$($run.BadTagsLint.StdErr)`n$($run.BadTagsLint.StdOut)"
        $tagIssues = @(($run.BadTagsLint.StdOut | ConvertFrom-Json).issues |
                Where-Object { $_.rule.name -eq 'avm_azapi_resource_tags_required' })
        $tagIssues | Should -HaveCount 2
        @($tagIssues | Where-Object { $_.range.filename -eq 'main.telemetry.tf' }) | Should -HaveCount 0
        $run.DeprecatedLint.ExitCode | Should -Be 0 -Because "$($run.DeprecatedLint.StdErr)`n$($run.DeprecatedLint.StdOut)"
        $run.DeprecatedResult.Status | Should -Be 'pass'
        $deprecatedIssue = $run.DeprecatedResult.Issues |
            Where-Object Code -eq 'avm_interface_lock_deprecated'
        $deprecatedIssue | Should -Not -BeNullOrEmpty
        $deprecatedIssue.Severity | Should -Be 'notice'
        $deprecatedIssue.File | Should -Be 'variables.tf'
        $deprecatedIssue.Message | Should -Match 'v0\.19\.0 migration window'
        @($run.DeprecatedWarnings).Count | Should -Be 3
        @($run.DeprecatedWarnings | Where-Object {
                $_ -match '\[avm_interface_lock_deprecated\].*v0\.19\.0 migration window'
            }).Count | Should -Be 1
        @($run.DeprecatedWarnings | Where-Object {
                $_ -ceq "TFLint override disables rule 'avm_output_resource_id_required'."
            }).Count | Should -Be 1
        @($run.DeprecatedWarnings | Where-Object {
                $_ -match 'TFLint inline ignore comment found for rule\(s\): terraform_unused_declarations\. \(manual-ignore\.tf, line 1\)'
            }).Count | Should -Be 1
        ($run.DeprecatedWarnings -join "`n") | Should -Not -Match 'main\.telemetry\.tf'
        ($run.DeprecatedSummary -join "`n") | Should -Not -Match 'avm_interface_lock_deprecated|v0\.19\.0 migration window'

        $run.CanonicalResult.Status | Should -Be 'pass'
        @($run.CanonicalWarnings).Count | Should -Be 1
        @($run.CanonicalWarnings | Where-Object {
                $_ -ceq "TFLint override disables rule 'avm_output_resource_id_required'."
            }).Count | Should -Be 1
        ($run.CanonicalWarnings -join "`n") | Should -Not -Match 'main\.telemetry\.tf'
        @($run.CanonicalResult.Issues | Where-Object Code -like 'avm_interface_*_deprecated') |
            Should -BeNullOrEmpty
    }

    It 'applies the released resource-ID rule to <Case>' -TestCases @(
        @{ Case = 'resource without output'; Leaf = 'terraform-azure-avm-res-class'; MetadataClass = 'resource'; ExpectedClass = 'resource'; RepoId = ''; Origin = ''; HasOutput = $false; ExpectedIssues = 1 }
        @{ Case = 'resource with output'; Leaf = 'terraform-azure-avm-res-class'; MetadataClass = 'resource'; ExpectedClass = 'resource'; RepoId = ''; Origin = ''; HasOutput = $true; ExpectedIssues = 0 }
        @{ Case = 'named pattern'; Leaf = 'terraform-azure-avm-ptn-class'; MetadataClass = 'pattern'; ExpectedClass = 'pattern'; RepoId = ''; Origin = ''; HasOutput = $false; ExpectedIssues = 0 }
        @{ Case = 'extracted pattern candidate'; Leaf = 'candidate'; MetadataClass = 'pattern'; ExpectedClass = 'pattern'; RepoId = 'avm-ptn-class'; Origin = ''; HasOutput = $false; ExpectedIssues = 0 }
        @{ Case = 'utility Git checkout'; Leaf = 'checkout'; MetadataClass = 'utility'; ExpectedClass = 'utility'; RepoId = ''; Origin = 'https://github.com/Azure/terraform-azurerm-avm-utl-regions.git'; HasOutput = $false; ExpectedIssues = 0 }
        @{ Case = 'unknown checkout with pattern metadata'; Leaf = 'unknown'; MetadataClass = 'pattern'; ExpectedClass = 'resource'; RepoId = ''; Origin = ''; HasOutput = $false; ExpectedIssues = 1 }
    ) -Skip:($env:AVM_OFFLINE -eq '1') {
        param($Case, $Leaf, $MetadataClass, $ExpectedClass, $RepoId, $Origin, $HasOutput, $ExpectedIssues)

        $root = Join-Path $TestDrive ($Leaf + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $child = Join-Path $root 'modules' 'child'
        $example = Join-Path $root 'examples' 'default'
        foreach ($directory in @($root, $child, $example)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
            'terraform { required_version = ">= 1.9.0" }' |
                Set-Content -LiteralPath (Join-Path $directory 'main.tf') -Encoding utf8NoBOM
        }
        $canonicalTypes = @{
            resource = 'Microsoft.Resources/resourceGroups'
            pattern = 'fixture-pattern'
            utility = 'regions'
        }
        $kinds = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }
        $metadata = [ordered]@{
            '$schema' = 'https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json'
            moduleDisplayName = 'TFLint class fixture'
            moduleDescription = 'Exercises the released resource-only output rule.'
            canonicalType = $canonicalTypes[$MetadataClass]
            owners = @('module-owner')
        }
        if ($MetadataClass -ne 'utility') {
            $metadata.telemetryIdPrefix = '46d3xtrf.' + $kinds[$MetadataClass] + '.a1b2c3d'
        }
        ConvertTo-Json -InputObject $metadata -Depth 5 |
            Set-Content -LiteralPath (Join-Path $root 'metadata.json') -Encoding utf8NoBOM
        if ($HasOutput) {
            'output "resource_id" { value = "fixture-resource-id" }' |
                Set-Content -LiteralPath (Join-Path $root 'outputs.tf') -Encoding utf8NoBOM
        }
        if ($RepoId) {
            $env:AVM_MANAGED_FILES_REPO_ID = $RepoId
        }

        $result = InModuleScope Avm.Authoring -Parameters @{
            Root = $root; Origin = $Origin; Base = (Split-Path -Parent $script:configPath)
        } {
            param($Root, $Origin, $Base)
            if ($Origin) {
                $git = Get-Command -Name git -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $null = Invoke-AvmProcess -FilePath $git.Source -WorkingDirectory $Root -ArgumentList @('init', '--quiet')
                $null = Invoke-AvmProcess -FilePath $git.Source -WorkingDirectory $Root `
                    -ArgumentList @('config', 'remote.origin.url', $Origin)
            }
            $moduleClass = Get-AvmTflintRootModuleClass `
                -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
            $sourceScopes = @(Get-AvmTflintScope -Root $Root -ConfigDir $Base)
            $configSet = New-AvmTflintConfigSet -Root $Root -BaseConfigDir $Base `
                -Scopes $sourceScopes -RootModuleClass $moduleClass
            $runs = [System.Collections.Generic.List[object]]::new()
            try {
                $tool = Resolve-AvmTool -Name tflint
                $initialization = Invoke-AvmProcess -FilePath $tool.Path -WorkingDirectory $Root `
                    -ArgumentList @('--init', '--no-color', '--config', (Join-Path $configSet.ConfigDir 'avm.tflint.hcl')) -IgnoreExitCode
                if ($initialization.ExitCode -ne 0) {
                    throw "TFLint plugin initialization failed: $($initialization.StdErr)`n$($initialization.StdOut)"
                }
                foreach ($scope in Get-AvmTflintScope -Root $Root -ConfigDir $configSet.ConfigDir) {
                    $arguments = @('--config', $scope.Config, '--format=json', '--no-color')
                    if ($scope.RelPath -eq '.') {
                        $arguments += '--only=avm_output_resource_id_required'
                    }
                    $run = Invoke-AvmProcess -FilePath $tool.Path -WorkingDirectory $scope.Dir `
                        -ArgumentList $arguments -IgnoreExitCode
                    $runs.Add([pscustomobject]@{ Scope = $scope.RelPath; Run = $run })
                }
            }
            finally {
                if ($configSet.StageDir) {
                    Remove-Item -LiteralPath $configSet.StageDir -Recurse -Force -ErrorAction Stop
                }
            }
            [pscustomobject]@{ ModuleClass = $moduleClass; Runs = $runs.ToArray() }
        }

        $result.ModuleClass | Should -BeExactly $ExpectedClass
        $result.Runs | Should -HaveCount 3
        foreach ($entry in $result.Runs) {
            $entry.Run.ExitCode | Should -BeIn @(0, 2) -Because "$($entry.Scope): $($entry.Run.StdErr)`n$($entry.Run.StdOut)"
            $payload = $entry.Run.StdOut | ConvertFrom-Json
            @($payload.errors) | Should -HaveCount 0
            $issues = @($payload.issues | Where-Object { $_.rule.name -eq 'avm_output_resource_id_required' })
            $count = if ($entry.Scope -eq '.') { $ExpectedIssues } else { 0 }
            $issues | Should -HaveCount $count -Because "$Case in scope $($entry.Scope)"
        }
    }

    It 'preserves utility override behavior for <Utility>' -ForEach @(
        @{
            Utility = 'Naming'
            Configs = @(
                @{
                    Name = 'avm.tflint.hcl'
                    Rules = @('avm_output_resource_id_required', 'avm_provider_modtm_version_constraint')
                    Disabled = @('avm_output_resource_id_required', 'avm_provider_modtm_version_constraint')
                }
            )
        }
        @{
            Utility = 'IP-addresses'
            Configs = @(
                @{ Name = 'avm.tflint.hcl'; Rules = @('required_output_rmfr7'); Disabled = @('avm_output_resource_id_required') }
                @{ Name = 'avm.tflint_example.hcl'; Rules = @('terraform_required_version'); Disabled = @('terraform_required_version') }
            )
        }
        @{
            Utility = 'Regions'
            Configs = @(
                @{ Name = 'avm.tflint.hcl'; Rules = @('required_output_rmfr7'); Disabled = @('avm_output_resource_id_required') }
                @{ Name = 'avm.tflint_module.hcl'; Rules = @('required_output_rmfr7'); Disabled = @('avm_output_resource_id_required') }
                @{ Name = 'avm.tflint_example.hcl'; Rules = @('terraform_output_separate'); Disabled = @() }
            )
        }
    ) -Skip:((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1')) {
        Install-AvmTool -Name tflint -ErrorAction Stop -SkipModuleVersionCheck
        $root = Join-Path $TestDrive $Utility
        $directories = @($root, (Join-Path $root 'modules' 'child'), (Join-Path $root 'examples' 'default'))
        foreach ($directory in $directories) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            @'
locals {
  value = "local-only"
}
output "value" {
  value       = local.value
  description = "A local utility value."
}
'@ | Set-Content -LiteralPath (Join-Path $directory 'main.tf') -Encoding utf8NoBOM
        }
        $overridePaths = foreach ($configuration in $Configs) {
            $path = Join-Path $root ($configuration.Name -replace '\.hcl$', '.override.hcl')
            $text = ($configuration.Rules | ForEach-Object { "rule `"$_`" {`n  enabled = false`n}`n" }) -join "`n"
            [System.IO.File]::WriteAllText($path, $text)
            $path
        }
        $before = Get-FileHash -LiteralPath $overridePaths
        $runs = InModuleScope 'Avm.Authoring' -Parameters @{
            Root = $root
            Configs = $Configs
            PluginDir = (Join-Path $TestDrive 'utility-plugins')
        } {
            param($Root, $Configs, $PluginDir)
            $tool = Resolve-AvmTool -Name tflint
            $configDir = Resolve-AvmTflintConfigDir
            $scopes = @(Get-AvmTflintScope -Root $Root -ConfigDir $configDir)
            $set = New-AvmTflintConfigSet -Root $Root -BaseConfigDir $configDir -Scopes $scopes
            try {
                $init = Invoke-AvmProcess -FilePath $tool.Path `
                    -ArgumentList @('--init', '--config', (Join-Path $configDir 'avm.tflint.hcl')) `
                    -WorkingDirectory $Root -EnvVars @{ TFLINT_PLUGIN_DIR = $PluginDir } -IgnoreExitCode
                $init.ExitCode | Should -Be 0 -Because $init.StdErr
                foreach ($configuration in $Configs) {
                    $scope = $scopes | Where-Object { [System.IO.Path]::GetFileName($_.Config) -eq $configuration.Name }
                    $baseline = Invoke-AvmProcess -FilePath $tool.Path `
                        -ArgumentList @('--config', $scope.Config, '--format=json') `
                        -WorkingDirectory $scope.Dir -EnvVars @{ TFLINT_PLUGIN_DIR = $PluginDir } -IgnoreExitCode
                    $candidate = Invoke-AvmProcess -FilePath $tool.Path `
                        -ArgumentList @('--config', (Join-Path $set.ConfigDir $configuration.Name), '--format=json') `
                        -WorkingDirectory $scope.Dir -EnvVars @{ TFLINT_PLUGIN_DIR = $PluginDir } -IgnoreExitCode
                    [pscustomobject]@{
                        Name = $configuration.Name
                        Disabled = $configuration.Disabled
                        Baseline = $baseline
                        Candidate = $candidate
                    }
                }
            }
            finally {
                Remove-Item -LiteralPath $set.StageDir -Recurse -Force
            }
        }

        @($runs).Count | Should -Be $Configs.Count
        foreach ($run in $runs) {
            $run.Baseline.ExitCode | Should -BeIn @(0, 2) -Because $run.Baseline.StdErr
            $run.Candidate.ExitCode | Should -BeIn @(0, 2) -Because $run.Candidate.StdErr
            $baselinePayload = $run.Baseline.StdOut | ConvertFrom-Json
            $candidatePayload = $run.Candidate.StdOut | ConvertFrom-Json
            $baselinePayload.errors | Should -BeNullOrEmpty
            $candidatePayload.errors | Should -BeNullOrEmpty
            if ($run.Name -ceq 'avm.tflint.hcl' -and $run.Disabled -contains 'avm_output_resource_id_required') {
                @($baselinePayload.issues | Where-Object { $_.rule.name -eq 'avm_output_resource_id_required' }).Count | Should -Be 1
            }
            @($candidatePayload.issues | Where-Object { $_.rule.name -in $run.Disabled }) | Should -BeNullOrEmpty
            $expected = @($baselinePayload.issues |
                    Where-Object { $_.rule.name -notin $run.Disabled } |
                    ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress } |
                    Sort-Object)
            $actual = @($candidatePayload.issues |
                    ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress } |
                    Sort-Object)
            ($actual -join "`n") | Should -Be ($expected -join "`n")
        }
        (Get-FileHash -LiteralPath $overridePaths).Hash | Should -Be $before.Hash
    }

    It 'retains native errors for unsupported utility override <Rule>' -ForEach @(
        @{ Rule = 'required_output_rmfr7'; Enabled = 'true' }
        @{ Rule = 'terraform_output_separate'; Enabled = 'true' }
        @{ Rule = 'unknown_utility_rule'; Enabled = 'false' }
    ) -Skip:((Test-Path Env:\AVM_OFFLINE) -and ($env:AVM_OFFLINE -eq '1')) {
        Install-AvmTool -Name tflint -ErrorAction Stop -SkipModuleVersionCheck
        $root = Join-Path $TestDrive $Rule
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), 'locals { value = 1 }')
        $overridePath = Join-Path $root 'override.hcl'
        [System.IO.File]::WriteAllText($overridePath, "rule `"$Rule`" {`n  enabled = $Enabled`n}`n")
        $run = InModuleScope 'Avm.Authoring' -Parameters @{
            Root = $root
            Override = $overridePath
            PluginDir = (Join-Path $TestDrive 'utility-plugins')
        } {
            param($Root, $Override, $PluginDir)
            $tool = Resolve-AvmTool -Name tflint
            $base = Join-Path (Resolve-AvmTflintConfigDir) 'avm.tflint.hcl'
            $merged = Join-Path $Root 'merged.hcl'
            Merge-AvmTflintConfig -BasePath $base -OverridePath $Override -DestinationPath $merged
            $init = Invoke-AvmProcess -FilePath $tool.Path `
                -ArgumentList @('--init', '--config', $base) `
                -WorkingDirectory $Root -EnvVars @{ TFLINT_PLUGIN_DIR = $PluginDir } -IgnoreExitCode
            $init.ExitCode | Should -Be 0 -Because $init.StdErr
            Invoke-AvmProcess -FilePath $tool.Path `
                -ArgumentList @('--config', $merged, '--format=json') `
                -WorkingDirectory $Root -EnvVars @{ TFLINT_PLUGIN_DIR = $PluginDir } -IgnoreExitCode
        }
        $run.ExitCode | Should -Be 1
        "$($run.StdOut)`n$($run.StdErr)" | Should -Match "Rule not found: $Rule"
    }
}
