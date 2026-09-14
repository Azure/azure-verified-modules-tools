function New-AvmModuleMetadataSeed {
    <#
    .SYNOPSIS
        Prepare an offline metadata seed from legacy values and checked-out source.
    .DESCRIPTION
        Returns a validated seed or explicit unresolved-field diagnostics without
        writing files. Existing metadata takes precedence. InputObject validates
        an exact reviewed seed independently of any existing metadata file.
    .PARAMETER Path
        Existing module directory. No cloning, source rewriting, or network lookup.
    .PARAMETER ModuleId
        Bicep avm/{res,ptn,utl}/group/name path or Terraform avm-kind-logical ID.
    .PARAMETER Ecosystem
        bicep or terraform.
    .PARAMETER ModuleType
        resource, pattern, or utility.
    .PARAMETER ChildModule
        Prepare the fixed reduced child shape, without owners or tier.
    .PARAMETER LegacyRecord
        Matching legacy CSV records. Only metadata fields and GitHub handles are read.
    .PARAMETER Override
        Reviewed metadata field overrides for values that cannot be inferred losslessly.
    .PARAMETER OwnerGitHubHandle
        Additional root owner handles from a reviewed ownership snapshot.
    .PARAMETER InputObject
        Exact metadata dictionary to validate and normalize without inferring fields.
    .PARAMETER SkipModuleVersionCheck
        Skip the installed-module version check for offline preparation.
    .EXAMPLE
        New-AvmModuleMetadataSeed -Path . -ModuleId avm-res-storage-storageaccount -Ecosystem terraform -ModuleType resource -LegacyRecord $row -Override @{ moduleDescription = 'Deploys a Storage Account.' } -SkipModuleVersionCheck
    .OUTPUTS
        A result with Status, Issues, Metadata (only when valid), and Candidate.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns an in-memory seed without writing files or state.')]
    [CmdletBinding(DefaultParameterSetName = 'Legacy')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'Legacy')]
        [string] $Path = $PWD.Path,
        [Parameter(Mandatory, ParameterSetName = 'Legacy')]
        [string] $ModuleId,
        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,
        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,
        [switch] $ChildModule,
        [Parameter(ParameterSetName = 'Legacy')]
        [object[]] $LegacyRecord = @(),
        [Parameter(ParameterSetName = 'Legacy')]
        [System.Collections.IDictionary] $Override = @{},
        [Parameter(ParameterSetName = 'Legacy')]
        [string[]] $OwnerGitHubHandle = @(),
        [Parameter(Mandatory, ParameterSetName = 'Object')]
        [System.Collections.IDictionary] $InputObject,
        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $issues = [System.Collections.Generic.List[object]]::new()
    if ($PSCmdlet.ParameterSetName -eq 'Object') {
        $candidate = $InputObject
    }
    elseif (Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath 'metadata.json')) {
        $existing = Test-AvmModuleMetadata -Path $Path -Ecosystem $Ecosystem -ModuleType $ModuleType `
            -ChildModule:$ChildModule -CheckSource:($Ecosystem -eq 'bicep') -SkipModuleVersionCheck
        return [pscustomobject]@{
            Status    = $existing.Status
            Issues    = $existing.Issues
            Metadata  = if ($existing.Status -eq 'pass') { $existing.Metadata } else { $null }
            Candidate = $existing.Metadata
        }
    }
    else {
        $converted = ConvertTo-AvmMetadataSeed -Path $Path -ModuleId $ModuleId -Ecosystem $Ecosystem `
            -ModuleType $ModuleType -ChildModule:$ChildModule -LegacyRecord $LegacyRecord `
            -Override $Override -OwnerGitHubHandle $OwnerGitHubHandle
        $candidate = $converted.Candidate
        foreach ($issue in $converted.Issues) {
            $issues.Add($issue)
        }
    }
    $validation = Test-AvmMetadataContent -Json (ConvertTo-Json -InputObject $candidate -Depth 50) `
        -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule
    foreach ($issue in $validation.Issues) {
        $issues.Add($issue)
    }
    return [pscustomobject]@{
        Status    = if ($issues.Count -eq 0) { 'pass' } else { 'fail' }
        Issues    = $issues.ToArray()
        Metadata  = if ($issues.Count -eq 0) { $validation.Metadata } else { $null }
        Candidate = $candidate
    }
}
