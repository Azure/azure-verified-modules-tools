. (Join-Path $PSScriptRoot 'Get-AvmMetadataBackfillValue.ps1')
. (Join-Path $PSScriptRoot 'Get-AvmMetadataBackfillSource.ps1')
. (Join-Path $PSScriptRoot 'ConvertTo-AvmMetadataBackfillCandidate.ps1')

function New-AvmMetadataBackfillIssue {
    param([string] $Code, [string] $Message)

    [pscustomobject]@{ Code = $Code; Message = $Message; Severity = 'error' }
}

function Get-AvmMetadataBackfillCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ModuleId,
        [Parameter(Mandatory)][ValidateSet('bicep', 'terraform')][string] $Ecosystem,
        [Parameter(Mandatory)][ValidateSet('resource', 'pattern', 'utility')][string] $ModuleType,
        [switch] $ChildModule,
        [object[]] $LegacyRecord = @(),
        [System.Collections.IDictionary] $Override = @{},
        [string[]] $OwnerGitHubHandle = @(),
        [switch] $SkipModuleVersionCheck
    )

    $parameters = @{
        Path = $Path
        Ecosystem = $Ecosystem
        ModuleType = $ModuleType
        ChildModule = $ChildModule
        SkipModuleVersionCheck = $SkipModuleVersionCheck
    }
    $existing = @(Get-ChildItem -LiteralPath $Path -Force | Where-Object { $_.Name -ieq 'metadata.json' })
    if ($existing.Count -gt 0) {
        return Get-AvmModuleMetadata @parameters
    }

    $converted = ConvertTo-AvmMetadataBackfillCandidate -Path $Path -ModuleId $ModuleId `
        -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule `
        -LegacyRecord $LegacyRecord -Override $Override -OwnerGitHubHandle $OwnerGitHubHandle
    $validation = Test-AvmModuleMetadata @parameters -InputObject $converted.Candidate `
        -CheckSource:($Ecosystem -eq 'bicep')
    $issues = @($converted.Issues) + @($validation.Issues)
    return [pscustomobject]@{
        Status = if ($issues.Count -eq 0) { 'pass' } else { 'fail' }
        Issues = $issues
        Metadata = if ($issues.Count -eq 0) { $validation.Metadata } else { $null }
        Candidate = $converted.Candidate
    }
}
