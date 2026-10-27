#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: provider-free Terraform policy planning' -Tag Qualification {
    BeforeAll {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        Import-Module (Join-Path $repo 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
        $script:tools = InModuleScope Avm.Authoring {
            @{ Terraform = Resolve-AvmTool -Name terraform; Conftest = Resolve-AvmTool -Name conftest }
        }
    }

    AfterAll {
        Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'initializes, validates, plans and runs Conftest on a local provider-free module' {
        $stage = Join-Path $TestDrive 'stage'
        $root = Join-Path $stage 'example'
        $child = Join-Path $root 'child'
        $policy = Join-Path $stage 'policy'
        $null = New-Item -ItemType Directory -Path $child, $policy -Force
        @'
module "utility" {
  source = "./child"
}
output "cidr" {
  value = module.utility.cidr
}
'@ | Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM
        @'
removed {
  from = random_uuid.telemetry
  lifecycle {
    destroy = false
  }
}
locals {
  cidr = cidrsubnet("10.0.0.0/16", 8, 0)
}
output "cidr" {
  value = local.cidr
}
'@ | Set-Content -LiteralPath (Join-Path $child 'main.tf') -Encoding utf8NoBOM
        @'
package main

deny contains "unexpected CIDR" if {
  input.planned_values.outputs.cidr.value != "10.0.0.0/24"
}
'@ | Set-Content -LiteralPath (Join-Path $policy 'policy.rego') -Encoding utf8NoBOM

        InModuleScope Avm.Authoring -Parameters @{
            Root = $root; Stage = $stage; Policy = $policy
            Terraform = $script:tools.Terraform.Path; Conftest = $script:tools.Conftest.Path
        } {
            param($Root, $Stage, $Policy, $Terraform, $Conftest)
            $isolated = @{ CHECKPOINT_DISABLE = '1' }
            foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -match '^(ARM_|AZURE_|TF_CLI_ARGS|TF_VAR_)' }) {
                $isolated[$item.Name] = $null
            }
            $environment = Get-AvmTerraformPolicyEnvironment -StageRoot $Stage -Environment $isolated
            Initialize-AvmTerraformPolicyStage -WorkingDirectory $Root -StageRoot $Stage `
                -TerraformPath $Terraform -ConftestPath $Conftest -EnvVars $environment
            $schema = Invoke-AvmProcess -FilePath $Terraform -WorkingDirectory $Root -EnvVars $environment `
                -ArgumentList @('providers', 'schema', '-json')
            $decoded = ConvertFrom-Json -InputObject $schema.StdOut -AsHashtable
            $decoded.format_version | Should -Be '1.0'
            $decoded.Contains('provider_schemas') | Should -BeFalse
            $null = Invoke-AvmProcess -FilePath $Terraform -WorkingDirectory $Root -EnvVars $environment `
                -ArgumentList @('plan', '-input=false', '-out=policy.tfplan')
            $plan = Invoke-AvmProcess -FilePath $Terraform -WorkingDirectory $Root -EnvVars $environment `
                -ArgumentList @('show', '-json', 'policy.tfplan')
            $planFile = Join-Path $Stage 'plan.json'
            [System.IO.File]::WriteAllText($planFile, $plan.StdOut, [System.Text.UTF8Encoding]::new($false))
            $result = Invoke-AvmProcess -FilePath $Conftest -WorkingDirectory $Root `
                -ArgumentList @('test', '--policy', $Policy, $planFile)
            $result.ExitCode | Should -Be 0
            [System.IO.File]::WriteAllText($planFile, '{"planned_values":{"outputs":{"cidr":{"value":"wrong"}}}}')
            $failure = Invoke-AvmProcess -FilePath $Conftest -WorkingDirectory $Root `
                -ArgumentList @('test', '--policy', $Policy, $planFile) -IgnoreExitCode
            $failure.ExitCode | Should -Not -Be 0
            $failure.StdOut | Should -Match 'unexpected CIDR'
        }
    }
}
