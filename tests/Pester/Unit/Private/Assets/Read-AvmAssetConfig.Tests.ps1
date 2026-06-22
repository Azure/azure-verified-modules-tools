#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    # Each test gets its own AVM_HOME + repo directory under a Pester-scoped
    # temp root. Cleaning up at AfterEach keeps tests independent.
    $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("avm-asset-cfg-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tempRoot -Force | Out-Null

    function script:NewIsolation {
        $id = [Guid]::NewGuid().ToString('N')
        $avmHome = Join-Path $script:tempRoot ("home-" + $id)
        $repoRoot = Join-Path $script:tempRoot ("repo-" + $id)
        New-Item -ItemType Directory -Path $avmHome -Force | Out-Null
        New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
        return [pscustomobject]@{
            AvmHome  = $avmHome
            RepoRoot = $repoRoot
        }
    }

    function script:WriteJson {
        param(
            [Parameter(Mandatory)] [string] $Path,
            [Parameter(Mandatory)] [string] $Json
        )
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($Path, $Json, [System.Text.UTF8Encoding]::new($false))
    }

    function script:NewRepoConfigJson {
        @'
{
  "schemaVersion": 1,
  "assets": {
    "aprl-policies": {
      "source": "https://github.com/Azure/example-repo/archive/v2.tar.gz",
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
  }
}
'@
    }

    function script:NewUserConfigJson {
        @'
{
  "schemaVersion": 1,
  "assets": {
    "aprl-policies": {
      "source": "https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2.git",
      "ref": "main"
    },
    "avmsec-policies": {
      "source": "https://github.com/Azure/AVM-Sec-Policies.git",
      "ref": "v1.0.0"
    }
  }
}
'@
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Read-AvmAssetConfig' {
    BeforeEach {
        $script:iso = script:NewIsolation
        $script:savedAvmHome = $env:AVM_HOME
        $env:AVM_HOME = $script:iso.AvmHome
    }

    AfterEach {
        if ($null -eq $script:savedAvmHome) {
            Remove-Item Env:AVM_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_HOME = $script:savedAvmHome
        }
        Remove-Item -LiteralPath $script:iso.AvmHome -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:iso.RepoRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'no config files present' {
        It 'returns an empty Assets map and empty Sources map' {
            $repoRoot = $script:iso.RepoRoot
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $repoRoot } {
                param($P)
                Read-AvmAssetConfig -Path $P
            }
            $result.PSObject.Properties['Assets'] | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties['Sources'] | Should -Not -BeNullOrEmpty
            $result.Assets.Count | Should -Be 0
            $result.Sources.Count | Should -Be 0
        }
    }

    Context 'per-user config only' {
        It 'surfaces every asset declared in the per-user config' {
            $configDir = Join-Path $script:iso.AvmHome 'config'
            $userPath = Join-Path $configDir 'avm.config.json'
            script:WriteJson -Path $userPath -Json (script:NewUserConfigJson)

            $repoRoot = $script:iso.RepoRoot
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $repoRoot } {
                param($P)
                Read-AvmAssetConfig -Path $P
            }
            $result.Assets.Count | Should -Be 2
            $result.Assets['aprl-policies'].Source |
                Should -Be 'https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2.git'
            $result.Assets['aprl-policies'].Ref | Should -Be 'main'
            $result.Assets['avmsec-policies'].Ref | Should -Be 'v1.0.0'
            $result.Sources['aprl-policies'] | Should -Be (Resolve-Path -LiteralPath $userPath).ProviderPath
        }
    }

    Context 'per-repo config only' {
        It 'finds .avm/config.json beside the supplied path' {
            $repoRoot = $script:iso.RepoRoot
            $repoPath = Join-Path $repoRoot '.avm/config.json'
            script:WriteJson -Path $repoPath -Json (script:NewRepoConfigJson)

            $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $repoRoot } {
                param($P)
                Read-AvmAssetConfig -Path $P
            }
            $result.Assets.Count | Should -Be 1
            $result.Assets['aprl-policies'].Sha256 | Should -Be ('c' * 64)
            $result.Assets['aprl-policies'].Ref | Should -BeNullOrEmpty
        }

        It 'walks upward to find .avm/config.json in an ancestor directory' {
            $repoRoot = $script:iso.RepoRoot
            $repoPath = Join-Path $repoRoot '.avm/config.json'
            script:WriteJson -Path $repoPath -Json (script:NewRepoConfigJson)
            $deep = Join-Path $repoRoot 'a/b/c/d'
            New-Item -ItemType Directory -Path $deep -Force | Out-Null

            $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $deep } {
                param($P)
                Read-AvmAssetConfig -Path $P
            }
            $result.Assets.Count | Should -Be 1
            $result.Assets['aprl-policies'].Sha256 | Should -Be ('c' * 64)
        }
    }

    Context 'merging both layers' {
        It 'per-repo override wins per asset; per-user-only assets pass through' {
            $configDir = Join-Path $script:iso.AvmHome 'config'
            $userPath = Join-Path $configDir 'avm.config.json'
            script:WriteJson -Path $userPath -Json (script:NewUserConfigJson)
            $repoPath = Join-Path $script:iso.RepoRoot '.avm/config.json'
            script:WriteJson -Path $repoPath -Json (script:NewRepoConfigJson)

            $repoRoot = $script:iso.RepoRoot
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $repoRoot } {
                param($P)
                Read-AvmAssetConfig -Path $P
            }
            $result.Assets.Count | Should -Be 2
            # aprl-policies should now reflect the repo override (sha256, no ref)
            $result.Assets['aprl-policies'].Sha256 | Should -Be ('c' * 64)
            $result.Assets['aprl-policies'].Ref | Should -BeNullOrEmpty
            $result.Sources['aprl-policies'] | Should -Be (Resolve-Path -LiteralPath $repoPath).ProviderPath
            # avmsec-policies is not in repo config; per-user wins.
            $result.Assets['avmsec-policies'].Ref | Should -Be 'v1.0.0'
            $result.Sources['avmsec-policies'] | Should -Be (Resolve-Path -LiteralPath $userPath).ProviderPath
        }
    }

    Context 'failure modes' {
        It 'throws AvmConfigurationException on malformed JSON in the per-repo file' {
            $repoPath = Join-Path $script:iso.RepoRoot '.avm/config.json'
            script:WriteJson -Path $repoPath -Json 'not really json'
            $repoRoot = $script:iso.RepoRoot
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $repoRoot } {
                param($P)
                { Read-AvmAssetConfig -Path $P } |
                    Should -Throw -ExceptionType ([AvmConfigurationException])
            }
        }

        It 'throws AvmConfigurationException on schema violation in the per-repo file' {
            $repoPath = Join-Path $script:iso.RepoRoot '.avm/config.json'
            $bad = @'
{
  "schemaVersion": 1,
  "assets": {
    "aprl-policies": {
      "source": "http://example.com/x.git",
      "ref": "main"
    }
  }
}
'@
            script:WriteJson -Path $repoPath -Json $bad
            $repoRoot = $script:iso.RepoRoot
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $repoRoot } {
                param($P)
                { Read-AvmAssetConfig -Path $P } |
                    Should -Throw -ExceptionType ([AvmConfigurationException])
            }
        }

        It 'prefixes the schema error with the offending file path' {
            $repoPath = Join-Path $script:iso.RepoRoot '.avm/config.json'
            $bad = @'
{
  "schemaVersion": 1,
  "assets": {
    "aprl-policies": {
      "source": "https://example.com/x.git"
    }
  }
}
'@
            script:WriteJson -Path $repoPath -Json $bad
            $repoRoot = $script:iso.RepoRoot
            $expected = (Resolve-Path -LiteralPath $repoPath).ProviderPath
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $repoRoot; Expected = $expected } {
                param($P, $Expected)
                $captured = $null
                try {
                    Read-AvmAssetConfig -Path $P
                }
                catch {
                    $captured = $_.Exception
                }
                $captured | Should -Not -BeNullOrEmpty
                $captured | Should -BeOfType ([AvmConfigurationException])
                $captured.Message | Should -Match ([regex]::Escape($Expected))
            }
        }
    }

    Context 'AllowFileUrls passthrough' {
        It 'lets a file:// source pass when -AllowFileUrls is set' {
            $repoPath = Join-Path $script:iso.RepoRoot '.avm/config.json'
            $cfg = @'
{
  "schemaVersion": 1,
  "assets": {
    "fixture": {
      "source": "file:///tmp/fixture.tar.gz",
      "sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    }
  }
}
'@
            script:WriteJson -Path $repoPath -Json $cfg
            $repoRoot = $script:iso.RepoRoot
            $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $repoRoot } {
                param($P)
                Read-AvmAssetConfig -Path $P -AllowFileUrls
            }
            $result.Assets.Count | Should -Be 1
            $result.Assets['fixture'].Source | Should -Be 'file:///tmp/fixture.tar.gz'
        }
    }
}
