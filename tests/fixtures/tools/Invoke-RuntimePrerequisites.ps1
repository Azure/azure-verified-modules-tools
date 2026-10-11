#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ManifestPath,
    [Parameter(Mandatory)] [string] $Root,
    [Parameter(Mandatory)] [string] $ResultPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$before = @(Get-Module -ListAvailable -Name Pester, powershell-yaml, PSRule, PSRule.Rules.Azure)
if ($before.Count -ne 0) {
    throw [System.InvalidOperationException]::new('The isolated runtime unexpectedly has external PowerShell modules.')
}
Import-Module -Name $ManifestPath -Force
$paths = [ordered]@{ AfterImport = $env:PSModulePath }
$module = Get-Module Avm.Authoring
$schemaPath = Join-Path $module.ModuleBase 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json'
$metadata = @{
    '$schema' = (Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json).'$id'
    moduleDisplayName = 'Runtime fixture'
    moduleDescription = 'Creates no resources.'
    canonicalType = 'naming'
    owners = @('module-owner')
}
$valid = Test-AvmModuleMetadata -Path $Root -InputObject $metadata -Ecosystem terraform -ModuleType utility -SkipModuleVersionCheck
if ($valid.Status -ne 'pass') {
    throw [System.InvalidOperationException]::new("Valid metadata failed: $($valid.Issues | ConvertTo-Json -Depth 10 -Compress)")
}
$metadata.owners = @('invalid owner')
$invalid = Test-AvmModuleMetadata -Path $Root -InputObject $metadata -Ecosystem terraform -ModuleType utility -SkipModuleVersionCheck
$paths.AfterMetadata = $env:PSModulePath
if ($invalid.Status -ne 'fail' -or $invalid.Issues.Count -eq 0) {
    throw [System.InvalidOperationException]::new('The isolated metadata validator accepted invalid metadata.')
}

$report = & $module {
    param($Root, $Paths)
    $summary = Invoke-AvmBicepPesterSuite -Files @((Join-Path $Root 'Runtime.Tests.ps1')) `
        -WorkingDirectory $Root -ModuleRoot $Root -RepositoryRoot $Root -ModulePaths @($Root)
    if ($summary.Total -ne 1 -or $summary.Passed -ne 1 -or $summary.Issues.Count -ne 0) {
        throw [System.InvalidOperationException]::new("Packaged Bicep Pester runner failed: $($summary | ConvertTo-Json -Depth 10 -Compress)")
    }
    $Paths.AfterPesterRunner = $env:PSModulePath
    $workflow = Get-AvmBicepConventionWorkflow -Path (Join-Path $Root 'workflow.yml') -ModuleRoot $Root
    $Paths.AfterYaml = $env:PSModulePath
    if ($workflow['name'] -cne 'Runtime fixture') {
        throw [System.InvalidOperationException]::new('The cached YAML module did not parse the workflow.')
    }
    $null = Import-AvmBicepPolicyModule -ModuleRoot $Root
    $Paths.AfterPolicyImport = $env:PSModulePath
    $configuration = Get-AvmBicepPolicyConfiguration
    $baseline = Get-AvmBicepPolicyBaseline -Configuration $configuration -Name 'CB.AVM.WAF.Security'
    $resolved = foreach ($name in @('Pester', 'powershell-yaml', 'PSRule', 'PSRule.Rules.Azure')) {
        Resolve-AvmTool -Name $name -ModuleRoot $Root
    }
    [pscustomobject]@{
        Modules = @($resolved | Select-Object Name, Version, Path, Source)
        Pester = $summary
        PolicyRules = $baseline.RuleNames.Count
        Paths = $Paths
    }
} $Root $paths
[System.IO.File]::WriteAllText($ResultPath, ($report | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
