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

    It 'retains root generator validation and masking regardless of its name' {
        $compiled = $script:compiled.Replace('"bicep"', '"FinOps toolkit"')
        InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $compiled } {
            param($Compiled)
            $current = $Compiled.Replace('987654321', 'old')
            Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($current)) |
                Should -BeNullOrEmpty
            $invalid = $Compiled.Replace(',"templateHash":"987654321"', '')
            { Get-AvmBicepCompiledJsonDrift -CompiledJson $invalid -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($invalid)) } |
                Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*requires version and templateHash*'
        }
    }

    Context 'nested deployment templates' {
        BeforeEach {
            $script:nestedCompiled = @'
{
  "languageVersion": "2.0",
  "metadata": {"_generator": {"name": "bicep", "version": "current-root", "templateHash": "root-hash"}},
  "resources": {
    "registry_scopeMaps": {
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2025-04-01",
      "name": "scopeMaps",
      "properties": {
        "expressionEvaluationOptions": {"scope": "inner"},
        "mode": "Incremental",
        "template": {
          "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
          "contentVersion": "1.0.0.0",
          "metadata": {"_generator": {"name": "bicep", "version": "current-local", "templateHash": "local-hash"}},
          "resources": [
            {"type": "Microsoft.ContainerRegistry/registries/scopeMaps", "name": "child-resource"},
            {
              "type": "Microsoft.Resources/deployments",
              "properties": {
                "template": {
                  "metadata": {"_generator": {"name": "bicep", "version": "current-leaf", "templateHash": "leaf-hash"}},
                  "resources": [],
                  "outputs": {"result": {"type": "string", "value": "unchanged-output"}}
                }
              }
            }
          ]
        }
      }
    },
    "withoutProvenance": {
      "type": "Microsoft.Resources/deployments",
      "properties": {"template": {"metadata": {}, "resources": []}}
    },
    "publishedModule": {
      "type": "Microsoft.Resources/deployments",
      "properties": {"template": {
        "metadata": {"_generator": {"name": "bicep", "version": "0.41.2.15936", "templateHash": "published-hash"}},
        "resources": []
      }}
    }
  }
}
'@
        }

        It 'ignores provenance through two levels and mixed resource collections: <Layout>' -ForEach @(
            @{ Layout = 'symbolic root, array child' }
            @{ Layout = 'array root, symbolic child' }
        ) {
            $compiled = $script:nestedCompiled
            if ($Layout -eq 'array root, symbolic child') {
                $template = $compiled | ConvertFrom-Json -AsHashtable
                $children = $template.resources.registry_scopeMaps.properties.template.resources
                $template.resources.registry_scopeMaps.properties.template.resources = [ordered]@{
                    scopeMap = $children[0]
                    nested   = $children[1]
                }
                $template.resources = @($template.resources.Values)
                $compiled = $template | ConvertTo-Json -Depth 100
            }
            $current = $compiled.Replace('current-root', 'old-root').Replace('root-hash', 'old-root-hash').
            Replace('current-local', '0.47.16.16243').Replace('local-hash', 'old-local-hash').
            Replace('current-leaf', 'old-leaf').Replace('leaf-hash', 'old-leaf-hash')
            InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $compiled; Current = $current } {
                param($Compiled, $Current)
                Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Current)) |
                    Should -BeNullOrEmpty
            }
        }

        It 'continues into children when ancestor provenance is absent: <Metadata>' -ForEach @(
            @{ Metadata = '' }
            @{ Metadata = '"metadata": {},' }
        ) {
            $compiled = '{' + $Metadata + '"resources":{"child":{"type":"Microsoft.Resources/deployments",' +
            '"properties":{"template":' + $script:compiled + '}}}}'
            $current = $compiled.Replace('987654321', 'old')
            InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $compiled; Current = $current } {
                param($Compiled, $Current)
                Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Current)) |
                    Should -BeNullOrEmpty
            }
        }

        It 'preserves nested non-provenance bytes: <Case>' -ForEach @(
            @{ Case = 'resource'; Find = 'child-resource'; Replace = 'changed-resource' }
            @{ Case = 'depth-two output'; Find = 'unchanged-output'; Replace = 'changed-output' }
            @{ Case = 'unknown generator field'; Find = '"templateHash": "local-hash"'; Replace = '"templateHash": "local-hash", "extra": "changed"' }
            @{ Case = 'generator name'; Find = '"name": "bicep", "version": "current-local"'; Replace = '"name": "other", "version": "current-local"' }
            @{ Case = 'whitespace'; Find = '"version": "current-local"'; Replace = '"version" : "current-local"' }
            @{ Case = 'key order'; Find = '"name": "bicep", "version": "current-local"'; Replace = '"version": "current-local", "name": "bicep"' }
            @{ Case = 'escaped key'; Find = '"version": "current-local"'; Replace = '"\u0076ersion": "current-local"' }
        ) {
            $current = $script:nestedCompiled.Replace($Find, $Replace).Replace('current-local', 'old-local')
            InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $script:nestedCompiled; Current = $current } {
                param($Compiled, $Current)
                Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Current)) |
                    Should -Be 'stale'
            }
        }

        It 'does not mask template-shaped data outside exact deployment paths: <Case>' -ForEach @(
            @{ Case = 'other type'; Prefix = '{"resources":[{"type":"Contoso/widgets","properties":{"template":'; Suffix = '}}]}' }
            @{ Case = 'type casing'; Prefix = '{"resources":[{"type":"microsoft.resources/deployments","properties":{"template":'; Suffix = '}}]}' }
            @{ Case = 'computed type'; Prefix = '{"resources":[{"type":"[variables(''type'')]","properties":{"template":'; Suffix = '}}]}' }
            @{ Case = 'missing type'; Prefix = '{"resources":[{"properties":{"template":'; Suffix = '}}]}' }
            @{ Case = 'resource metadata'; Prefix = '{"resources":[{"type":"Microsoft.Resources/deployments","metadata":'; Suffix = '}]}' }
            @{ Case = 'template casing'; Prefix = '{"resources":[{"type":"Microsoft.Resources/deployments","properties":{"Template":'; Suffix = '}}]}' }
            @{ Case = 'parameter default'; Prefix = '{"parameters":{"input":{"defaultValue":'; Suffix = '}}}' }
            @{ Case = 'deployment parameters'; Prefix = '{"resources":[{"type":"Microsoft.Resources/deployments","properties":{"parameters":{"input":{"value":'; Suffix = '}}}}]}' }
            @{ Case = 'variables'; Prefix = '{"variables":{"template":'; Suffix = '}}' }
            @{ Case = 'templateLink'; Prefix = '{"resources":[{"type":"Microsoft.Resources/deployments","properties":{"templateLink":'; Suffix = '}}]}' }
        ) {
            $compiled = $Prefix + $script:compiled + $Suffix
            $current = $compiled.Replace('987654321', 'old')
            InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $compiled; Current = $current } {
                param($Compiled, $Current)
                Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Current)) |
                    Should -Be 'stale'
            }
        }

        It 'preserves non-object nested templates and their referenced variables: <Case>' -ForEach @(
            @{ Case = 'expression'; Template = '"[variables(''$fxv#0'')]"'; ChangedTemplate = '"[variables(''$fxv#1'')]"' }
            @{ Case = 'array'; Template = '[]'; ChangedTemplate = '[{}]' }
        ) {
            $compiled = '{"variables":{"$fxv#0":{"resources":[]}},"resources":[{"type":"Microsoft.Resources/deployments",' +
            '"properties":{"template":' + $Template + '}}]}'
            InModuleScope 'Avm.Authoring' -Parameters @{
                Compiled        = $compiled
                ChangedTemplate = $compiled.Replace('"template":' + $Template, '"template":' + $ChangedTemplate)
            } {
                param($Compiled, $ChangedTemplate)
                Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Compiled)) |
                    Should -BeNullOrEmpty
                $changedVariable = $Compiled.Replace('"resources":[]', '"resources":[{}]')
                Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($changedVariable)) |
                    Should -Be 'stale'
                Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($ChangedTemplate)) |
                    Should -Be 'stale'
            }
        }

        It 'preserves explicitly non-Bicep nested generator metadata: <Name>' -ForEach @(
            @{ Name = 'FinOps toolkit' }
            @{ Name = 'Bicep' }
        ) {
            $compiled = '{"resources":{"defaultTelemetry":{"type":"Microsoft.Resources/deployments","properties":{' +
            '"template":{"metadata":{"_generator":{"name":"' + $Name + '","version":"0.3"}},"resources":[]}}}}}'
            InModuleScope 'Avm.Authoring' -Parameters @{ Compiled = $compiled } {
                param($Compiled)
                Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Compiled)) |
                    Should -BeNullOrEmpty
                $changed = $Compiled.Replace('"0.3"', '"0.4"')
                Get-AvmBicepCompiledJsonDrift -CompiledJson $Compiled -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($changed)) |
                    Should -Be 'stale'
            }
        }

        It 'rejects malformed present nested provenance on either side: <Case>' -ForEach @(
            @{ Case = 'metadata array'; Template = '{"metadata":[]}' }
            @{ Case = 'generator array'; Template = '{"metadata":{"_generator":[]}}' }
            @{ Case = 'missing hash'; Template = '{"metadata":{"_generator":{"version":"old"}}}' }
            @{ Case = 'Bicep missing hash'; Template = '{"metadata":{"_generator":{"name":"bicep","version":"old"}}}' }
            @{ Case = 'null version'; Template = '{"metadata":{"_generator":{"version":null,"templateHash":"hash"}}}' }
            @{ Case = 'empty hash'; Template = '{"metadata":{"_generator":{"version":"old","templateHash":""}}}' }
            @{ Case = 'duplicate version'; Template = '{"metadata":{"_generator":{"version":"old","version":"new","templateHash":"hash"}}}' }
        ) {
            $invalid = '{"resources":{"child":{"type":"Microsoft.Resources/deployments","properties":{"template":' + $Template + '}}}}'
            InModuleScope 'Avm.Authoring' -Parameters @{ Invalid = $invalid } {
                param($Invalid)
                { Get-AvmBicepCompiledJsonDrift -CompiledJson '{}' -CurrentBytes ([Text.Encoding]::UTF8.GetBytes($Invalid)) } |
                    Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Checked-in main.json*'
                { Get-AvmBicepCompiledJsonDrift -CompiledJson $Invalid -CurrentBytes ([Text.Encoding]::UTF8.GetBytes('{}')) } |
                    Should -Throw -ExceptionType ([AvmConfigurationException]) -ExpectedMessage '*Bicep compiler output*'
            }
        }
    }
}
