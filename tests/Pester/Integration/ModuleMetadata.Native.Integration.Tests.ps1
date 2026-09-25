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
            $rootId = if ($Ecosystem -eq 'bicep') { 'storage-storageaccount' } else { 'a1b2c3d' }
            $seed = [ordered]@{
                '$schema'         = $script:schemaId
                moduleDisplayName = 'Storage Accounts'
                moduleDescription = 'Deploys a Storage Account.'
                canonicalType     = 'Microsoft.Storage/storageAccounts'
                telemetryIdPrefix = "$marker.res.$rootId"
            }
            if ($ChildModule) {
                $seed.canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
                $childId = if ($Ecosystem -eq 'bicep') { 'storage-blobservice' } else { 'c4d5e6f' }
                $seed.telemetryIdPrefix = "$marker.res.$childId"
            }
            else {
                $seed.owners = @('original-owner')
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

    It 'keeps compiled ARM byte-identical after owner and canonical edits' {
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

        $seed.owners = @('first-owner', '@Azure/team-one', 'second-owner', 'third-owner', '@Azure/team-two', 'fourth-owner')
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

    It 'keeps a provider-free Terraform plan unchanged without generating metadata readers' {
        $root = Join-Path $TestDrive 'terraform-native'
        $child = Join-Path $root 'modules' 'child'
        $null = New-Item -ItemType Directory -Path $child -Force
        $rootSource = @'
module "child" {
  source = "./modules/child"
}

output "source_value" {
  value = "root-source"
}
output "child_value" {
  value = module.child.source_value
}
'@
        $childSource = @'
output "source_value" {
  value = "child-source"
}
'@
        [System.IO.File]::WriteAllText((Join-Path $root 'main.tf'), $rootSource)
        [System.IO.File]::WriteAllText((Join-Path $child 'main.tf'), $childSource)
        $null = Invoke-MetadataNativeTool -Tool terraform -Root $root `
            -Arguments @('init', '-backend=false', '-input=false', '-no-color')
        $planPath = Join-Path $root 'metadata.tfplan'
        $null = Invoke-MetadataNativeTool -Tool terraform -Root $root `
            -Arguments @('plan', '-refresh=false', '-input=false', '-lock=false', '-no-color', "-out=$planPath")
        $plan = (Invoke-MetadataNativeTool -Tool terraform -Root $root `
                -Arguments @('show', '-json', $planPath)) | ConvertFrom-Json
        $outputs = $plan.planned_values.outputs
        $outputs.source_value.value | Should -BeExactly 'root-source'
        $outputs.child_value.value | Should -BeExactly 'child-source'
        $plan.PSObject.Properties.Name | Should -Not -Contain 'resource_changes'
        $before = $outputs | ConvertTo-Json -Depth 20

        $seed = New-NativeMetadataSeed -Ecosystem terraform
        $childSeed = New-NativeMetadataSeed -Ecosystem terraform -ChildModule
        $null = Initialize-AvmModuleMetadata -Path $root -InputObject $seed `
            -Ecosystem terraform -ModuleType resource -SkipModuleVersionCheck
        $null = Initialize-AvmModuleMetadata -Path $child -InputObject $childSeed `
            -Ecosystem terraform -ModuleType resource -ChildModule -SkipModuleVersionCheck
        foreach ($modulePath in @($root, $child)) {
            Test-Path -LiteralPath (Join-Path $modulePath 'metadata.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $modulePath 'main.metadata.tf') | Should -BeFalse
        }
        Get-Content -LiteralPath (Join-Path $root 'main.tf') -Raw | Should -BeExactly $rootSource
        Get-Content -LiteralPath (Join-Path $child 'main.tf') -Raw | Should -BeExactly $childSource
        $null = Invoke-MetadataNativeTool -Tool terraform -Root $root `
            -Arguments @('plan', '-refresh=false', '-input=false', '-lock=false', '-no-color', "-out=$planPath")
        $updatedPlan = (Invoke-MetadataNativeTool -Tool terraform -Root $root `
                -Arguments @('show', '-json', $planPath)) | ConvertFrom-Json
        ($updatedPlan.planned_values.outputs | ConvertTo-Json -Depth 20) | Should -BeExactly $before
        $updatedPlan.PSObject.Properties.Name | Should -Not -Contain 'resource_changes'

        $seed.owners = @('new-owner', '@Azure/new-team')
        $seed.canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
        $seed.telemetryIdPrefix = '46d3xtrf.res.7654321'
        [System.IO.File]::WriteAllText((Join-Path $root 'metadata.json'), ($seed | ConvertTo-Json -Depth 20))
        { Initialize-AvmModuleMetadata -Path $root -InputObject $seed -Ecosystem terraform `
                -ModuleType resource -UpdateSource -SkipModuleVersionCheck } | Should -Throw '*not supported*'
        $null = Invoke-MetadataNativeTool -Tool terraform -Root $root `
            -Arguments @('plan', '-refresh=false', '-input=false', '-lock=false', '-no-color', "-out=$planPath")
        $updatedPlan = (Invoke-MetadataNativeTool -Tool terraform -Root $root `
                -Arguments @('show', '-json', $planPath)) | ConvertFrom-Json
        ($updatedPlan.planned_values.outputs | ConvertTo-Json -Depth 20) | Should -BeExactly $before
        $updatedPlan.PSObject.Properties.Name | Should -Not -Contain 'resource_changes'
    }
}
