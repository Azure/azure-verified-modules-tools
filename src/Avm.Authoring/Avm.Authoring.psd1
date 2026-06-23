@{
    RootModule           = 'Avm.Authoring.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '356c238f-88dd-48bf-ad0a-b7de6a5bb877'
    Author               = 'Azure Verified Modules'
    CompanyName          = 'Microsoft'
    Copyright            = '(c) Microsoft Corporation. All rights reserved.'
    Description          = 'Cross-platform PowerShell 7 CLI that consolidates the authoring and CI tooling for Azure Verified Modules (https://aka.ms/avm). A single avm command (alias: avm) works across both ecosystems and ships: environment diagnostics (avm version, avm doctor); a checksum-pinned managed-tool resolver (avm tool list/which/install) that downloads and verifies the exact terraform, terraform-docs, tflint, conftest and mapotf binaries a module needs; and a fully wired Terraform authoring chain - avm pre-commit fixes and checks a module locally (convention checks, HCL transforms via mapotf, terraform fmt and terraform-docs) while avm pr-check adds tflint, APRL/AVMSEC policy checks and terraform validate. No Docker, make or porch required. The Bicep facade is in active development. Requires PowerShell 7.4+ (Core). See https://github.com/Azure/azure-verified-modules-tools for status and docs.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Get-AvmAuthoringPlaceholder',
        'Get-AvmModuleContext',
        'Get-AvmTool',
        'Get-AvmVersion',
        'Install-AvmTool',
        'Invoke-Avm',
        'Invoke-AvmCheckConvention',
        'Invoke-AvmCheckPolicy',
        'Invoke-AvmDoctor',
        'Invoke-AvmDocs',
        'Invoke-AvmFormat',
        'Invoke-AvmLint',
        'Invoke-AvmPrCheck',
        'Invoke-AvmPreCommit',
        'Invoke-AvmTest',
        'Invoke-AvmTransform'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('avm')
    PrivateData          = @{
        PSData = @{
            Tags         = @('Azure', 'AVM', 'AzureVerifiedModules', 'Bicep', 'Terraform', 'Authoring', 'CLI', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/Azure/azure-verified-modules-tools/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Azure/azure-verified-modules-tools'
            ReleaseNotes = '0.1.0 - Phase 0 skeleton. Adds the avm dispatcher (alias: avm), Get-AvmVersion / avm version, Invoke-AvmDoctor / avm doctor, and the managed-tool resolver (Get-AvmTool, Install-AvmTool, avm tool list|which|install). The bundled tools.lock.psd1 is an empty schema stub awaiting bicep and terraform entries. Backward compatibility shim Get-AvmAuthoringPlaceholder is retained from 0.0.1.'
        }
    }
}
