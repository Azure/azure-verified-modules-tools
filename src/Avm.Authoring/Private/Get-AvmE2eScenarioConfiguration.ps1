function Get-AvmE2eScenarioConfiguration {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if (-not (Get-Variable -Name AvmE2eScenarioConfiguration -Scope Script -ErrorAction Ignore) -or
        $null -eq $script:AvmE2eScenarioConfiguration) {
        $resourceRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Resources'
        $configPath = Join-Path $resourceRoot 'e2e-scenarios.json'
        $schemaPath = Join-Path -Path $resourceRoot -ChildPath 'Schemas' `
            -AdditionalChildPath 'v1', 'e2e-scenarios.schema.json'
        $json = [System.IO.File]::ReadAllText($configPath)
        if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
            throw [AvmConfigurationException]::new(
                "The packaged E2E scenario configuration is invalid: $configPath")
        }
        $configuration = ConvertFrom-Json -InputObject $json -AsHashtable
        foreach ($pattern in $configuration['scenarioPatterns'].Values) {
            try {
                $null = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::None,
                    [System.TimeSpan]::FromSeconds(1))
            }
            catch {
                throw [AvmConfigurationException]::new(
                    "The packaged E2E scenario configuration contains an invalid pattern: $configPath")
            }
        }
        $script:AvmE2eScenarioConfiguration = $configuration
    }
    return $script:AvmE2eScenarioConfiguration
}

function Test-AvmE2eScenarioName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('defaults', 'waf-aligned')] [string] $Scenario
    )

    $configuration = Get-AvmE2eScenarioConfiguration
    return [regex]::IsMatch($Name, $configuration['scenarioPatterns'][$Scenario],
        [System.Text.RegularExpressions.RegexOptions]::None,
        [System.TimeSpan]::FromSeconds(1))
}

function Get-AvmRequiredE2eScenario {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [ValidateSet('res', 'ptn', 'utl')] [string] $ModuleType
    )

    $configuration = Get-AvmE2eScenarioConfiguration
    return [string[]]@($configuration['moduleTypes'][$ModuleType]['requiredScenarios'])
}

function Get-AvmRequiredPolicyBaseline {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [ValidateSet('res', 'ptn', 'utl')] [string] $ModuleType
    )

    $configuration = Get-AvmE2eScenarioConfiguration
    return [string[]]@($configuration['moduleTypes'][$ModuleType]['requiredPolicyBaselines'])
}
