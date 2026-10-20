#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: pr-check example dependency selections' -Tag Component {
    It 'retains tracked lock bytes on cold initialization, cache reuse and a repeated check' {
        $root = Join-Path $TestDrive 'module'
        $cache = Join-Path $TestDrive 'cache'
        $source = @'
terraform {
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
'@
        $lock = @'
provider "registry.terraform.io/hashicorp/random" {
  version     = "3.8.1"
  constraints = "~> 3.0"
}
'@
        $originalHashes = @{}
        foreach ($name in @('cold', 'prepared')) {
            $example = Join-Path $root 'examples' $name
            $null = New-Item -ItemType Directory -Path $example -Force
            [System.IO.File]::WriteAllText((Join-Path $example 'main.tf'), $source)
            $lockPath = Join-Path $example '.terraform.lock.hcl'
            [System.IO.File]::WriteAllText($lockPath, $lock)
            $originalHashes[$lockPath] = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
        }
        [System.IO.File]::WriteAllText((Join-Path $root 'terraform.tf'), $source)
        $preparedModules = Join-Path $root 'examples' 'prepared' '.terraform' 'modules'
        $null = New-Item -ItemType Directory -Path $preparedModules -Force
        [System.IO.File]::WriteAllText((Join-Path $preparedModules 'modules.json'), '{"Modules":[]}')

        InModuleScope 'Avm.Authoring' -Parameters @{
            Root = $root; Cache = $cache; OriginalHashes = $originalHashes
        } {
            param($Root, $Cache, $OriginalHashes)

            Mock Get-AvmTerraformPluginCachePath { Join-Path $Cache 'provider-cache' }
            Mock Get-AvmFolder { $Cache }
            Mock Resolve-AvmTool { [pscustomobject]@{ Path = 'terraform-stub' } }
            Mock Invoke-AvmProcess {
                param($WorkingDirectory, $ArgumentList)

                if ($ArgumentList -contains '-upgrade') {
                    [System.IO.File]::WriteAllText(
                        (Join-Path $WorkingDirectory '.terraform.lock.hcl'), 'upgraded dependency selections')
                }
                $modules = Join-Path $WorkingDirectory '.terraform' 'modules'
                $null = New-Item -ItemType Directory -Path $modules -Force
                [System.IO.File]::WriteAllText((Join-Path $modules 'modules.json'), '{"Modules":[]}')
                [pscustomobject]@{ ExitCode = 0 }
            }

            $context = [pscustomobject]@{
                Kind = 'terraform-module-repo'; Root = $Root; Ecosystem = 'terraform'
            }
            $first = Initialize-AvmTerraformCommand -Context $context -Command pr-check
            $first.Status | Should -Be 'pass'
            $first.Initialized | Should -Be @('examples/cold')
            $first.Reused | Should -Be @('examples/prepared')

            $second = Initialize-AvmTerraformCommand -Context $context -Command pr-check
            $second.Status | Should -Be 'pass'
            $second.InitializedDirectories | Should -Be 0
            $second.ReusedDirectories | Should -Be 2
            foreach ($path in $OriginalHashes.Keys) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash |
                    Should -BeExactly $OriginalHashes[$path]
            }
            Should -Invoke Invoke-AvmProcess -Exactly 1
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq 'terraform-stub' -and
                ($ArgumentList -join ' ') -ceq 'init -input=false -backend=false -no-color'
            }
        }

    }
}
