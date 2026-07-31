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

    It 'resolves both bundles from the shipped pin manifest with no repository config' {
        $ctx = $script:context
        $captured = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $seen = [ordered]@{}
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
            Mock Resolve-AvmPinnedAsset {
                param($Name, $Asset)
                $seen[$Name] = $Asset
                [pscustomobject]@{ Name = $Name; Sha256 = $Asset.Sha256; Ref = $Asset.Ref; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
            }
            Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
            $null = Invoke-AvmTerraformCheckPolicy -Context $C
            $seen
        }

        $captured.Keys | Should -Contain 'avm-policy-aprl'
        $captured.Keys | Should -Contain 'avm-policy-avmsec'
        foreach ($name in @('avm-policy-aprl', 'avm-policy-avmsec')) {
            $captured[$name].Source | Should -Match '^https://github\.com/Azure/policy-library-avm/archive/refs/tags/v'
            $captured[$name].Sha256 | Should -Match '^[0-9a-f]{64}$'
            $captured[$name].Type   | Should -Be 'archive'
            $captured[$name].Path   | Should -Match '^policy-library-avm-[0-9][^/]*/policy/'
        }
        $captured['avm-policy-aprl'].Path   | Should -Match '/policy/Azure-Proactive-Resiliency-Library-v2$'
        $captured['avm-policy-avmsec'].Path | Should -Match '/policy/avmsec$'
    }

    It 'invokes conftest against a staging directory holding only the Terraform sources' {
        $ctx = $script:context
        Set-Content -LiteralPath (Join-Path $script:moduleDir '.gitignore') -Value '*.tfstate' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'README.md') -Value '# mock' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $script:moduleDir 'examples' 'default') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:moduleDir 'examples' 'default' 'main.tf') -Value 'variable "y" {}' -Encoding utf8

        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            $seen = $null
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
            Mock Resolve-AvmPinnedAsset {
                param($Name, $Asset)
                if ($Name -eq 'avm-policy-aprl') {
                    [pscustomobject]@{ Name = $Name; Sha256 = $Asset.Sha256; Ref = $Asset.Ref; Path = '/fake/cache/aprl'; Action = 'cache-hit' }
                }
                else {
                    [pscustomobject]@{ Name = $Name; Sha256 = $Asset.Sha256; Ref = $Asset.Ref; Path = '/fake/cache/avmsec'; Action = 'cache-hit' }
                }
            }
            Mock Invoke-AvmProcess {
                $script:stagedFiles = @(Get-ChildItem -LiteralPath $WorkingDirectory -Recurse -File |
                        ForEach-Object { [System.IO.Path]::GetRelativePath($WorkingDirectory, $_.FullName).Replace('\', '/') })
                $script:stageRootSeen = $WorkingDirectory
                [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $result = Invoke-AvmTerraformCheckPolicy -Context $C
            [pscustomobject]@{
                Result = $result
                Staged = $script:stagedFiles
                Stage  = $script:stageRootSeen
                Cache  = (Get-AvmFolder -Kind Cache)
            }
        }

        $probe.Result.Status | Should -Be 'skipped'

        # The F48 defect: conftest walks every file under CWD, so a real module's
        # .gitignore aborted it in 'parse configurations' before a policy loaded.
        $probe.Staged | Should -Not -BeNullOrEmpty
        $probe.Staged | Should -Contain 'main.tf'
        $probe.Staged | Should -Contain 'examples/default/main.tf'
        $probe.Staged | Should -Not -Contain '.gitignore'
        $probe.Staged | Should -Not -Contain 'README.md'
        @($probe.Staged).Count | Should -Be 2

        $probe.Stage | Should -Not -Be $ctx.Root
        Test-Path -LiteralPath $probe.Stage | Should -BeFalse

        # Staging under the cache, not the system temp dir, is load-bearing:
        # conftest strips the drive letter from --policy, so an absolute bundle
        # path only resolves when CWD shares its volume. The bundles live under
        # the cache, so this containment is what guarantees that. Windows CI
        # (repo + AVM_HOME on D:, temp on C:) failed on exactly this.
        $probe.Stage | Should -BeLike ((Join-Path $probe.Cache 'policy-stage') + '*')
        [System.IO.Path]::GetPathRoot($probe.Stage) |
            Should -Be ([System.IO.Path]::GetPathRoot($probe.Cache))

        InModuleScope 'Avm.Authoring' {
            Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                $FilePath -eq '/fake/conftest' -and
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
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
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
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
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
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx; J = $json } {
            param($C, $J)
            Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
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
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
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
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
            param($C)
            Mock Resolve-AvmTool {
                param($Name, [switch] $AllowPathFallback)
                [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'path'; Path = '/usr/local/bin/conftest' }
            }
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

    Context 'per-example exceptions discovery' {
        BeforeEach {
            $script:examplesRoot = Join-Path $script:moduleDir 'examples'
        }

        It 'appends each examples/{name}/exceptions/*.rego as additional --policy pairs' {
            $exFoo = Join-Path $script:examplesRoot 'foo' 'exceptions'
            $exBar = Join-Path $script:examplesRoot 'bar' 'exceptions'
            $null = New-Item -ItemType Directory -Path $exFoo -Force
            $null = New-Item -ItemType Directory -Path $exBar -Force
            $fooFile = Join-Path $exFoo 'allow.rego'
            $barFile = Join-Path $exBar 'allow.rego'
            Set-Content -LiteralPath $fooFile -Value 'package x' -Encoding utf8
            Set-Content -LiteralPath $barFile -Value 'package y' -Encoding utf8

            $ctx = $script:context
            $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset {
                    param($Name, $Asset)
                    [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            InModuleScope 'Avm.Authoring' -Parameters @{ FooFile = $fooFile; BarFile = $barFile } {
                param($FooFile, $BarFile)
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList.Count -eq 14 -and
                    $ArgumentList[5] -eq '--policy' -and
                    $ArgumentList[7] -eq '--policy' -and
                    $ArgumentList[9] -eq '--output' -and
                    ($ArgumentList[6] -eq $BarFile -or $ArgumentList[6] -eq $FooFile) -and
                    ($ArgumentList[8] -eq $BarFile -or $ArgumentList[8] -eq $FooFile) -and
                    ($ArgumentList[6] -ne $ArgumentList[8])
                }
            }
        }

        It 'sorts discovered exceptions by FullName using ordinal comparison' {
            $exFoo = Join-Path $script:examplesRoot 'foo' 'exceptions'
            $null = New-Item -ItemType Directory -Path $exFoo -Force
            # Filenames chosen so en-US sort and ordinal sort disagree:
            # ordinal: 'Foo.rego' (0x46) < 'bar.rego' (0x62);
            # en-US:   'bar.rego' < 'Foo.rego' (case-insensitive then case-sensitive).
            $upperFile = Join-Path $exFoo 'Foo.rego'
            $lowerFile = Join-Path $exFoo 'bar.rego'
            Set-Content -LiteralPath $upperFile -Value 'package u' -Encoding utf8
            Set-Content -LiteralPath $lowerFile -Value 'package l' -Encoding utf8

            $ctx = $script:context
            $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset {
                    param($Name, $Asset)
                    [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            InModuleScope 'Avm.Authoring' -Parameters @{ Upper = $upperFile; Lower = $lowerFile } {
                param($Upper, $Lower)
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList[6] -eq $Upper -and
                    $ArgumentList[8] -eq $Lower
                }
            }
        }

        It 'emits no exceptions args when examples directory is absent' {
            $ctx = $script:context
            $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset {
                    param($Name, $Asset)
                    [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            InModuleScope 'Avm.Authoring' {
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList.Count -eq 10
                }
            }
        }

        It 'emits no exceptions args when an example has no exceptions subdir' {
            $null = New-Item -ItemType Directory -Path (Join-Path $script:examplesRoot 'foo') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $script:examplesRoot 'bar') -Force

            $ctx = $script:context
            $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset {
                    param($Name, $Asset)
                    [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            InModuleScope 'Avm.Authoring' {
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList.Count -eq 10
                }
            }
        }

        It 'skips non-.rego files inside exceptions directories' {
            $exFoo = Join-Path $script:examplesRoot 'foo' 'exceptions'
            $null = New-Item -ItemType Directory -Path $exFoo -Force
            $kept = Join-Path $exFoo 'allow.rego'
            Set-Content -LiteralPath $kept -Value 'package x' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $exFoo 'README.md') -Value '# notes' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $exFoo 'data.json') -Value '{}' -Encoding utf8

            $ctx = $script:context
            $null = InModuleScope 'Avm.Authoring' -Parameters @{ C = $ctx } {
                param($C)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset {
                    param($Name, $Asset)
                    [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' }
                }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            InModuleScope 'Avm.Authoring' -Parameters @{ Kept = $kept } {
                param($Kept)
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList.Count -eq 12 -and
                    $ArgumentList[5] -eq '--policy' -and
                    $ArgumentList[6] -eq $Kept -and
                    $ArgumentList[7] -eq '--output'
                }
            }
        }
    }

    Context 'vacuous-evaluation detection (F46)' {
        It 'reports skipped, not pass, when conftest evaluates zero policies' {
            # The shipped bundles declare no 'package main' rules, so conftest's
            # default namespace yields successes=0 and exit 0 on any module.
            $json = '[{"filename":"main.tf","namespace":"main","successes":0}]'
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; J = $json } {
                param($C, $J)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' } }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            $result.Status    | Should -Be 'skipped'
            $result.Evaluated | Should -Be 0
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Code     | Should -Be 'avm.tf.policy-not-evaluated'
            $result.Issues[0].Severity | Should -Be 'warning'
            $result.Issues[0].Message  | Should -Match 'evaluated 0 policies'
        }

        It 'reports skipped when every policy is evaluated but nothing can match (the --all-namespaces trap)' {
            # Adding --all-namespaces without the plan-JSON path moves the engine
            # from 0 evaluated to 260 vacuously passed. That must not read as pass.
            $json = '[{"filename":"main.tf","namespace":"avmsec","successes":100},{"filename":"main.tf","namespace":"Azure_Proactive_Resiliency_Library_v2","successes":160}]'
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; J = $json } {
                param($C, $J)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' } }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            $result.Status    | Should -Be 'skipped'
            $result.Evaluated | Should -Be 260
            $result.Issues[0].Code    | Should -Be 'avm.tf.policy-not-evaluated'
            $result.Issues[0].Message | Should -Match "evaluated 260 policies from the 'hcl2' parser"
        }

        It 'still reports fail when a policy genuinely fires' {
            $json = '[{"filename":"main.tf","namespace":"avmsec","successes":259,"failures":[{"msg":"AVM_SEC_2_1: CMK required"}]}]'
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; J = $json } {
                param($C, $J)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' } }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = $J; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            $result.Status    | Should -Be 'fail'
            $result.Evaluated | Should -Be 260
            @($result.Issues | Where-Object { $_.Code -eq 'avm.tf.policy-not-evaluated' }).Count | Should -Be 0
        }

        It 'does not skip when only warnings fire, because a rule that fired proves the input matched' {
            $json = '[{"filename":"main.tf","namespace":"avmsec","successes":259,"warnings":[{"msg":"advisory"}]}]'
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; J = $json } {
                param($C, $J)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' } }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            $result.Status | Should -Be 'pass'
            @($result.Issues | Where-Object { $_.Code -eq 'avm.tf.policy-not-evaluated' }).Count | Should -Be 0
        }
    }

    Context 'run-failure detection (F48)' {
        It 'reports error, not skipped, when conftest exits non-zero without producing results' {
            # conftest reuses exit 1 for 'a policy failed' and 'I aborted before
            # evaluating anything'. Reported as the vacuity skip, a crash was
            # indistinguishable from a clean run that matched no rule.
            $stderr = 'Error: running test: parse configurations: parser unmarshal: convert to bytes: parse config: [:1,1-2: Argument or block definition required], path: .gitignore'
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; E = $stderr } {
                param($C, $E)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' } }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $E } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            $result.Status    | Should -Be 'error'
            $result.Evaluated | Should -Be 0
            $result.Issues.Count | Should -Be 1
            $result.Issues[0].Code     | Should -Be 'avm.tf.policy-run-failed'
            $result.Issues[0].Severity | Should -Be 'error'
            $result.Issues[0].Message  | Should -Match 'parse configurations'
            # Pin the cause, not the shared value: both this and the namespace
            # skip yield Evaluated=0, so only the diagnostic separates them.
            $result.Issues[0].Message  | Should -Not -Match 'default .main. namespace'
        }

        It 'keeps reporting fail when conftest exits non-zero with real findings' {
            # Negative control for the guard above: exit 1 plus output is a
            # genuine policy failure and must not be re-labelled a crash.
            $json = '[{"filename":"main.tf","namespace":"avmsec","successes":259,"failures":[{"msg":"AVM_SEC_2_1: CMK required"}]}]'
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; J = $json } {
                param($C, $J)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' } }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = $J; StdErr = 'noise on stderr' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            $result.Status | Should -Be 'fail'
            @($result.Issues | Where-Object { $_.Code -eq 'avm.tf.policy-run-failed' }).Count | Should -Be 0
            @($result.Issues | Where-Object { $_.Severity -eq 'error' }).Count | Should -Be 1
        }

        It 'keeps the namespace skip when conftest succeeds having evaluated nothing' {
            # Second negative control: exit 0 with output is the honest vacuity
            # case and must keep its own diagnostic, not become an error.
            $json = '[{"filename":"main.tf","namespace":"main","successes":0}]'
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context; J = $json } {
                param($C, $J)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' } }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 0; StdOut = $J; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            $result.Status | Should -Be 'skipped'
            $result.Issues[0].Code    | Should -Be 'avm.tf.policy-not-evaluated'
            $result.Issues[0].Message | Should -Match 'namespaces seen: main'
        }

        It 'surfaces a bare non-zero exit with no stderr as an error rather than a silent skip' {
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
                param($C)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' } }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = '' } }
                Invoke-AvmTerraformCheckPolicy -Context $C
            }

            $result.Status | Should -Be 'error'
            $result.Issues[0].Code    | Should -Be 'avm.tf.policy-run-failed'
            $result.Issues[0].Message | Should -Match 'exited with code 1'
        }
        It 'skips without launching conftest when the module holds no Terraform sources' {
            # conftest exits 1 with 'no files found' on an empty tree. Routed
            # through the crash guard that would read as a run failure; nothing
            # to check is a skip, and it is knowable before launching anything.
            Remove-Item -LiteralPath (Join-Path $script:moduleDir 'main.tf') -Force
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ C = $script:context } {
                param($C)
                Mock Resolve-AvmTool { [pscustomobject]@{ Name = 'conftest'; Version = '0.68.2'; Platform = 'linux-amd64'; Source = 'cache'; Path = '/fake/conftest' } }
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) [pscustomobject]@{ Name = $Name; Path = "/fake/cache/$Name"; Action = 'cache-hit' } }
                Mock Invoke-AvmProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Error: running test: parse files: no files found' } }
                $r = Invoke-AvmTerraformCheckPolicy -Context $C
                Should -Invoke Invoke-AvmProcess -Exactly 0
                $r
            }

            $result.Status | Should -Be 'skipped'
            $result.Issues[0].Code    | Should -Be 'avm.tf.policy-not-evaluated'
            $result.Issues[0].Message | Should -Match 'no \.tf or \.tfvars files'
        }
    }
}
