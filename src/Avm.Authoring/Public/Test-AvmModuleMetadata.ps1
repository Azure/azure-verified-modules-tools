function Test-AvmModuleMetadata {
    <#
    .SYNOPSIS
        Validate a module's shared metadata against the packaged v1 schema.
    .DESCRIPTION
        Checks strict JSON, the root or reduced child shape, canonical type,
        ownership, and ecosystem-specific telemetry requirements. Never writes
        files or downloads schemas. Missing or invalid metadata returns fail.
    .PARAMETER Path
        Directory containing metadata.json.
    .PARAMETER Ecosystem
        The containing module's ecosystem: bicep or terraform.
    .PARAMETER ModuleType
        Module kind derived by the caller from its path or repository name.
    .PARAMETER ChildModule
        Require the reduced child shape, without owners or tier.
    .PARAMETER CheckSource
        Also compare Bicep metadata name and description literals to the JSON.
    .PARAMETER SkipModuleVersionCheck
        Skip the standard installed-module version check for offline validation.
    .EXAMPLE
        Test-AvmModuleMetadata -Path . -Ecosystem terraform -ModuleType resource
    .OUTPUTS
        A result with Status, Issues, and the decoded Metadata dictionary.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is the shared metadata.json contract name.')]
    [CmdletBinding()]
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
        if (Test-Path -LiteralPath $Path -PathType Container) {
            Get-ChildItem -LiteralPath $Path -Force | Where-Object { $_.Name -ieq 'metadata.json' }
        }
    )
    $metadata = $null
    if ($metadataFiles.Count -eq 0) {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_MISSING' -Message 'metadata.json is required.'))
    }
    elseif ($metadataFiles.Count -ne 1 -or $metadataFiles[0].PSIsContainer -or $metadataFiles[0].Name -cne 'metadata.json') {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_CASE' -Message 'Exactly one file named metadata.json with that casing is required.'))
    }
    else {
        try {
            $result = Test-AvmMetadataContent -Json (Read-AvmMetadataJson -Path $metadataPath) `
                -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule
            $metadata = $result.Metadata
            foreach ($issue in $result.Issues) {
                $issues.Add($issue)
            }
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_JSON' -Message $_.Exception.Message))
        }
    }

    if ($issues.Count -eq 0 -and $CheckSource -and $Ecosystem -eq 'bicep') {
        $sourcePath = Join-Path -Path $Path -ChildPath 'main.bicep'
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_SOURCE' -File 'main.bicep' `
                        -Message 'main.bicep is required for the literal metadata comparison.'))
        }
        else {
            try {
                $source = Get-Content -LiteralPath $sourcePath -Raw
                $literals = Get-AvmBicepMetadataLiteral -Source $source
                $code = Get-AvmBicepCommentFreeSource -Source $source
                if (-not $metadata.Contains('telemetryIdPrefix') -and
                    [regex]::IsMatch($code, "(?m)^[\t ]*resource[\t ]+avmTelemetry[\t ]+'Microsoft\.Resources/deployments@")) {
                    $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_TELEMETRY' `
                                -Message 'This Bicep module emits telemetry and requires telemetryIdPrefix.'))
                }
                foreach ($field in @(
                        @{ Source = 'name'; Metadata = 'moduleDisplayName' },
                        @{ Source = 'description'; Metadata = 'moduleDescription' }
                    )) {
                    if ($literals[$field.Source] -cne $metadata[$field.Metadata]) {
                        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_SOURCE' -File 'main.bicep' `
                                    -Message "metadata $($field.Source) must match metadata.json $($field.Metadata)."))
                    }
                }
            }
            catch [System.ArgumentException] {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_SOURCE' -File 'main.bicep' `
                            -Message $_.Exception.Message))
            }
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
