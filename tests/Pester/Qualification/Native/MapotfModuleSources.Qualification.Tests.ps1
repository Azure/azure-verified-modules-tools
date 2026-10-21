#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: MAPOTF module sources' -Tag Qualification {
BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $moduleRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
        $script:originalAvmHome = $env:AVM_HOME
        if (-not $env:AVM_HOME) {
            $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        }
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:terraformPath = InModuleScope 'Avm.Authoring' {
            (Resolve-AvmTool -Name terraform).Path
        }
        $script:mapotfPath = InModuleScope 'Avm.Authoring' { (Resolve-AvmTool -Name mapotf).Path }
        $script:gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $script:processEnvironment = InModuleScope 'Avm.Authoring' -Parameters @{ Terraform = $script:terraformPath } {
            param($Terraform)
            New-AvmToolPathEnvironment -ToolPath $Terraform -ToolName terraform
        }
        $script:processEnvironment.TF_DATA_DIR = $null
        $script:processEnvironment.TF_CLI_ARGS = $null
        $script:processEnvironment.TF_CLI_ARGS_get = $null
        $script:config = Join-Path $TestDrive 'config'
        $null = New-Item -ItemType Directory -Path $script:config
        Copy-Item `
            -LiteralPath (Join-Path $moduleRoot 'Resources' 'mapotf' 'common' 'order_module_attrs.mptf.hcl') `
            -Destination $script:config

        function Invoke-ModuleSourceProcess {
            param([string] $FilePath, [string[]] $ArgumentList, [string] $WorkingDirectory)

            InModuleScope 'Avm.Authoring' -Parameters @{
                FilePath = $FilePath
                ArgumentList = $ArgumentList
                WorkingDirectory = $WorkingDirectory
                Environment = $script:processEnvironment
            } {
                param($FilePath, $ArgumentList, $WorkingDirectory, $Environment)
                Invoke-AvmProcess -FilePath $FilePath -ArgumentList $ArgumentList `
                    -WorkingDirectory $WorkingDirectory -EnvVars $Environment
            }
        }

        $script:variables = @'
variable "z_required" {
  type = string
}
variable "b_required" {
  type = string
}
variable "y_optional" {
  type    = string
  default = ""
}
variable "a_optional" {
  type    = string
  default = ""
}
'@
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

It 'orders inputs from <Name> and remains idempotent' -TestCases (@(
        @{ Name = 'a Git repository root'; Subdirectory = ''; Decoy = $false }
        @{ Name = 'a Git subdirectory with no root Terraform files'; Subdirectory = 'modules/nested'; Decoy = $false }
        @{ Name = 'a Git subdirectory with conflicting root inputs'; Subdirectory = 'modules/nested'; Decoy = $true }
    ) | Where-Object { $_.Decoy }) {
        param($Name, $Subdirectory, $Decoy)

        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $repository = Join-Path $work 'source repo'
        $target = Join-Path $work 'consumer'
        $null = New-Item -ItemType Directory -Path $repository, $target -Force
        $moduleDirectory = if ($Subdirectory) {
            Join-Path $repository 'modules' 'nested'
        }
        else {
            $repository
        }
        $null = New-Item -ItemType Directory -Path $moduleDirectory -Force
        Set-Content -LiteralPath (Join-Path $moduleDirectory 'variables.tf') -Value $script:variables -Encoding utf8NoBOM
        if ($Decoy) {
            Set-Content -LiteralPath (Join-Path $repository 'variables.tf') -Encoding utf8NoBOM -Value @'
variable "z_required" {
  type    = string
  default = ""
}
variable "b_required" {
  type    = string
  default = ""
}
variable "y_optional" {
  type = string
}
variable "a_optional" {
  type = string
}
'@
        }

        $null = Invoke-ModuleSourceProcess -FilePath $script:gitPath -WorkingDirectory $repository -ArgumentList @(
            'init', '--quiet', '--initial-branch=main'
        )
        $null = Invoke-ModuleSourceProcess -FilePath $script:gitPath -WorkingDirectory $repository -ArgumentList @(
            '-c', 'core.autocrlf=false', 'add', '--all'
        )
        $null = Invoke-ModuleSourceProcess -FilePath $script:gitPath -WorkingDirectory $repository -ArgumentList @(
            '-c', 'user.name=AVM Tests', '-c', 'user.email=avm-tests@example.invalid',
            '-c', 'commit.gpgsign=false', '-c', "core.hooksPath=$work",
            'commit', '--quiet', '-m', 'Create module source fixture'
        )
        $revision = (Invoke-ModuleSourceProcess -FilePath $script:gitPath -WorkingDirectory $repository -ArgumentList @(
            'rev-parse', 'HEAD'
        )).StdOut.Trim()
        $repositoryUri = [UriBuilder]::new('file', '', -1, $repository).Uri
        $repositoryUri.IsFile | Should -BeTrue
        $repositoryUri.LocalPath | Should -BeExactly $repository
        $source = 'git::' + $repositoryUri.AbsoluteUri
        if ($Subdirectory) {
            $source += '//' + $Subdirectory
        }
        $source += '?ref=' + $revision

        $main = Join-Path $target 'main.tf'
        Set-Content -LiteralPath $main -Encoding utf8NoBOM -Value @"
module "config" {
  source = "$source"

  y_optional = "y"
  z_required = "z"
  a_optional = "a"
  b_required = "b"
}
"@
        $arguments = @('transform', '--mptf-dir', $script:config, '--tf-dir', $target)
        $null = Invoke-ModuleSourceProcess -FilePath $script:mapotfPath -ArgumentList $arguments -WorkingDirectory $target
        $first = Get-Content -LiteralPath $main -Raw
        $names = @([regex]::Matches($first, '(?m)^\s+(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value })
        ($names -join ',') | Should -BeExactly 'source,b_required,z_required,a_optional,y_optional'
        $first | Should -Match ([regex]::Escape($source))

        $null = Invoke-ModuleSourceProcess -FilePath $script:mapotfPath -ArgumentList $arguments -WorkingDirectory $target
        Get-Content -LiteralPath $main -Raw | Should -BeExactly $first
    }

It 'forwards root telemetry through local children on the first pass with instrumentation=<Instrumented>' -ForEach @(
        @{ Instrumented = $true }
        @{ Instrumented = $false }
    ) {
        $root = Join-Path $TestDrive "telemetry-inheritance-$Instrumented"
        $branch = Join-Path $root 'modules' 'branch'
        $leaf = Join-Path $branch 'modules' 'leaf'
        $plain = Join-Path $root 'modules' 'plain'
        foreach ($path in @($root, $branch, $leaf, $plain)) {
            $null = New-Item -ItemType Directory -Path $path -Force
            Set-Content -LiteralPath (Join-Path $path 'metadata.json') -Value '{}' -Encoding utf8NoBOM
        }
        if ($Instrumented) {
            foreach ($path in @($root, $branch, $leaf)) {
                Set-Content -LiteralPath (Join-Path $path 'metadata.json') -Encoding utf8NoBOM -Value '{"telemetryIdPrefix":"46d3xtrf.res.a1b2c3d"}'
            }
            Set-Content -LiteralPath (Join-Path $root 'terraform.tf') -Encoding utf8NoBOM -Value @'
terraform {
  required_providers {
    azapi = { source = "Azure/azapi", version = "~> 2.12" }
  }
}
'@
        }
        Set-Content -LiteralPath (Join-Path $leaf 'main.tf') -Encoding utf8NoBOM -Value @'
output "enabled" {
  value = var.enable_telemetry
}
'@
        if (-not $Instrumented) {
            Add-Content -LiteralPath (Join-Path $leaf 'main.tf') -Encoding utf8NoBOM -Value @'
variable "enable_telemetry" {
  type    = bool
  default = true
}
'@
        }
        Set-Content -LiteralPath (Join-Path $branch 'main.tf') -Encoding utf8NoBOM -Value @'
module "leaf" {
  source = "./modules/leaf"
  enable_telemetry = false
}
output "enabled" {
  value = module.leaf.enabled
}
'@
        Set-Content -LiteralPath (Join-Path $plain 'main.tf') -Encoding utf8NoBOM -Value @'
output "plain" {
  value = true
}
'@
        Set-Content -LiteralPath (Join-Path $root 'main.tf') -Encoding utf8NoBOM -Value @'
module "branch" {
  source = "./modules/branch"
  enable_telemetry = true
}
module "plain" {
  source = "./modules/plain"
}
module "direct" {
  source = "./modules/branch/modules/leaf"
}
output "enabled" {
  value = module.branch.enabled
}
output "direct_enabled" {
  value = module.direct.enabled
}
'@
        $tests = Join-Path $root 'tests'
        $null = New-Item -ItemType Directory -Path $tests
        $scopes = @($root, $branch, $leaf, $plain)
        if ($Instrumented) {
            $wrapper = Join-Path $tests 'wrapper'
            $null = New-Item -ItemType Directory -Path $wrapper
            $scopes += $wrapper
            Set-Content -LiteralPath (Join-Path $wrapper 'main.tf') -Encoding utf8NoBOM -Value @'
module "subject" {
  source = "../.."
  enable_telemetry = false
}
'@
        }
        $mocks = if ($Instrumented) {
            @'
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000001"
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000001"
      tenant_id       = "00000000-0000-0000-0000-000000000002"
    }
  }
}
mock_provider "terraform" {}
'@
        }
        else { '' }
        $locationInput = if ($Instrumented) { 'location = "eastus"' } else { '' }
        Set-Content -LiteralPath (Join-Path $tests 'telemetry.tftest.hcl') -Encoding utf8NoBOM -Value ($mocks + "`n" + @"
run "root_opt_out" {
  command = plan
  variables {
    enable_telemetry = false
    $locationInput
  }
  assert {
    condition     = output.enabled == false && output.direct_enabled == false
    error_message = "The root opt-out must reach the transitive child."
  }
}
run "root_opt_in" {
  command = plan
  variables {
    enable_telemetry = true
    $locationInput
  }
  assert {
    condition     = output.enabled == true && output.direct_enabled == true
    error_message = "The root opt-in must reach the transitive child."
  }
}
"@)
        $first = @{}
        foreach ($pass in 1..2) {
            InModuleScope Avm.Authoring -Parameters @{ Root = $root } {
                param($Root)
                $result = Invoke-AvmTerraformTransform -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' })
                $result.Status | Should -BeExactly 'pass'
            }
            $null = Invoke-ModuleSourceProcess -FilePath $script:terraformPath -WorkingDirectory $root -ArgumentList @(
                'init', '-backend=false', '-input=false', '-no-color'
            )
            $execution = Invoke-ModuleSourceProcess -FilePath $script:terraformPath -WorkingDirectory $root -ArgumentList @('test', '-no-color')
            $execution.StdOut | Should -Match '2 passed, 0 failed'
            Get-Content -LiteralPath (Join-Path $plain 'main.tf') -Raw | Should -Not -Match 'enable_telemetry'
            if ($Instrumented) {
                Get-Content -LiteralPath (Join-Path $wrapper 'main.tf') -Raw | Should -Match 'enable_telemetry\s*=\s*false'
                @(Get-ChildItem -LiteralPath $wrapper -File -Filter '*.tf' |
                        ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n" | Should -Not -Match 'variable "enable_telemetry"'
            }
            foreach ($path in $scopes) {
                $content = @(Get-ChildItem -LiteralPath $path -File -Filter '*.tf' | Sort-Object Name |
                        ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
                if (-not $Instrumented) { $content | Should -Not -Match 'variable "location"' }
                if ($pass -eq 1) { $first[$path] = $content }
                else { $content | Should -BeExactly $first[$path] }
            }
        }
    }
}
