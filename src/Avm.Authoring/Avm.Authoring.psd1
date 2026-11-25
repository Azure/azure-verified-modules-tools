@{
    RootModule           = 'Avm.Authoring.psm1'
    ModuleVersion        = '0.0.0'
    GUID                 = '356c238f-88dd-48bf-ad0a-b7de6a5bb877'
    Author               = 'Azure Verified Modules'
    CompanyName          = 'Microsoft'
    Copyright            = '(c) Microsoft Corporation. All rights reserved.'
    Description          = 'Cross-platform PowerShell CLI for Azure Verified Modules authors. Check and fix Terraform modules locally, then validate changes before opening a pull request. Includes formatting, linting, policy checks, and Terraform validation.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Get-AvmAuthoringPlaceholder',
        'Get-AvmBicepAzureDependency',
        'Get-AvmBicepE2eDeploymentMatrix',
        'Get-AvmBicepE2eTestContext',
        'Get-AvmBicepPendingReleasePlan',
        'Get-AvmBicepWorkflowModuleMatrix',
        'Get-AvmBicepWorkflowTestFiles',
        'Get-AvmCatalogTelemetryPrefix',
        'Get-AvmE2eScenarioSelection',
        'Get-AvmModuleContext',
        'Get-AvmTool',
        'Get-AvmVersion',
        'Initialize-AvmModule',
        'Initialize-AvmModuleMetadata',
        'Initialize-AvmBicepReleaseMatrix',
        'Initialize-AvmBicepWorkflowMatrix',
        'Install-AvmTool',
        'New-AvmTelemetryIdPrefix',
        'Invoke-Avm',
        'Invoke-AvmCheckConvention',
        'Invoke-AvmCheckPolicy',
        'Invoke-AvmDoctor',
        'Invoke-AvmDocs',
        'Invoke-AvmFormat',
        'Invoke-AvmReleaseBranch',
        'Invoke-AvmLint',
        'Invoke-AvmPrCheck',
        'Invoke-AvmPreCommit',
        'Invoke-AvmSync',
        'Invoke-AvmTest',
        'Invoke-AvmTestCleanup',
        'Invoke-AvmTestE2e',
        'Invoke-AvmTestIntegration',
        'Invoke-AvmTestUnit',
        'Invoke-AvmTransform',
        'Get-AvmModuleMetadata',
        'Register-AvmFeature',
        'Select-AvmTestSubscription',
        'Set-AvmBicepReleaseTags',
        'Test-AvmModuleMetadata',
        'Update-AvmAuthoring'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('avm')
    PrivateData          = @{
        AvmCapabilities = @{
            BicepTestSubscriptionSelection  = 1
            BicepPackagedCompliance         = 1
            BicepRequiredResourceProviders  = 1
            PowerShellModuleArchiveRecovery = 1
            BicepWorkflowOrchestration      = 1
            BicepReleaseSelection           = 1
            BicepWorkflowE2eRuntime         = 1
            BicepAzureDependencyInventory   = 1
        }
        PSData          = @{
            Tags         = @('Azure', 'AVM', 'AzureVerifiedModules', 'Bicep', 'Terraform', 'Authoring', 'CLI', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/Azure/azure-verified-modules-tools/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Azure/azure-verified-modules-tools'
            ReleaseNotes = 'See https://github.com/Azure/azure-verified-modules-tools/blob/main/CHANGELOG.md. The release workflow replaces this value with the CHANGELOG section for the tag being published, when one exists.'
        }
    }
}
