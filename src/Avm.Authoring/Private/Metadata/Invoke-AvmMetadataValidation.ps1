function Invoke-AvmMetadataValidation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object[]] $Validations
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Import-Module -Name Pester -MinimumVersion 5.5.0 -DisableNameChecking -ErrorAction Stop
    $suite = Join-Path -Path $PSScriptRoot -ChildPath '..' `
        -AdditionalChildPath '..', 'Resources', 'metadata', 'Metadata.Tests.ps1'
    $configuration = New-PesterConfiguration
    $configuration.Run.Container = @(New-PesterContainer -Path $suite -Data @{ Validations = $Validations })
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Run.Throw = $false
    $configuration.Output.Verbosity = 'None'
    $configuration.Output.CIFormat = 'None'
    $result = Invoke-Pester -Configuration $configuration
    $issues = [System.Collections.Generic.List[object]]::new()
    foreach ($test in @($result.Tests | Where-Object { $_.Result -eq 'Failed' })) {
        $code = @($test.Tag | Where-Object { $_ -like 'AVM_METADATA_*' }) | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($code)) { $code = 'AVM_METADATA_SUITE' }
        $detail = @($test.ErrorRecord | ForEach-Object { $_.Exception.Message }) -join ' '
        $leaf = if ($code -eq 'AVM_METADATA_SOURCE') { 'main.bicep' } else { 'metadata.json' }
        $file = Join-Path $test.Block.Data.Validation.Path $leaf
        $issues.Add((New-AvmMetadataIssue -Code $code -File $file -Message "$($test.ExpandedName): $detail"))
    }
    $expected = 0
    foreach ($validation in $Validations) {
        $expected += if ($validation.ShapeValid) { 6 } else { 1 }
        if ($validation.ShapeValid -and $validation.CheckSource) {
            $expected += 2
            if ($null -ne $validation.SourceText) { $expected += 2 }
        }
    }
    if ($result.FailedContainersCount -gt 0 -or $result.FailedBlocksCount -gt 0 -or
        $result.TotalCount -ne $expected -or @($result.Tests).Count -ne $expected -or
        $result.PassedCount + $result.FailedCount -ne $expected) {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_SUITE' `
                    -Message "Metadata Pester validation did not execute all $expected intended checks."))
    }
    return [pscustomobject]@{
        Issues = $issues.ToArray()
        Tests  = @($result.Tests | ForEach-Object { [pscustomobject]@{ Name = $_.ExpandedPath; Result = $_.Result } })
    }
}
