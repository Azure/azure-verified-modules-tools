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
        Install-AvmTool -Name tflint -InformationAction Continue -ErrorAction Stop
        Install-AvmTool -Name terraform -InformationAction Continue -ErrorAction Stop

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

resource "azapi_resource" "example" {
  type                   = "Microsoft.Example/widgets@2024-01-01"
  name                   = "example"
  parent_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example"
  response_export_values = []
  replace_triggers_refs  = []
}

output "resource_id" {
  value = azapi_resource.example.id
}
'@ | Set-Content -LiteralPath (Join-Path $requiredRoot 'main.tf') -Encoding utf8NoBOM
        @'
variable "private_endpoints" {
  type        = map(string)
  default     = {}
  description = "An intentionally invalid private endpoint interface used to prove required-variable enforcement."
  nullable    = false
}
'@ | Set-Content -LiteralPath (Join-Path $requiredRoot 'variables.tf') -Encoding utf8NoBOM

        $canonicalRoot = Join-Path $script:repoRoot 'tests' 'fixtures' 'modules' 'terraform-azure-avm-res-mock'
        $deprecatedRoot = Join-Path $TestDrive 'deprecated-interface'
        Copy-Item -LiteralPath $canonicalRoot -Destination $deprecatedRoot -Recurse -Force
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

        $run = InModuleScope 'Avm.Authoring' -Parameters @{
            Canonical  = $canonicalRoot
            Config     = $script:configPath
            Deprecated = $deprecatedRoot
            Required   = $requiredRoot
        } {
            param($Canonical, $Config, $Deprecated, $Required)

            $tool = Resolve-AvmTool -Name 'tflint'
            $init = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--init', '--config', $Config) `
                -WorkingDirectory $Required `
                -IgnoreExitCode
            $version = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--config', $Config, '--version') `
                -WorkingDirectory $Required `
                -IgnoreExitCode
            $requiredLint = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--config', $Config, '--format=json', '--minimum-failure-severity=warning') `
                -WorkingDirectory $Required `
                -IgnoreExitCode
            $canonicalLint = Invoke-AvmProcess `
                -FilePath $tool.Path `
                -ArgumentList @('--config', $Config, '--format=json', '--minimum-failure-severity=warning') `
                -WorkingDirectory $Canonical `
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

        $run.RequiredLint.ExitCode | Should -Be 2 -Because $run.RequiredLint.StdErr
        $requiredPayload = $run.RequiredLint.StdOut | ConvertFrom-Json
        $requiredRules = @($requiredPayload.issues.rule.name)
        foreach ($rule in @(
                'ignore_body_changes',
                'private_endpoints_manage_dns_zone_group',
                'resource_types',
                'retry',
                'timeouts'
            )) {
            $requiredRules | Should -Contain $rule
        }

        $run.CanonicalLint.ExitCode | Should -Be 0 -Because "$($run.CanonicalLint.StdErr)`n$($run.CanonicalLint.StdOut)"
        $run.DeprecatedLint.ExitCode | Should -Be 0 -Because "$($run.DeprecatedLint.StdErr)`n$($run.DeprecatedLint.StdOut)"
        $run.DeprecatedResult.Status | Should -Be 'pass'
        $deprecatedIssue = $run.DeprecatedResult.Issues |
            Where-Object Code -eq 'deprecated_lock_interface'
        $deprecatedIssue | Should -Not -BeNullOrEmpty
        $deprecatedIssue.Severity | Should -Be 'notice'
        $deprecatedIssue.File | Should -Be 'variables.tf'
        $deprecatedIssue.Message | Should -Match 'v0\.19\.0 migration window'
        @($run.DeprecatedWarnings).Count | Should -Be 1
        $run.DeprecatedWarnings[0] | Should -Match '\[deprecated_lock_interface\].*v0\.19\.0 migration window'
        ($run.DeprecatedSummary -join "`n") | Should -Not -Match 'deprecated_lock_interface|v0\.19\.0 migration window'

        $run.CanonicalResult.Status | Should -Be 'pass'
        @($run.CanonicalWarnings) | Should -BeNullOrEmpty
        @($run.CanonicalResult.Issues | Where-Object Code -like 'deprecated_*_interface') |
            Should -BeNullOrEmpty
    }
}
