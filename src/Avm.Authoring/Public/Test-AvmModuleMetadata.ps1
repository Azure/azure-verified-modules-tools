function Test-AvmModuleMetadata {
    <#
    .SYNOPSIS
        Validate existing or supplied module metadata with packaged Pester tests.
    .DESCRIPTION
        Checks strict JSON, the root or reduced child shape, canonical type,
        ownership, and ecosystem-specific telemetry requirements. Never writes
        module files or downloads schemas. Missing or invalid metadata returns fail.
        Both ecosystems use the same native assertion suite and shared schemas.
        Requires Pester 5.5 or later. InputObject validates supplied values without
        reading metadata.json.
    .PARAMETER Path
        Directory containing metadata.json.
    .PARAMETER Ecosystem
        The containing module's ecosystem: bicep or terraform.
    .PARAMETER ModuleType
        Module kind derived by the caller from its path or repository name.
    .PARAMETER ChildModule
        Require the reduced child shape, without owners.
        This scope also permits canonicalType helper with optional telemetry.
    .PARAMETER InputObject
        Metadata values to validate instead of reading metadata.json.
    .PARAMETER CheckSource
        Also validate Bicep source metadata literals and telemetry when source
        exists. A metadata-only scope cannot contain version.json or main.json.
    .PARAMETER SkipModuleVersionCheck
        Skip the standard installed-module version check for offline validation.
    .EXAMPLE
        Test-AvmModuleMetadata -Path . -Ecosystem terraform -ModuleType resource
    .OUTPUTS
        A result with Status, Issues, and the decoded Metadata dictionary.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is the shared metadata.json contract name.')]
    [CmdletBinding(DefaultParameterSetName = 'File')]
    [OutputType([pscustomobject])]
    param(
        [string] $Path = $PWD.Path,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [switch] $ChildModule,

        [Parameter(Mandatory, ParameterSetName = 'Object')]
        [System.Collections.IDictionary] $InputObject,

        [switch] $CheckSource,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $sentinel = Test-AvmDisableSentinel -Path $Path
    if ($sentinel) {
        throw [AvmConfigurationException]::new("avm is disabled in this repository (remove '$sentinel' to re-enable).")
    }
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $issues = [System.Collections.Generic.List[object]]::new()
    $metadataPath = Join-Path -Path $Path -ChildPath 'metadata.json'
    $metadataFiles = @(
        if ($PSCmdlet.ParameterSetName -eq 'File' -and (Test-Path -LiteralPath $Path -PathType Container)) {
            Get-ChildItem -LiteralPath $Path -Force | Where-Object { $_.Name -ieq 'metadata.json' }
        }
    )
    $metadata = $null
    $json = $null
    if ($PSCmdlet.ParameterSetName -eq 'Object') {
        $json = ConvertTo-Json -InputObject $InputObject -Depth 50
    }
    elseif ($metadataFiles.Count -eq 0) {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_MISSING' -Message 'metadata.json is required.'))
    }
    elseif ($metadataFiles.Count -ne 1 -or $metadataFiles[0].PSIsContainer -or $metadataFiles[0].Name -cne 'metadata.json') {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_CASE' -Message 'Exactly one file named metadata.json with that casing is required.'))
    }
    else {
        try {
            $json = Read-AvmMetadataJson -Path $metadataPath
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_JSON' -Message $_.Exception.Message))
        }
    }
    if ($null -ne $json) {
        try {
            $validation = Get-AvmMetadataValidationInput -Json $json -Path $Path -CheckSource:$CheckSource `
                -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule `
                -TelemetryRequired (Test-AvmMetadataTelemetryRequired -Path $Path -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule)
            $result = Invoke-AvmMetadataValidation -Validations @($validation) -ModuleRoot $Path
            $metadata = $validation.Metadata
            foreach ($issue in $result.Issues) {
                if ([System.IO.Path]::IsPathRooted($issue.File)) {
                    $issue.File = [System.IO.Path]::GetRelativePath([System.IO.Path]::GetFullPath($Path), $issue.File).Replace('\', '/')
                }
                elseif ($issue.File -ne 'metadata.json') {
                    $issue.File = [System.IO.Path]::GetFileName($issue.File)
                }
                $issues.Add($issue)
            }
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_JSON' -Message $_.Exception.Message))
        }
    }

    return [pscustomobject][ordered]@{
        Engine     = $Ecosystem
        Tool       = 'module-metadata/1'
        ToolPath   = $null
        ToolSource = 'builtin'
        Status     = if ($issues.Count -gt 0) { 'fail' } else { 'pass' }
        Issues     = $issues.ToArray()
        Metadata   = $metadata
    }
}
