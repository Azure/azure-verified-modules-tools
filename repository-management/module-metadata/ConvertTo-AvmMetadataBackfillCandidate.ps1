function ConvertTo-AvmMetadataBackfillCandidate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $ModuleId,
        [Parameter(Mandatory)]
        [string] $Ecosystem,
        [Parameter(Mandatory)]
        [string] $ModuleType,
        [switch] $ChildModule,
        [object[]] $LegacyRecord = @(),
        [System.Collections.IDictionary] $Override = @{},
        [string[]] $OwnerGitHubHandle = @()
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $issues = [System.Collections.Generic.List[object]]::new()
    $authoring = (Get-Command Test-AvmModuleMetadata -Module Avm.Authoring -ErrorAction Stop).Module
    $schemaPath = Join-Path $authoring.ModuleBase 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
    $shape = if ($ChildModule) { 'child' } else { 'root' }
    $allowed = @($schema.definitions[$shape].properties.Keys)
    $metadata = [ordered]@{ '$schema' = $schema.'$id' }
    foreach ($key in $Override.Keys) {
        if ($allowed -cnotcontains $key) {
            $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_OVERRIDE' -Message "Unsupported $shape override field '$key'."))
        }
        else {
            $metadata[$key] = $Override[$key]
        }
    }

    $source = $null
    try {
        $source = Get-AvmMetadataBackfillSource -Path $Path -Ecosystem $Ecosystem
    }
    catch [System.ArgumentException] {
        $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_SOURCE' -Message $_.Exception.Message))
    }
    $fields = [ordered]@{
        moduleDisplayName = @('ModuleDisplayName')
        moduleDescription = @('ModuleDescription', 'Description')
        telemetryIdPrefix = @('TelemetryIdPrefix')
    }
    if (-not $ChildModule) {
        $fields.comments = @('Comments')
        $fields.alternativeNames = @('AlternativeNames')
    }
    foreach ($field in $fields.Keys) {
        if ($Ecosystem -eq 'bicep' -and $null -ne $source -and $field -in @('moduleDisplayName', 'moduleDescription')) {
            $literalName = if ($field -eq 'moduleDisplayName') { 'name' } else { 'description' }
            $value = $source.Literals[$literalName]
            if ($metadata.Contains($field) -and $metadata[$field] -cne $value) {
                $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_SOURCE' -Message "$field must match the existing Bicep literal; the backfill does not rewrite metadata literals."))
            }
            $metadata[$field] = $value
            continue
        }
        if ($metadata.Contains($field)) {
            continue
        }
        try {
            $value = Get-AvmMetadataBackfillValue -Record $LegacyRecord -Name $fields[$field]
            if ($null -ne $value) {
                if ($field -eq 'alternativeNames') {
                    $metadata[$field] = @($value.Split(',').Trim() | Where-Object { $_.Length -gt 0 } | Select-Object -Unique)
                }
                else {
                    $metadata[$field] = $value
                }
            }
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_LEGACY' -Message "$field : $($_.Exception.Message)"))
        }
    }

    if (-not $metadata.Contains('canonicalType')) {
        try {
            $canonicalType = Get-AvmMetadataBackfillValue -Record $LegacyRecord -Name @('CanonicalType')
            if ($canonicalType) {
                $metadata.canonicalType = $canonicalType
            }
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_LEGACY' -Message $_.Exception.Message))
        }
    }
    if (-not $metadata.Contains('canonicalType')) {
        if ($ModuleType -eq 'resource') {
            try {
                $provider = Get-AvmMetadataBackfillValue -Record $LegacyRecord -Name @('ProviderNamespace')
                $resourceType = Get-AvmMetadataBackfillValue -Record $LegacyRecord -Name @('ProviderResourceType', 'ResourceType')
                if ($provider -and $resourceType) {
                    $metadata.canonicalType = "$provider/$resourceType"
                }
                elseif ($ChildModule -and $Ecosystem -eq 'bicep' -and $null -ne $source -and
                    -not $source.UnresolvedResource -and $source.CanonicalTypes.Count -eq 1) {
                    $metadata.canonicalType = $source.CanonicalTypes[0]
                }
            }
            catch [System.ArgumentException] {
                $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_LEGACY' -Message "canonicalType : $($_.Exception.Message)"))
            }
        }
        elseif ($Ecosystem -eq 'bicep' -and $ModuleId -cmatch '^avm/(ptn|utl)/(?<taxonomy>[a-z0-9-]+(?:/[a-z0-9-]+)+)$') {
            $metadata.canonicalType = $Matches.taxonomy
        }
        elseif ($Ecosystem -eq 'terraform' -and $ModuleId -cmatch '^avm-(ptn|utl)-(?<group>[a-z0-9]+)-(?<name>[a-z0-9]+)$') {
            $metadata.canonicalType = "$($Matches.group)/$($Matches.name)"
        }
    }

    if ($null -ne $source) {
        if ($source.TelemetryPrefixes.Count -eq 1) {
            if ($Override.Contains('telemetryIdPrefix') -and $Override.telemetryIdPrefix -cne $source.TelemetryPrefixes[0]) {
                $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_TELEMETRY' -Message 'telemetryIdPrefix conflicts with the existing source prefix; preserve it or review the source separately.'))
            }
            $metadata.telemetryIdPrefix = $source.TelemetryPrefixes[0]
        }
        elseif (-not $metadata.Contains('telemetryIdPrefix')) {
            $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
            if ($Ecosystem -eq 'terraform' -and -not $ChildModule -and -not $source.TelemetryPresent -and
                $ModuleType -ne 'utility' -and $ModuleId -cmatch "^avm-$kind-(?<logical>[a-z0-9-]+)$") {
                $metadata.telemetryIdPrefix = "46d3xtrf.$kind.$($Matches.logical)"
            }
            elseif ($source.TelemetryPresent) {
                $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_TELEMETRY' -Message 'Existing telemetry cannot be read losslessly; supply a telemetryIdPrefix and leave source wiring disabled until reviewed.'))
            }
        }
    }

    if (-not $ChildModule) {
        $handles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $owners = [System.Collections.Generic.List[string]]::new()
        $candidates = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $LegacyRecord) {
            foreach ($names in @(
                    @('PrimaryModuleOwnerGHHandle', 'PrimaryOwnerGitHubHandle'),
                    @('SecondaryModuleOwnerGHHandle', 'SecondaryOwnerGitHubHandle')
                )) {
                try {
                    $handle = Get-AvmMetadataBackfillValue -Record @($row) -Name $names
                    if ($handle) {
                        $candidates.Add($handle)
                    }
                }
                catch [System.ArgumentException] {
                    $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_OWNER' -Message $_.Exception.Message))
                }
            }
        }
        if ($metadata.Contains('owners')) {
            if ($metadata.owners -isnot [array]) {
                $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_OWNER' -Message 'Owner overrides must be an array of usernames or qualified team handles.'))
            }
            else {
                foreach ($owner in $metadata.owners) {
                    $candidates.Add($owner)
                }
            }
        }
        foreach ($handle in $OwnerGitHubHandle) {
            $candidates.Add($handle)
        }
        try {
            $team = Get-AvmMetadataBackfillValue -Record $LegacyRecord -Name @('ModuleOwnersGHTeam')
            if ($team) {
                $candidates.Add($team)
            }
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_OWNER' -Message $_.Exception.Message))
        }
        foreach ($handle in $candidates) {
            $valid = $handle -is [string] -and (
                ($handle.Length -le 39 -and $handle -cmatch '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$') -or
                $handle -cmatch '^@[A-Za-z0-9]+(-[A-Za-z0-9]+)*/[a-z0-9]+(-[a-z0-9]+)*$'
            )
            if (-not $valid) {
                $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_OWNER' -Message 'An owner must be a GitHub username or a qualified @organization/team-slug string.'))
            }
            elseif ($handles.Add($handle)) {
                $owners.Add($handle)
            }
        }
        $metadata.owners = $owners.ToArray()
    }

    $required = @('moduleDisplayName', 'moduleDescription', 'canonicalType')
    foreach ($field in $required) {
        if (-not $metadata.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$metadata[$field])) {
            $issues.Add((New-AvmMetadataBackfillIssue -Code 'AVM_METADATA_REQUIRED' -Message "Cannot infer $field losslessly for '$ModuleId'; supply an explicit value."))
        }
    }
    return [pscustomobject]@{ Candidate = $metadata; Issues = $issues.ToArray() }
}
