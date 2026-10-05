#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: Terraform plan data evidence' -Tag Integration {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        Import-Module (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
        . (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'TestTenant.ps1')
        $root = Join-Path $TestDrive 'local-plan'
        $child = Join-Path $root 'azure'
        $null = [System.IO.Directory]::CreateDirectory($child)
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), @'
module "azure" {
  source = "./azure"
}
'@, $encoding)
        [System.IO.File]::WriteAllText((Join-Path $child 'main.tf'), @'
data "terraform_remote_state" "context" {
  backend = "local"
  config = {
    path = "${path.module}/context.tfstate"
  }
}

resource "terraform_data" "consumer" {
  input = data.terraform_remote_state.context.outputs
}
'@, $encoding)
        $snapshot = @{
            version = 4
            serial = 1
            lineage = '00000000-0000-4000-8000-000000000001'
            outputs = @{
                tenant_id = @{ value = '10000000-0000-4000-8000-000000000001'; type = 'string' }
                subscription_id = @{ value = '10000000-0000-4000-8000-000000000003'; type = 'string' }
            }
            resources = @()
        }
        [System.IO.File]::WriteAllText((Join-Path $child 'context.tfstate'),
            (ConvertTo-Json -InputObject $snapshot -Depth 10), $encoding)
        $script:plan = & (Get-Module Avm.Authoring) {
            param($Root)

            $tool = Resolve-AvmTool -Name terraform
            $environment = @{
                TF_DATA_DIR = Join-Path $Root 'data'
                TF_IN_AUTOMATION = 'true'
                TF_INPUT = 'false'
                TF_CLI_ARGS = $null
                TF_CLI_ARGS_init = $null
                TF_CLI_ARGS_plan = $null
                TF_CLI_ARGS_show = $null
                TF_LOG = $null
                TF_LOG_PATH = $null
            }
            foreach ($arguments in @(
                @('init', '-backend=false', '-input=false', '-no-color'),
                @('plan', '-input=false', '-no-color', '-out=candidate.tfplan')
            )) {
                $null = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList $arguments `
                    -WorkingDirectory $Root -EnvVars $environment
            }
            $result = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @('show', '-json', 'candidate.tfplan') `
                -WorkingDirectory $Root -EnvVars $environment
            ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -Depth 100
        } $root
    }

    It 'serializes completed data reads in refreshed prior state, not planned values or resource changes' {
        $planned = @(Get-AvmTerraformPlannedResource -Module $script:plan['planned_values']['root_module'])
        @($planned | Where-Object { $_['mode'] -ceq 'data' }).Count | Should -Be 0
        @($script:plan['resource_changes'] | Where-Object { $_['mode'] -ceq 'data' }).Count | Should -Be 0
        $refreshed = @(Get-AvmTerraformPlannedResource -Module $script:plan['prior_state']['values']['root_module'])
        $data = @($refreshed | Where-Object { $_['mode'] -ceq 'data' })
        $data.Count | Should -Be 1
        $data[0]['address'] | Should -BeExactly 'module.azure.data.terraform_remote_state.context'
        $data[0]['values']['outputs']['tenant_id'] | Should -BeExactly '10000000-0000-4000-8000-000000000001'
        $data[0]['values']['outputs']['subscription_id'] | Should -BeExactly '10000000-0000-4000-8000-000000000003'
        $planned.Count | Should -Be 1
        $planned[0]['values']['input']['tenant_id'] | Should -BeExactly $data[0]['values']['outputs']['tenant_id']
    }

    It 'reads the native saved plan through the production evidence reader' {
        $data = @(Get-AvmTerraformPlanDataResource -Plan $script:plan)
        $data.Count | Should -Be 1
        $data[0]['address'] | Should -BeExactly 'module.azure.data.terraform_remote_state.context'
        $data[0]['values']['outputs']['tenant_id'] | Should -BeExactly '10000000-0000-4000-8000-000000000001'
        $data[0]['values']['outputs']['subscription_id'] | Should -BeExactly '10000000-0000-4000-8000-000000000003'
    }
}
