#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Integration: module metadata native readers' -Tag Integration -Skip:($env:AVM_OFFLINE -eq '1') {
    BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
        Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
        $script:originalMetadataAvmHome = $env:AVM_HOME
        $env:AVM_HOME = Join-Path $TestDrive 'native-tools'
        $script:schemaId = (Get-Content -LiteralPath (
                Join-Path $moduleRoot 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json'
            ) -Raw | ConvertFrom-Json).'$id'
        $script:metadataTools = InModuleScope Avm.Authoring {
            @{
                bicep     = (Resolve-AvmTool -Name bicep).Path
                terraform = (Resolve-AvmTool -Name terraform).Path
            }
        }

        function Invoke-MetadataNativeTool {
            param([string] $Tool, [string] $Root, [string[]] $Arguments)
            $result = InModuleScope Avm.Authoring -Parameters @{
                ToolPath = $script:metadataTools[$Tool]
                Root     = $Root
                Argv     = $Arguments
            } {
                param($ToolPath, $Root, $Argv)
                Invoke-AvmProcess -FilePath $ToolPath -ArgumentList $Argv -WorkingDirectory $Root `
                    -EnvVars @{ CHECKPOINT_DISABLE = '1' } -IgnoreExitCode
            }
            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            return $result.StdOut
        }

        function New-NativeMetadataSeed {
            param([string] $Ecosystem, [switch] $ChildModule)
            $marker = if ($Ecosystem -eq 'bicep') { '46d3xbcp' } else { '46d3xtrf' }
            $seed = [ordered]@{
                '$schema'         = $script:schemaId
                schemaVersion     = 1
                moduleDisplayName = 'Storage Accounts'
                moduleDescription = 'Deploys a Storage Account.'
                canonicalType     = 'Microsoft.Storage/storageAccounts'
                telemetryIdPrefix = "$marker.res.storage-storageaccount"
            }
            if ($ChildModule) {
                $seed.canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
                $seed.telemetryIdPrefix = "$marker.res.storage-blobservice"
            }
            else {
                $seed.tier = 'maintained'
                $seed.owners = @{ individuals = @(@{ githubHandle = 'original-owner' }) }
            }
            return $seed
        }

        function Get-NativeBicepTelemetryPrefix {
            param($Template)
            $value = $Template.variables.avmTelemetryIdPrefix
            $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            while ($value -is [string]) {
                $reference = [regex]::Match($value, "^\[variables\('([^']+)'\)\]$")
                if (-not $reference.Success) {
                    break
                }
                $name = $reference.Groups[1].Value
                if (-not $visited.Add($name) -or -not $Template.variables.PSObject.Properties[$name]) {
                    throw "Unresolvable compiled telemetry prefix reference: $name"
                }
                $value = $Template.variables.PSObject.Properties[$name].Value
            }
            return $value
        }
    }

    AfterAll {
        if ($null -eq $script:originalMetadataAvmHome) {
            Remove-Item Env:AVM_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:AVM_HOME = $script:originalMetadataAvmHome
        }
        Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
    }

    It 'keeps compiled ARM byte-identical after owner, tier, and canonical edits' {
        $root = Join-Path $TestDrive 'bicep-native'
        $null = New-Item -ItemType Directory -Path $root
        $sourcePath = Join-Path $root 'main.bicep'
        $source = @'
metadata name = 'Storage Accounts'
metadata description = 'Deploys a Storage Account.'

param enableTelemetry bool = true
param location string = resourceGroup().location

resource avmTelemetry 'Microsoft.Resources/deployments@2025-04-01' = if (enableTelemetry) {
  name: '46d3xbcp.res.storage-storageaccount.${replace('-..--..-', '.', '-')}.${substring(uniqueString(deployment().name, location), 0, 4)}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: []
    }
  }
}
'@
        [System.IO.File]::WriteAllText($sourcePath, $source)
        $seed = New-NativeMetadataSeed -Ecosystem bicep
        $null = Initialize-AvmModuleMetadata -Path $root -InputObject $seed `
            -Ecosystem bicep -ModuleType resource -UpdateSource -SkipModuleVersionCheck
        $before = Invoke-MetadataNativeTool -Tool bicep -Root $root -Arguments @('build', '--stdout', $sourcePath)
        $template = $before | ConvertFrom-Json
        Get-NativeBicepTelemetryPrefix -Template $template | Should -BeExactly $seed.telemetryIdPrefix

        $seed.owners = @{
            individuals = @(
                @{ githubHandle = 'first-owner' }
                @{ githubHandle = 'second-owner' }
                @{ githubHandle = 'third-owner' }
                @{ githubHandle = 'fourth-owner' }
            )
        }
        $seed.tier = 'core'
        $seed.canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
        $seed.comments = 'Catalog-only change.'
        $metadataPath = Join-Path $root 'metadata.json'
        [System.IO.File]::WriteAllText($metadataPath, ($seed | ConvertTo-Json -Depth 20))
        $after = Invoke-MetadataNativeTool -Tool bicep -Root $root -Arguments @('build', '--stdout', $sourcePath)
        $after | Should -BeExactly $before
        $after | Should -Not -Match 'fourth-owner|Catalog-only'

        $seed.telemetryIdPrefix += '-v2'
        [System.IO.File]::WriteAllText($metadataPath, ($seed | ConvertTo-Json -Depth 20))
        $changed = Invoke-MetadataNativeTool -Tool bicep -Root $root -Arguments @('build', '--stdout', $sourcePath)
        $changed | Should -Not -BeExactly $before
        Get-NativeBicepTelemetryPrefix -Template ($changed | ConvertFrom-Json) | Should -BeExactly $seed.telemetryIdPrefix
    }

    It 'evaluates root and inherited child metadata in a provider-free Terraform plan' {
        $root = Join-Path $TestDrive 'terraform-native'
        $child = Join-Path $root 'modules' 'child'
        $null = New-Item -ItemType Directory -Path $child -Force
        $rootSource = @'
module "child" {
  source = "./modules/child"
}

output "canonical" {
  value = local.avm_canonical_type
}
output "prefix" {
  value = local.avm_telemetry_id_prefix
}
output "inherited_tier" {
  value = module.child.tier
}
output "child_prefix" {
  value = module.child.prefix
}
'@
        $childSource = @'
output "tier" {
  value = local.avm_tier
}
output "prefix" {
  value = local.avm_telemetry_id_prefix
}
'@
        [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), $rootSource)
        [System.IO.File]::WriteAllText((Join-Path $child 'main.tf'), $childSource)
        $seed = New-NativeMetadataSeed -Ecosystem terraform
        $seed.tier = 'core'
        $childSeed = New-NativeMetadataSeed -Ecosystem terraform -ChildModule
        $null = Initialize-AvmModuleMetadata -Path $root -InputObject $seed `
            -Ecosystem terraform -ModuleType resource -UpdateSource -SkipModuleVersionCheck
        $null = Initialize-AvmModuleMetadata -Path $child -InputObject $childSeed `
            -Ecosystem terraform -ModuleType resource -ChildModule -UpdateSource -SkipModuleVersionCheck
        $null = Invoke-MetadataNativeTool -Tool terraform -Root $root `
            -Arguments @('init', '-backend=false', '-input=false', '-no-color')
        $planPath = Join-Path $root 'metadata.tfplan'
        $null = Invoke-MetadataNativeTool -Tool terraform -Root $root `
            -Arguments @('plan', '-refresh=false', '-input=false', '-lock=false', '-no-color', "-out=$planPath")
        $plan = (Invoke-MetadataNativeTool -Tool terraform -Root $root `
                -Arguments @('show', '-json', $planPath)) | ConvertFrom-Json
        $outputs = $plan.planned_values.outputs
        $outputs.canonical.value | Should -BeExactly $seed.canonicalType
        $outputs.prefix.value | Should -BeExactly $seed.telemetryIdPrefix
        $outputs.inherited_tier.value | Should -BeExactly 'core'
        $outputs.child_prefix.value | Should -BeExactly $childSeed.telemetryIdPrefix
        $plan.PSObject.Properties.Name | Should -Not -Contain 'resource_changes'
    }
}
