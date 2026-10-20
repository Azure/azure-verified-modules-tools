#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

Describe 'Repository-root required-provider map' {
    BeforeEach {
        $script:registry = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:moduleRoot = Join-Path $script:registry 'avm' 'res' 'example' 'module'
        $null = New-Item -ItemType Directory -Path $script:moduleRoot -Force
        $script:manifest = Join-Path $script:registry '.required-resource-providers.json'
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring { throw 'Manifest parsing must not contact Azure.' }
    }

    AfterEach { Should -Invoke Invoke-AvmProcess -ModuleName Avm.Authoring -Exactly 0 }

    It 'validates the entire map and selects only the exact module, never a parent or prefix' {
        Set-Content -LiteralPath $script:manifest -Value '{"avm/res/example/module":["Microsoft.Compute"],"avm/res/example/module/child":["Microsoft.Storage"],"avm/res/example/module-longer":["Microsoft.Network"]}'
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
            param($Root)
            foreach ($selection in @(
                    @{ Path = 'avm/res/example/module'; Expected = @('Microsoft.Compute') }
                    @{ Path = 'avm/res/example/module/child'; Expected = @('Microsoft.Storage') }
                    @{ Path = 'avm/res/example/module/other'; Expected = @() }
                )) {
                $entries = @(Read-AvmRequiredRegistration -Root $Root -ModulePath $selection.Path -Kind Provider)
                @($entries | ForEach-Object Namespace) | Should -Be $selection.Expected
            }
        }
    }

    It 'skips and logs <Case> without an Azure call' -ForEach @(
        @{ Case = 'absent map'; Json = $null }
        @{ Case = 'empty map'; Json = '{}' }
        @{ Case = 'empty selected list'; Json = '{"avm/res/example/module":[]}' }
        @{ Case = 'unrelated map'; Json = '{"avm/res/other/module":["Microsoft.Compute"]}' }
    ) {
        if ($null -ne $Json) { Set-Content -LiteralPath $script:manifest -Value $Json }
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
            param($Root)
            Mock Write-AvmLog {}
            @(Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/example/module' -Kind Provider).Count | Should -Be 0
            Should -Invoke Write-AvmLog -Exactly 1 -ParameterFilter { $Level -eq 'Info' -and $Message -like '*skipped*' }
        }
    }

    It 'ignores nested and underscore manifests instead of interpreting them as fallback maps' {
        Set-Content -LiteralPath (Join-Path $script:moduleRoot '.required-resource-providers.json') -Value '{invalid'
        Set-Content -LiteralPath (Join-Path $script:registry '.required_resource_providers.json') -Value '{invalid'
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleRoot } {
            param($Root)
            @(Get-AvmContextRequiredRegistration -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'bicep' }) -Kind Provider).Count |
                Should -Be 0
        }
    }

    It 'rejects invalid provider declarations before returning anything: <Case>' -ForEach @(
        @{ Case = 'array'; Json = '[]' }
        @{ Case = 'null'; Json = 'null' }
        @{ Case = 'broken JSON'; Json = '{' }
        @{ Case = 'comment'; Json = '{/* no comments */}' }
        @{ Case = 'trailing comma'; Json = '{"avm/res/example/module":[],}' }
        @{ Case = 'duplicate key'; Json = '{"avm/res/example/module":[],"avm/res/example/module":[]}' }
        @{ Case = 'escaped duplicate key'; Json = '{"avm/res/example/module":[],"\u0061vm/res/example/module":[]}' }
        @{ Case = 'upper-case module'; Json = '{"avm/res/Example/module":[]}' }
        @{ Case = 'absolute key'; Json = '{"/avm/res/example/module":[]}' }
        @{ Case = 'traversal key'; Json = '{"avm/res/example/../module":[]}' }
        @{ Case = 'backslash key'; Json = '{"avm\\res\\example\\module":[]}' }
        @{ Case = 'scalar list'; Json = '{"avm/res/example/module":"Microsoft.Compute"}' }
        @{ Case = 'null list'; Json = '{"avm/res/example/module":null}' }
        @{ Case = 'invalid unselected list'; Json = '{"avm/res/example/module":[],"avm/res/other/module":["invalid"]}' }
        @{ Case = 'null provider'; Json = '{"avm/res/example/module":[null]}' }
        @{ Case = 'number'; Json = '{"avm/res/example/module":[1]}' }
        @{ Case = 'object'; Json = '{"avm/res/example/module":[{}]}' }
        @{ Case = 'array provider'; Json = '{"avm/res/example/module":[["Microsoft.Compute"]]}' }
        @{ Case = 'feature entry'; Json = '{"avm/res/example/module":["Microsoft.Compute/Feature"]}' }
        @{ Case = 'case-duplicate namespace'; Json = '{"avm/res/example/module":["Microsoft.Compute","microsoft.compute"]}' }
        @{ Case = 'space'; Json = '{"avm/res/example/module":["Microsoft. Compute"]}' }
        @{ Case = 'command argument'; Json = '{"avm/res/example/module":["Microsoft.Compute;--consent"]}' }
        @{ Case = 'Unicode'; Json = '{"avm/res/example/module":["Microsoft.Comput\u00e9"]}' }
        @{ Case = 'empty namespace'; Json = '{"avm/res/example/module":[""]}' }
        @{ Case = 'missing namespace separator'; Json = '{"avm/res/example/module":["Compute"]}' }
        @{ Case = 'empty namespace segment'; Json = '{"avm/res/example/module":["Microsoft..Compute"]}' }
    ) {
        Set-Content -LiteralPath $script:manifest -Value $Json
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/example/module' -Kind Provider
            }
        } | Should -Throw
    }

    It 'rejects a <Case> manifest' -ForEach @(
        @{ Case = 'miscased'; Filename = '.Required-Resource-Providers.json'; Directory = $false }
        @{ Case = 'directory'; Filename = '.required-resource-providers.json'; Directory = $true }
    ) {
        $path = Join-Path $script:registry $Filename
        if ($Directory) { $null = New-Item -ItemType Directory -Path $path }
        else { Set-Content -LiteralPath $path -Value '{}' }
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/example/module' -Kind Provider
            }
        } | Should -Throw '*file named exactly*'
    }

    It 'enforces byte, list and namespace bounds: <Case>' -ForEach @(
        @{ Case = 'oversize manifest'; Count = 1; Length = 128; Padding = 65536; Valid = $false }
        @{ Case = '32 namespaces'; Count = 32; Length = 128; Padding = 0; Valid = $true }
        @{ Case = '33 namespaces'; Count = 33; Length = 128; Padding = 0; Valid = $false }
        @{ Case = '129 characters'; Count = 1; Length = 129; Padding = 0; Valid = $false }
    ) {
        $names = @(1..$Count | ForEach-Object { ('A.' + ('b' * $Length) + $_).Substring(0, $Length - 2) + $_.ToString('00') })
        Set-Content -LiteralPath $script:manifest -Value (
            (@{ 'avm/res/example/module' = $names } | ConvertTo-Json -Compress) + (' ' * $Padding))
        InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry; Valid = $Valid; Count = $Count } {
            param($Root, $Valid, $Count)
            if ($Valid) {
                @(Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/example/module' -Kind Provider).Count | Should -Be $Count
            }
            else {
                { Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/example/module' -Kind Provider } | Should -Throw
            }
        }
    }
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
                Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/compute/virtual-machine-scale-set'
            })
        $features.FullName | Should -Be @('Microsoft.Compute/EncryptionAtHost')
        $features[0].Namespace | Should -BeExactly 'Microsoft.Compute'
    }

    It 'returns nothing when the module has no entry' {
        Set-Content -LiteralPath $script:manifest -Value '{"avm/res/network/route-table":["Microsoft.Network/AllowRouteTable"]}'
        $features = @(InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/compute/virtual-machine-scale-set'
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
                Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/compute/virtual-machine-scale-set'
            }
        } | Should -Throw -ExpectedMessage $Message
    }

    It 'rejects a module path that is not an exact registry module directory' {
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/compute/../network'
            }
        } | Should -Throw -ExpectedMessage '*exact lowercase*'
    }

    It 'enforces the manifest size limit' {
        Set-Content -LiteralPath $script:manifest -Value ('{"avm/res/a/b":[]}' + (' ' * 65536))
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:registry } {
                param($Root)
                Read-AvmRequiredRegistration -Root $Root -ModulePath 'avm/res/a/b'
            }
        } | Should -Throw -ExpectedMessage '*64 KiB*'
    }

    It 'selects the repository map for a Bicep registry module context' {
        Set-Content -LiteralPath $script:manifest -Value '{"avm/res/compute/virtual-machine-scale-set":["Microsoft.Compute/EncryptionAtHost"]}'
        $features = @(InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleRoot } {
                param($Root)
                Get-AvmContextRequiredRegistration -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'bicep' })
            })
        $features.FullName | Should -Be @('Microsoft.Compute/EncryptionAtHost')
    }

    It 'refuses an ignored module-root manifest inside a Bicep registry checkout' {
        Set-Content -LiteralPath $script:manifest -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:moduleRoot '.required-features.json') -Value '["Microsoft.Compute/EncryptionAtHost"]'
        {
            InModuleScope Avm.Authoring -Parameters @{ Root = $script:moduleRoot } {
                param($Root)
                Get-AvmContextRequiredRegistration -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'bicep' })
            }
        } | Should -Throw -ExpectedMessage '*repository-root*'
    }

    It 'keeps the module-root array contract outside a Bicep registry checkout' {
        $standalone = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $standalone
        Set-Content -LiteralPath (Join-Path $standalone '.required-features.json') -Value '["Microsoft.Compute/EncryptionAtHost"]'
        $features = @(InModuleScope Avm.Authoring -Parameters @{ Root = $standalone } {
                param($Root)
                Get-AvmContextRequiredRegistration -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'bicep' })
            })
        $features.FullName | Should -Be @('Microsoft.Compute/EncryptionAtHost')
    }
}
