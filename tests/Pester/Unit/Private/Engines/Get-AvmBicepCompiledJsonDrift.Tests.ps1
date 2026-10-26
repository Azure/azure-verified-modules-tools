#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepCompiledJsonDrift' {
    BeforeEach {
        $script:compiled = '{"metadata":{"_generator":{"name":"bicep","version":"0.48.1.52935","templateHash":"987654321"}},"resources":[]}'
    }

    It 'classifies an absent artifact as missing' {
        InModuleScope 'Avm.Authoring' {
            Get-AvmBicepCompiledJsonDrift -CompiledJson '{}' -CurrentBytes $null |
                Should -Be 'missing'
        }
    }

    It 'accepts only byte-identical output' {
        InModuleScope 'Avm.Authoring' {
            $compiled = "{}`n"
            $current = [System.Text.UTF8Encoding]::new($false).GetBytes($compiled)
            Get-AvmBicepCompiledJsonDrift -CompiledJson $compiled -CurrentBytes $current |
                Should -BeNullOrEmpty
        }
    }

    It 'detects newline and BOM drift even when the JSON values are identical' {
        InModuleScope 'Avm.Authoring' {
            $compiled = "{}`n"
            $newlineDrift = [System.Text.UTF8Encoding]::new($false).GetBytes("{}`r`n")
            $bomDrift = [System.Text.UTF8Encoding]::new($true).GetPreamble() +
                [System.Text.UTF8Encoding]::new($false).GetBytes($compiled)
            Get-AvmBicepCompiledJsonDrift -CompiledJson $compiled -CurrentBytes $newlineDrift |
                Should -Be 'stale'
            Get-AvmBicepCompiledJsonDrift -CompiledJson $compiled -CurrentBytes $bomDrift |
                Should -Be 'stale'
        }
    }

    It 'ignores only the two root generator string values, including escaped token contents' -ForEach @(
        @{ Version = '0.47.16.16243'; Hash = '18275710714278981656' }
        @{ Version = '0.47\u002e16\"quoted\\value'; Hash = 'hash\"with\\escapes' }
    ) {
        $current = $script:compiled.Replace('0.48.1.52935', $Version).Replace('987654321', $Hash)
        InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $script:compiled; Current = $current } {
            param($Compiled, $Current)
            Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Current)) |
                Should -BeNullOrEmpty
        }
    }

    It 'preserves all other byte differences: <Case>' -ForEach @(
        @{ Case = 'resource'; Tail = ',"resources":[{}]'; Generator = ''; Metadata = '' }
        @{ Case = 'unknown generator field'; Tail = ',"resources":[]'; Generator = ',"extra":"changed"'; Metadata = '' }
        @{ Case = 'generator name'; Tail = ',"resources":[]'; Generator = ',"name":"changed"'; Metadata = ''; OmitName = $true }
        @{ Case = 'sibling version'; Tail = ',"version":"changed","resources":[]'; Generator = ''; Metadata = '' }
        @{ Case = 'metadata hash'; Tail = ',"resources":[]'; Generator = ''; Metadata = ',"templateHash":"changed"' }
        @{ Case = 'nested generator'; Tail = ',"nested":{"metadata":{"_generator":{"version":"changed","templateHash":"changed"}}},"resources":[]'; Generator = ''; Metadata = '' }
        @{ Case = 'array generator'; Tail = ',"resources":[{"metadata":{"_generator":{"version":"changed","templateHash":"changed"}}}]'; Generator = ''; Metadata = '' }
    ) {
        $name = if ($Case -ceq 'generator name') { '' } else { '"name":"bicep",' }
        $current = '{"metadata":{"_generator":{' + $name + '"version":"0.47.16.16243","templateHash":"old"' +
            $Generator + '}' + $Metadata + '}' + $Tail + '}'
        InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $script:compiled; Current = $current } {
            param($Compiled, $Current)
            Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Current)) |
                Should -Be 'stale'
        }
    }

    It 'locates provenance after Unicode, escaped names, decoy strings and nested objects without changing them' {
        $compiled = ' {"decoy":{"metadata":{"_generator":{"version":"keep","templateHash":"keep"}}},' +
            '"text":"\u00e9 \"metadata\": { \"_generator\": {} }","metadata":{"\u005fgenerator":{' +
            '"templateHash":"987654321","unknown":{"version":"keep"},"version":"0.48.1.52935"}}} '
        $compiled = $compiled.Replace('\u00e9', [string][char]0xE9)
        $current = $compiled.Replace('0.48.1.52935', '0.47.16.16243').Replace('987654321', 'old')
        InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $compiled; Current = $current } {
            param($Compiled, $Current)
            Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Current)) |
                Should -BeNullOrEmpty
            $changed = $Current.Replace('"keep"', '"changed"')
            Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($changed)) |
                Should -Be 'stale'
        }
    }

    It 'preserves formatting, casing, key order and encoding when provenance also changes: <Case>' -ForEach @(
        @{ Case = 'whitespace'; Find = ',"resources"'; Replace = ', "resources"' }
        @{ Case = 'key order'; Find = '"name":"bicep","version":"0.48.1.52935"'; Replace = '"version":"0.48.1.52935","name":"bicep"' }
        @{ Case = 'escaped property name'; Find = '"version"'; Replace = '"\u0076ersion"' }
        @{ Case = 'path casing'; Find = '"metadata"'; Replace = '"Metadata"' }
        @{ Case = 'CRLF'; Find = '}'; Replace = "}`r`n" }
        @{ Case = 'BOM'; Find = '{"metadata"'; Replace = ([string][char]0xFEFF + '{"metadata"') }
    ) {
        $current = $script:compiled.Replace($Find, $Replace).Replace('987654321', 'old')
        InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $script:compiled; Current = $current } {
            param($Compiled, $Current)
            Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Current)) |
                Should -Be 'stale'
        }
    }

    It 'rejects invalid or ambiguous input on either side: <Case>' -ForEach @(
        @{ Case = 'malformed'; Json = '{invalid' }
        @{ Case = 'trailing comma'; Json = '{"metadata":{},}' }
        @{ Case = 'comment'; Json = '{/*comment*/}' }
        @{ Case = 'scalar'; Json = '"value"' }
        @{ Case = 'duplicate ancestor'; Json = '{"metadata":{},"metadata":{}}' }
        @{ Case = 'escaped duplicate'; Json = '{"metadata":{},"\u006detadata":{}}' }
        @{ Case = 'nested duplicate'; Json = '{"resources":[{"x":1,"x":2}]}' }
        @{ Case = 'duplicate version'; Json = '{"metadata":{"_generator":{"version":"a","version":"b","templateHash":"c"}}}' }
        @{ Case = 'duplicate generator'; Json = '{"metadata":{"_generator":{},"_generator":{}}}' }
        @{ Case = 'missing version'; Json = '{"metadata":{"_generator":{"templateHash":"c"}}}' }
        @{ Case = 'missing hash'; Json = '{"metadata":{"_generator":{"version":"a"}}}' }
        @{ Case = 'null version'; Json = '{"metadata":{"_generator":{"version":null,"templateHash":"c"}}}' }
        @{ Case = 'numeric hash'; Json = '{"metadata":{"_generator":{"version":"a","templateHash":123}}}' }
        @{ Case = 'empty version'; Json = '{"metadata":{"_generator":{"version":"","templateHash":"c"}}}' }
        @{ Case = 'object generator'; Json = '{"metadata":{"_generator":[]}}' }
    ) {
        InModuleScope 'Avm.Authoring' -Parameters @{ Invalid = $Json } {
            param($Invalid)
            { Get-AvmBicepCompiledJsonDrift -CompiledJson '{}' -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Invalid)) } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Checked-in main.json*'
            { Get-AvmBicepCompiledJsonDrift -CompiledJson $Invalid -CurrentBytes ([Text.Encoding]::UTF8.GetBytes('{}')) } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Bicep compiler output*'
        }
    }

    It 'does not synthesize absent provenance and rejects invalid UTF-8' {
        InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $script:compiled } {
            param($Compiled)
            Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes('{"resources":[]}')) |
                Should -Be 'stale'
            { Get-AvmBicepCompiledJsonDrift -CompiledJson '{}' -CurrentBytes ([byte[]]@(0xFF)) } |
                Should -Throw '*valid UTF-8*'
        }
    }
}
