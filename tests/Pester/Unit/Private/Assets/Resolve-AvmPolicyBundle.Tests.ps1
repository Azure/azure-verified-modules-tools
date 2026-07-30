#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force

    $script:originalRef = $env:AVM_POLICY_LIBRARY_REF
    $script:originalSha = $env:AVM_POLICY_LIBRARY_SHA256
    Remove-Item Env:\AVM_POLICY_LIBRARY_REF -ErrorAction SilentlyContinue
    Remove-Item Env:\AVM_POLICY_LIBRARY_SHA256 -ErrorAction SilentlyContinue
}

AfterAll {
    if ($null -eq $script:originalRef) { Remove-Item Env:\AVM_POLICY_LIBRARY_REF -ErrorAction SilentlyContinue }
    else { $env:AVM_POLICY_LIBRARY_REF = $script:originalRef }
    if ($null -eq $script:originalSha) { Remove-Item Env:\AVM_POLICY_LIBRARY_SHA256 -ErrorAction SilentlyContinue }
    else { $env:AVM_POLICY_LIBRARY_SHA256 = $script:originalSha }
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-AvmPolicyBundle' {
    BeforeEach {
        Remove-Item Env:\AVM_POLICY_LIBRARY_REF -ErrorAction SilentlyContinue
        Remove-Item Env:\AVM_POLICY_LIBRARY_SHA256 -ErrorAction SilentlyContinue

        $script:pins = @{
            schemaVersion = 1
            tools         = @()
            policyLibrary = @{
                repository  = 'Azure/policy-library-avm'
                ref         = 'v1.2.3'
                urlTemplate = 'https://github.com/{repository}/archive/refs/tags/{ref}.tar.gz'
                sha256      = ('c' * 64)
                archiveRoot = 'policy-library-avm-{version}'
                bundles     = @{
                    'avm-policy-aprl'   = 'policy/Azure-Proactive-Resiliency-Library-v2'
                    'avm-policy-avmsec' = 'policy/avmsec'
                }
            }
        }
    }

    It 'expands the url template and composes the archive-root sub-path' {
        $asset = InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:pins } {
            param($P)
            $captured = $null
            Mock Resolve-AvmPinnedAsset { param($Name, $Asset) $script:captured = $Asset; [pscustomobject]@{ Path = '/x' } }
            $null = Resolve-AvmPolicyBundle -Name 'avm-policy-aprl' -Pins $P
            $script:captured
        }
        $asset.Source | Should -Be 'https://github.com/Azure/policy-library-avm/archive/refs/tags/v1.2.3.tar.gz'
        $asset.Ref    | Should -Be 'v1.2.3'
        $asset.Sha256 | Should -Be ('c' * 64)
        $asset.Type   | Should -Be 'archive'
        $asset.Path   | Should -Be 'policy-library-avm-1.2.3/policy/Azure-Proactive-Resiliency-Library-v2'
    }

    It 'composes a distinct sub-path per bundle' {
        $asset = InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:pins } {
            param($P)
            Mock Resolve-AvmPinnedAsset { param($Name, $Asset) $script:captured = $Asset; [pscustomobject]@{ Path = '/x' } }
            $null = Resolve-AvmPolicyBundle -Name 'avm-policy-avmsec' -Pins $P
            $script:captured
        }
        $asset.Path | Should -Be 'policy-library-avm-1.2.3/policy/avmsec'
    }

    It 'throws for an unknown bundle name' {
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:pins } {
                param($P)
                Mock Resolve-AvmPinnedAsset { throw 'should not be called' }
                Resolve-AvmPolicyBundle -Name 'avm-policy-nope' -Pins $P
            }
        } | Should -Throw -ExpectedMessage '*avm-policy-nope*'
    }

    It 'throws when the pin manifest has no policyLibrary section' {
        {
            InModuleScope 'Avm.Authoring' {
                Mock Resolve-AvmPinnedAsset { throw 'should not be called' }
                Resolve-AvmPolicyBundle -Name 'avm-policy-aprl' -Pins @{ schemaVersion = 1; tools = @() }
            }
        } | Should -Throw -ExpectedMessage '*policyLibrary*'
    }

    It 'honours a paired ref and sha256 override' {
        $env:AVM_POLICY_LIBRARY_REF = 'v9.9.9-rc1'
        $env:AVM_POLICY_LIBRARY_SHA256 = ('d' * 64)
        $asset = InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:pins } {
            param($P)
            Mock Resolve-AvmPinnedAsset { param($Name, $Asset) $script:captured = $Asset; [pscustomobject]@{ Path = '/x' } }
            $null = Resolve-AvmPolicyBundle -Name 'avm-policy-aprl' -Pins $P
            $script:captured
        }
        $asset.Ref    | Should -Be 'v9.9.9-rc1'
        $asset.Sha256 | Should -Be ('d' * 64)
        $asset.Source | Should -Be 'https://github.com/Azure/policy-library-avm/archive/refs/tags/v9.9.9-rc1.tar.gz'
        $asset.Path   | Should -Be 'policy-library-avm-9.9.9-rc1/policy/Azure-Proactive-Resiliency-Library-v2'
    }

    It 'rejects a ref override without a sha256 override' {
        $env:AVM_POLICY_LIBRARY_REF = 'v9.9.9-rc1'
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:pins } {
                param($P)
                Mock Resolve-AvmPinnedAsset { throw 'should not be called' }
                Resolve-AvmPolicyBundle -Name 'avm-policy-aprl' -Pins $P
            }
        } | Should -Throw -ExpectedMessage '*AVM_POLICY_LIBRARY_SHA256*'
    }

    It 'rejects a sha256 override without a ref override' {
        $env:AVM_POLICY_LIBRARY_SHA256 = ('d' * 64)
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ P = $script:pins } {
                param($P)
                Mock Resolve-AvmPinnedAsset { throw 'should not be called' }
                Resolve-AvmPolicyBundle -Name 'avm-policy-aprl' -Pins $P
            }
        } | Should -Throw -ExpectedMessage '*AVM_POLICY_LIBRARY_REF*'
    }

    It 'resolves both shipped bundle names from the real pin manifest' {
        foreach ($name in @('avm-policy-aprl', 'avm-policy-avmsec')) {
            $asset = InModuleScope 'Avm.Authoring' -Parameters @{ N = $name } {
                param($N)
                Mock Resolve-AvmPinnedAsset { param($Name, $Asset) $script:captured = $Asset; [pscustomobject]@{ Path = '/x' } }
                $null = Resolve-AvmPolicyBundle -Name $N
                $script:captured
            }
            $asset.Source | Should -Match '^https://github\.com/Azure/policy-library-avm/archive/refs/tags/v'
            $asset.Sha256 | Should -Match '^[0-9a-f]{64}$'
            $asset.Path   | Should -Match '^policy-library-avm-[0-9][^/]*/policy/'
        }
    }
}
