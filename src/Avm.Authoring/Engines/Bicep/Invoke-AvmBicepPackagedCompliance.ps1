function Invoke-AvmBicepPackagedCompliance {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [switch] $Recurse,

        [switch] $AllowPathFallback,

        [AllowEmptyCollection()]
        [string[]] $Tag = @(),

        [AllowEmptyCollection()]
        [string[]] $TestName = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $scopes = @(Get-AvmMetadataScope -Context $Context -IncludeModuleDirectories |
            Where-Object { $Recurse -or -not $_.ChildModule -or $_.Path -ceq $Context.Root })
    $metadata = Test-AvmMetadataModules -Context $Context -SelectedScope $scopes -PreparationOnly
    $prepared = Invoke-AvmBicepCheckConvention -Context $Context -SelectedScope $scopes `
        -AllowPathFallback:$AllowPathFallback -PreparationOnly
    $issues = [System.Collections.Generic.List[object]]::new()
    foreach ($issue in @($metadata.Issues) + @($prepared.Issues)) { $issues.Add($issue) }
    $readmeInputs = @()
    if ($scopes.Count -gt 0) {
        try {
            $readmes = Invoke-AvmBicepDocs -Context $Context -SelectedScope $scopes -CheckDrift `
                -PreparationOnly -AllowPathFallback:$AllowPathFallback
            $readmeInputs = @($readmes.ReadmeInputs)
            foreach ($issue in @($readmes.Issues)) { $issues.Add($issue) }
        }
        catch [AvmConfigurationException], [AvmProcessException], [AvmToolException] {
            $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root -Path (Join-Path $Context.Root 'README.md') `
                        -Code 'avm.bicep.docs-render-failed' -Message $_.Exception.Message))
        }
    }
    foreach ($issue in @(Invoke-AvmBicepConventionSuite -Convention $prepared.Convention -Compliance `
                -MetadataInputs @($metadata.Validations) -ReadmeInputs $readmeInputs -Tag $Tag -TestName $TestName)) {
        $issues.Add($issue)
    }
    $summary = $prepared.Convention.ValidationSummary
    if ($null -eq $summary) {
        $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root -Path $Context.Root `
                    -Code 'avm.bicep.compliance-not-run' -Message 'The packaged compliance suite did not execute.'))
    }
    $suite = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..' `
                -AdditionalChildPath '..', 'Resources', 'bicep', 'Compliance.Tests.ps1'))
    return [pscustomobject]@{ Summary = $summary; Issues = $issues.ToArray(); Suite = $suite }
}
