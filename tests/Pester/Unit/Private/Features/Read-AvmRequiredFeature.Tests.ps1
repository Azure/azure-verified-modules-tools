#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Repository-root required-feature map' {
    BeforeEach {
        $script:registry = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:moduleRoot = Join-Path $script:registry 'avm' 'res' 'compute' 'virtual-machine-scale-set'
        $null = New-Item -ItemType Directory -Path $script:moduleRoot -Force
        $script:manifest = Join-Path $script:registry '.required-features.json'
    }

    It 'returns only the exact module entry after validating the whole map' {
        Set-Content -LiteralPath $script:manifest -Value (@{
                'avm/res/compute/virtual-machine-scale-set' = @('Microsoft.Compute/EncryptionAtHost')
                'avm/res/network/route-table'               = @('Microsoft.Network/AllowRouteTable')
            } | ConvertTo-Json)
        $features = @(InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredFeature -Root $Root -ModulePath 'avm/res/compute/virtual-machine-scale-set'
            })
        $features.FullName | Should -Be @('Microsoft.Compute/EncryptionAtHost')
        $features[0].Namespace | Should -BeExactly 'Microsoft.Compute'
    }

    It 'returns nothing when the module has no entry' {
        Set-Content -LiteralPath $script:manifest -Value '{"avm/res/network/route-table":["Microsoft.Network/AllowRouteTable"]}'
        $features = @(InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredFeature -Root $Root -ModulePath 'avm/res/compute/virtual-machine-scale-set'
            })
        $features.Count | Should -Be 0
    }

    It 'rejects an invalid map before returning any entry (<Case>)' -ForEach @(
        @{ Case = 'array root'; Json = '["Microsoft.Compute/EncryptionAtHost"]'; Message = '*JSON object*' }
        @{ Case = 'duplicate module key'; Json = '{"avm/res/a/b":[],"avm/res/a/b":[]}'; Message = '*Duplicate module path*' }
        @{ Case = 'non-exact key'; Json = '{"avm/res/A/b":[]}'; Message = '*exact avm/res|ptn|utl*' }
        @{ Case = 'key outside avm'; Json = '{"modules/a/b":[]}'; Message = '*exact avm/res|ptn|utl*' }
        @{ Case = 'non-array value'; Json = '{"avm/res/a/b":"Microsoft.Compute/EncryptionAtHost"}'; Message = '*JSON array*' }
        @{ Case = 'invalid sibling entry'; Json = '{"avm/res/compute/virtual-machine-scale-set":[],"avm/res/a/b":["bad"]}'; Message = '*avm/res/a/b*' }
        @{ Case = 'duplicate feature'; Json = '{"avm/res/compute/virtual-machine-scale-set":["A.B/C","a.b/c"]}'; Message = '*Duplicate feature*' }
        @{ Case = 'non-string feature'; Json = '{"avm/res/compute/virtual-machine-scale-set":[1]}'; Message = '*must all be strings*' }
        @{ Case = 'broken JSON'; Json = '{'; Message = '*JSON object*' }
    ) {
        Set-Content -LiteralPath $script:manifest -Value $Json
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredFeature -Root $Root -ModulePath 'avm/res/compute/virtual-machine-scale-set'
            }
        } | Should -Throw -ExpectedMessage $Message
    }

    It 'rejects a module path that is not an exact registry module directory' {
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredFeature -Root $Root -ModulePath 'avm/res/compute/../network'
            }
        } | Should -Throw -ExpectedMessage '*exact lowercase*'
    }

    It 'enforces the manifest size limit' {
        Set-Content -LiteralPath $script:manifest -Value ('{"avm/res/a/b":[]}' + (' ' * 65536))
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredFeature -Root $Root -ModulePath 'avm/res/a/b'
            }
        } | Should -Throw -ExpectedMessage '*64 KiB*'
    }

    It 'selects the repository map for a Bicep registry module context' {
        Set-Content -LiteralPath $script:manifest -Value '{"avm/res/compute/virtual-machine-scale-set":["Microsoft.Compute/EncryptionAtHost"]}'
        $features = @(InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleRoot } {
                param($Root)
                Get-AvmContextRequiredFeature -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'bicep' })
            })
        $features.FullName | Should -Be @('Microsoft.Compute/EncryptionAtHost')
    }

    It 'refuses an ignored module-root manifest inside a Bicep registry checkout' {
        Set-Content -LiteralPath $script:manifest -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:moduleRoot '.required-features.json') -Value '["Microsoft.Compute/EncryptionAtHost"]'
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleRoot } {
                param($Root)
                Get-AvmContextRequiredFeature -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'bicep' })
            }
        } | Should -Throw -ExpectedMessage '*repository-root*'
    }

    It 'keeps the module-root array contract outside a Bicep registry checkout' {
        $standalone = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $standalone
        Set-Content -LiteralPath (Join-Path $standalone '.required-features.json') -Value '["Microsoft.Compute/EncryptionAtHost"]'
        $features = @(InModuleScope Avm.Authoring -Parameters @{ Root = $standalone } {
                param($Root)
                Get-AvmContextRequiredFeature -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'bicep' })
            })
        $features.FullName | Should -Be @('Microsoft.Compute/EncryptionAtHost')
    }
}
