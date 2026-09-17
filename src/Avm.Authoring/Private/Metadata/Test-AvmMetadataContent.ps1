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

    $resourceType = Test-AvmMetadataResourceType -CanonicalType $metadata.canonicalType
    if (($ModuleType -eq 'resource') -ne $resourceType) {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_KIND' `
                    -Message "canonicalType '$($metadata.canonicalType)' does not identify a $ModuleType module."))
    }

    if ($metadata.Contains('telemetryIdPrefix')) {
        $marker = if ($Ecosystem -eq 'bicep') { '46d3xbcp' } else { '46d3xtrf' }
        $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
        $legacyResourceGraph = $Ecosystem -eq 'bicep' -and $ModuleType -eq 'resource' -and
        $metadata.canonicalType -ceq 'Microsoft.ResourceGraph/queries' -and
        $metadata.telemetryIdPrefix -ceq '46d3xbcp.resourcegraph-query'
        if (-not $legacyResourceGraph -and -not $metadata.telemetryIdPrefix.StartsWith("$marker.$kind.", [System.StringComparison]::Ordinal)) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_TELEMETRY' `
                        -Message "telemetryIdPrefix must start with '$marker.$kind.' for this module."))
        }
    }
    elseif (($null -eq $TelemetryRequired -and $ModuleType -ne 'utility') -or $TelemetryRequired -eq $true) {
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
