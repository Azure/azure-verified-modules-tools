#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

param([string] $MapotfPath)

Describe 'Integration: MAPOTF module sources' -Tag 'Integration' -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $moduleRoot = Join-Path $repoRoot 'src' 'Avm.Authoring'
        $script:originalAvmHome = $env:AVM_HOME
        if (-not $env:AVM_HOME) {
            $env:AVM_HOME = Join-Path $TestDrive 'avm-home'
        }
        Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:terraformPath = InModuleScope 'Avm.Authoring' {
            (Resolve-AvmTool -Name terraform).Path
        }
        $script:mapotfPath = if ($MapotfPath) {
            (Resolve-Path -LiteralPath $MapotfPath -ErrorAction Stop).Path
        }
        else {
            InModuleScope 'Avm.Authoring' { (Resolve-AvmTool -Name mapotf).Path }
        }
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
        foreach ($name in @('order_module_attrs.mptf.hcl', 'remove_avm_headers_for_azapi.mptf.hcl')) {
            Copy-Item -LiteralPath (Join-Path $moduleRoot 'Resources' 'mapotf' 'common' $name) -Destination $script:config
        }

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

    It 'orders inputs from <Name> and remains idempotent' -TestCases @(
        @{ Name = 'a Git repository root'; Subdirectory = ''; Decoy = $false }
        @{ Name = 'a Git subdirectory with no root Terraform files'; Subdirectory = 'modules/nested'; Decoy = $false }
        @{ Name = 'a Git subdirectory with conflicting root inputs'; Subdirectory = 'modules/nested'; Decoy = $true }
    ) {
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
}
