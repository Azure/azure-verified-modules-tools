function Test-AvmMetadataContent {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Json,

        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Ecosystem,

        [Parameter(Mandatory)]
        [ValidateSet('resource', 'pattern', 'utility')]
        [string] $ModuleType,

        [switch] $ChildModule,

        [Nullable[bool]] $TelemetryRequired = $null
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $issues = [System.Collections.Generic.List[object]]::new()
    $metadata = $null
    try {
        $metadata = ConvertFrom-AvmMetadataJson -Json $Json
    }
    catch [System.ArgumentException] {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_JSON' -Message $_.Exception.Message))
        return [pscustomobject]@{ Metadata = $null; Issues = $issues.ToArray() }
    }

    $schemaPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Resources', 'Schemas', 'v1', 'avm-module-metadata.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
    $shape = if ($ChildModule) { 'child' } else { 'root' }
    $schema.oneOf = @(@{ '$ref' = "#/definitions/$shape" })
    $schemaErrors = @()
    $valid = Test-Json -Json $Json -Schema ($schema | ConvertTo-Json -Depth 50) `
        -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    if (-not $valid) {
        $detail = @($schemaErrors | ForEach-Object { $_.Exception.Message }) -join ' '
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_SCHEMA' `
                    -Message "Invalid $shape module metadata. $detail"))
        return [pscustomobject]@{ Metadata = $metadata; Issues = $issues.ToArray() }
    }

    $helper = $ChildModule -and $metadata.canonicalType -ceq 'helper'
    $resourceType = Test-AvmMetadataResourceType -CanonicalType $metadata.canonicalType
    if (-not $helper -and (($ModuleType -eq 'resource') -ne $resourceType)) {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_KIND' `
                    -Message "canonicalType '$($metadata.canonicalType)' does not identify a $ModuleType module."))
    }

    $marker = if ($Ecosystem -eq 'bicep') { '46d3xbcp' } else { '46d3xtrf' }
    $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
    $resourceGraphModule = $Ecosystem -eq 'bicep' -and $ModuleType -eq 'resource' -and $metadata.canonicalType -ceq 'Microsoft.ResourceGraph/queries'
    $prefixes = @(
        if ($metadata.Contains('telemetryIdPrefix')) {
            [pscustomobject]@{ Field = 'telemetryIdPrefix'; Value = $metadata.telemetryIdPrefix }
        }
        if ($metadata.Contains('alternativeTelemetryIdPrefixes')) {
            foreach ($prefix in $metadata.alternativeTelemetryIdPrefixes) {
                [pscustomobject]@{ Field = 'alternativeTelemetryIdPrefixes'; Value = $prefix }
            }
        }
    )
    foreach ($prefix in $prefixes) {
        if ($prefix.Field -eq 'alternativeTelemetryIdPrefixes' -and
            $metadata.Contains('telemetryIdPrefix') -and $prefix.Value -ceq $metadata.telemetryIdPrefix) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_TELEMETRY' `
                        -Message 'alternativeTelemetryIdPrefixes cannot contain the current telemetryIdPrefix.'))
        }
        $legacyResourceGraph = $prefix.Value -ceq '46d3xbcp.resourcegraph-query'
        if ($legacyResourceGraph -and -not $resourceGraphModule) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_TELEMETRY' `
                        -Message "$($prefix.Field) cannot use the Resource Graph legacy identifier for this module."))
        }
        elseif (-not $legacyResourceGraph -and -not $prefix.Value.StartsWith("$marker.$kind.", [System.StringComparison]::Ordinal)) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_TELEMETRY' `
                        -Message "$($prefix.Field) must start with '$marker.$kind.' for this module."))
        }
    }
    if (-not $metadata.Contains('telemetryIdPrefix') -and -not $helper -and
        (($null -eq $TelemetryRequired -and $ModuleType -ne 'utility') -or $TelemetryRequired -eq $true)) {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_TELEMETRY' `
                    -Message 'This module requires telemetryIdPrefix.'))
    }

    if (-not $ChildModule) {
        $handles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($owner in $metadata.owners) {
            if (-not $handles.Add($owner)) {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_OWNER' `
                            -Message "Owner '$owner' is listed more than once."))
            }
        }
    }

    return [pscustomobject]@{ Metadata = $metadata; Issues = $issues.ToArray() }
}
