#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmTerraformCheckPolicy' {
    BeforeEach {
        $script:moduleDir = Join-Path $TestDrive ("tf-mod-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:moduleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Value 'variable "x" {}' -Encoding utf8

        $script:context = [pscustomobject][ordered]@{
            Kind      = 'terraform-module-repo'
            Root      = $script:moduleDir
            Ecosystem = 'terraform'
            Source    = 'path-heuristic'
        }

        $script:bothAssets = [pscustomobject]@{
            Assets  = [ordered]@{
                'avm-policy-aprl'   = [pscustomobject]@{
                    Source = 'https://example.test/aprl.tar.gz'
                    Ref    = 'v1.0.0'
                    Sha256 = ('a' * 64)
                    Type   = 'archive'
                }
                'avm-policy-avmsec' = [pscustomobject]@{
                    Source = 'https://example.test/avmsec.tar.gz'
                    Ref    = 'v2.0.0'
                    Sha256 = ('b' * 64)
                    Type   = 'archive'
                }
            }
            Sources = [ordered]@{}
        }
    }

    It 'rejects a non-terraform context' {
        $bicepCtx = [pscustomobject][ordered]@{
            Kind      = 'bicep-module'
            Root      = $TestDrive
            Ecosystem = 'bicep'
            Source    = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bicepCtx } {
                param($C)
                Invoke-AvmTerraformCheckPolicy -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'throws AvmConfigurationException when avm-policy-aprl is missing' {
        $ctx = $script:context
        $assets = [pscustomobject]@{
            Assets  = [ordered]@{
                'avm-policy-avmsec' = [pscustomobject]@{
                    Source = 'https://example.test/avmsec.tar.gz'; Ref = 'v1.0.0'; Sha256 = ('b' * 64); Type = 'archive'
                }
            }
            Sources = [ordered]@{}
        }
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $assets } {
                param($C, $A)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Read-AvmAssetConfig { $A }
                Mock Resolve-AvmPinnedAsset { throw 'should not be called' }
                Mock Invoke-AvmProcess { throw 'should not be called' }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match 'avm-policy-aprl'
    }

    It 'throws AvmConfigurationException when avm-policy-avmsec is missing' {
        $ctx = $script:context
        $assets = [pscustomobject]@{
            Assets  = [ordered]@{
                'avm-policy-aprl' = [pscustomobject]@{
                    Source = 'https://example.test/aprl.tar.gz'; Ref = 'v1.0.0'; Sha256 = ('a' * 64); Type = 'archive'
                }
            }
            Sources = [ordered]@{}
        }
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $assets } {
                param($C, $A)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Read-AvmAssetConfig { $A }
                Mock Resolve-AvmPinnedAsset { throw 'should not be called' }
                Mock Invoke-AvmProcess { throw 'should not be called' }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match 'avm-policy-avmsec'
    }

    It 'invokes conftest with the resolved bundle paths from the module root' {
        $ctx = $script:context
        $assets = $script:bothAssets
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $assets } {
            param($C, $A)
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
            Mock Read-AvmAssetConfig { $A }
            Mock Resolve-AvmPinnedAsset {
                param($Name, $Asset)
                if ($Name -eq 'avm-policy-aprl') {
                    [pscustomobject]@{ Name = $Name; Sha256 = $Asset.Sha256; Ref = $Asset.Ref; Path = '/fake/cache/aprl'; Action = 'cache-hit' }
                }
                else {
                    [pscustomobject]@{ Name = $Name; Sha256 = $Asset.Sha256; Ref = $Asset.Ref; Path = '/fake/cache/avmsec'; Action = 'cache-hit' }
                }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformCheckPolicy -Context $C
        }
        $result.Engine     | Should -Be 'terraform'
        $result.Tool       | Should -Be 'conftest/0.68.2'
        $result.ToolPath   | Should -Be '/fake/conftest'
        $result.ToolSource | Should -Be 'cache'
        $result.Status     | Should -Be 'pass'
        $result.Issues.Count | Should -Be 0

        $expectedRoot = $ctx.Root
        InModuleScope 'Avm.Authoring' -Parameters @{ R = $expectedRoot } {
            param($R)
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/conftest' -and
                $WorkingDirectory -eq $R -and
                $ArgumentList.Count -eq 10 -and
                $ArgumentList[0] -eq 'test' -and
                $ArgumentList[1] -eq '--policy' -and
                $ArgumentList[2] -eq '/fake/cache/aprl' -and
                $ArgumentList[3] -eq '--policy' -and
                $ArgumentList[4] -eq '/fake/cache/avmsec' -and
                $ArgumentList[5] -eq '--output' -and
                $ArgumentList[6] -eq 'json' -and
                $ArgumentList[7] -eq '--parser' -and
                $ArgumentList[8] -eq 'hcl2' -and
                $ArgumentList[9] -eq '.'
            }
        }
    }

    It 'parses failures into Issue records with Severity error' {
        $ctx = $script:context
        $assets = $script:bothAssets
        $json = @'
[
  {
    "filename": "main.tf",
    "namespace": "avm.aprl",
    "successes": 3,
    "failures": [
      { "msg": "Resource missing required tag" }
    ],
    "warnings": []
  }
]
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $assets; J = $json } {
            param($C, $A, $J)
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
            Mock Read-AvmAssetConfig { $A }
            Mock Resolve-AvmPinnedAsset {
                param($Name, $Asset)
                [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = $J; StdErr = '' } }
            Invoke-AvmTerraformCheckPolicy -Context $C
        }
        $result.Status            | Should -Be 'fail'
        $result.Issues.Count      | Should -Be 1
        $result.Issues[0].File    | Should -Be 'main.tf'
        $result.Issues[0].Severity | Should -Be 'error'
        $result.Issues[0].Code    | Should -Be 'avm.aprl'
        $result.Issues[0].Message | Should -Be 'Resource missing required tag'
        $result.Issues[0].Line    | Should -Be 0
    }

    It 'parses warnings as Severity warning without failing' {
        $ctx = $script:context
        $assets = $script:bothAssets
        $json = @'
[
  {
    "filename": "main.tf",
    "namespace": "avm.avmsec",
    "successes": 1,
    "warnings": [
      { "msg": "Consider enabling diagnostic settings" }
    ],
    "failures": []
  }
]
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $assets; J = $json } {
            param($C, $A, $J)
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
            Mock Read-AvmAssetConfig { $A }
            Mock Resolve-AvmPinnedAsset {
                param($Name, $Asset)
                [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' } }
            Invoke-AvmTerraformCheckPolicy -Context $C
        }
        $result.Status              | Should -Be 'pass'
        $result.Issues.Count        | Should -Be 1
        $result.Issues[0].Severity  | Should -Be 'warning'
        $result.Issues[0].Code      | Should -Be 'avm.avmsec'
        $result.Issues[0].Message   | Should -Be 'Consider enabling diagnostic settings'
    }

    It 'flattens mixed failures and warnings across multiple files' {
        $ctx = $script:context
        $assets = $script:bothAssets
        $json = @'
[
  {
    "filename": "main.tf",
    "namespace": "avm.aprl",
    "successes": 0,
    "failures": [{ "msg": "fail one" }, { "msg": "fail two" }],
    "warnings": [{ "msg": "warn one" }]
  },
  {
    "filename": "variables.tf",
    "namespace": "avm.avmsec",
    "successes": 2,
    "failures": [],
    "warnings": [{ "msg": "warn two" }]
  }
]
'@
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $assets; J = $json } {
            param($C, $A, $J)
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
            Mock Read-AvmAssetConfig { $A }
            Mock Resolve-AvmPinnedAsset {
                param($Name, $Asset)
                [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = $J; StdErr = '' } }
            Invoke-AvmTerraformCheckPolicy -Context $C
        }
        $result.Status                                       | Should -Be 'fail'
        $result.Issues.Count                                 | Should -Be 4
        ($result.Issues | Where-Object Severity -eq 'error').Count   | Should -Be 2
        ($result.Issues | Where-Object Severity -eq 'warning').Count | Should -Be 2
        $mainIssues = $result.Issues | Where-Object File -eq 'main.tf'
        $mainIssues.Count                                    | Should -Be 3
        $varsIssues = $result.Issues | Where-Object File -eq 'variables.tf'
        $varsIssues.Count                                    | Should -Be 1
        $varsIssues[0].Severity                              | Should -Be 'warning'
        $varsIssues[0].Code                                  | Should -Be 'avm.avmsec'
    }

    It 'throws AvmProcessException on unexpected conftest exit codes' {
        $ctx = $script:context
        $assets = $script:bothAssets
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $assets } {
                param($C, $A)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Read-AvmAssetConfig { $A }
                Mock Resolve-AvmPinnedAsset {
                    param($Name, $Asset)
                    [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 99; StdOut = ''; StdErr = 'conftest crashed' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmProcessException'
        $err.Message        | Should -Match 'conftest crashed'
        $err.Message        | Should -Match '99'
    }

    It 'returns the resolver-provided ToolSource on path fallback' {
        $ctx = $script:context
        $assets = $script:bothAssets
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; A = $assets } {
            param($C, $A)
            Mock Resolve-AvmTool {
                param($Name, [switch] $AllowPathFallback)
                [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'path'; Path = '/usr/local/bin/conftest' }
            }
            Mock Read-AvmAssetConfig { $A }
            Mock Resolve-AvmPinnedAsset {
                param($Name, $Asset)
                [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            Invoke-AvmTerraformCheckPolicy -Context $C -AllowPathFallback
        }
        $result.ToolPath   | Should -Be '/usr/local/bin/conftest'
        $result.ToolSource | Should -Be 'path'
    }
}
