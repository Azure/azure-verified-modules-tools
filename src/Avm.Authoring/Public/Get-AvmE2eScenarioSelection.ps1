function Get-AvmE2eScenarioSelection {
    <#
    .SYNOPSIS
        Classify AVM E2E examples by module-specific requirements.

    .DESCRIPTION
        Uses the packaged scenario configuration to divide example names into
        required and optional groups, and reports required scenario categories
        that have no matching example. Scenario matching is case-sensitive.

    .PARAMETER ModuleType
        AVM module type: res, ptn, or utl.

    .PARAMETER Names
        Discovered E2E example names. An empty list is valid and reports all
        required scenario categories as missing.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for offline workflow callers.

    .OUTPUTS
        PSCustomObject with ModuleType, ModuleTypeDisplayName, RequiredScenarios,
        Required, Optional, and MissingRequiredScenarios.

    .EXAMPLE
        PS> Get-AvmE2eScenarioSelection -ModuleType ptn -Names @('defaults-api', 'waf-aligned')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('res', 'ptn', 'utl')]
        [string] $ModuleType,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Names,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $configuration = Get-AvmE2eScenarioConfiguration
    $moduleConfiguration = $configuration['moduleTypes'][$ModuleType]
    $requiredScenarios = @($moduleConfiguration['requiredScenarios'])
    $requiredNames = [System.Collections.Generic.List[string]]::new()
    $optionalNames = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Names) {
        $isRequired = $false
        foreach ($scenario in $requiredScenarios) {
            if (Test-AvmE2eScenarioName -Name $name -Scenario $scenario) {
                $isRequired = $true
                break
            }
        }
        if ($isRequired) { $requiredNames.Add($name) }
        else { $optionalNames.Add($name) }
    }

    $missingScenarios = @(
        foreach ($scenario in $requiredScenarios) {
            if (-not @($Names | Where-Object {
                        Test-AvmE2eScenarioName -Name $_ -Scenario $scenario
                    }).Count) {
                $scenario
            }
        }
    )
    return [pscustomobject]@{
        ModuleType               = $ModuleType
        ModuleTypeDisplayName    = [string]$moduleConfiguration['displayName']
        RequiredScenarios        = $requiredScenarios
        Required                 = $requiredNames.ToArray()
        Optional                 = $optionalNames.ToArray()
        MissingRequiredScenarios = $missingScenarios
    }
}
