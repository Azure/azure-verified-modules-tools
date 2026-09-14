function ConvertTo-AvmModuleMetadata {
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
    $Override = ConvertFrom-AvmMetadataJson -Json (ConvertTo-Json -InputObject $Override -Depth 50)
    $issues = [System.Collections.Generic.List[object]]::new()
    $schemaPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Resources', 'Schemas', 'v1', 'avm-module-metadata.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
    $shape = if ($ChildModule) { 'child' } else { 'root' }
    $allowed = @($schema.definitions[$shape].properties.Keys)
    $metadata = [ordered]@{ '$schema' = $schema.'$id'; schemaVersion = 1 }
    foreach ($key in $Override.Keys) {
        if ($allowed -cnotcontains $key) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_OVERRIDE' -Message "Unsupported $shape override field '$key'."))
        }
        else {
            $metadata[$key] = $Override[$key]
        }
    }

    $source = $null
    try {
        $source = Get-AvmMetadataSource -Path $Path -Ecosystem $Ecosystem
    }
    catch [System.ArgumentException] {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_SOURCE' -Message $_.Exception.Message))
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
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_SOURCE' -Message "$field must match the existing Bicep literal; the backfill does not rewrite metadata literals."))
            }
            $metadata[$field] = $value
            continue
        }
        if ($metadata.Contains($field)) {
            continue
        }
        try {
            $value = Get-AvmLegacyMetadataValue -Record $LegacyRecord -Name $fields[$field]
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
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_LEGACY' -Message "$field : $($_.Exception.Message)"))
        }
    }

    if (-not $metadata.Contains('canonicalType')) {
        try {
            $canonicalType = Get-AvmLegacyMetadataValue -Record $LegacyRecord -Name @('CanonicalType')
            if ($canonicalType) {
                $metadata.canonicalType = $canonicalType
            }
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_LEGACY' -Message $_.Exception.Message))
        }
    }
    if (-not $metadata.Contains('canonicalType')) {
        if ($ModuleType -eq 'resource') {
            try {
                $provider = Get-AvmLegacyMetadataValue -Record $LegacyRecord -Name @('ProviderNamespace')
                $resourceType = Get-AvmLegacyMetadataValue -Record $LegacyRecord -Name @('ProviderResourceType', 'ResourceType')
                if ($provider -and $resourceType) {
                    $metadata.canonicalType = "$provider/$resourceType"
                }
                elseif ($ChildModule -and $Ecosystem -eq 'bicep' -and $null -ne $source -and
                    -not $source.UnresolvedResource -and $source.CanonicalTypes.Count -eq 1) {
                    $metadata.canonicalType = $source.CanonicalTypes[0]
                }
            }
            catch [System.ArgumentException] {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_LEGACY' -Message "canonicalType : $($_.Exception.Message)"))
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
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_TELEMETRY' -Message 'telemetryIdPrefix conflicts with the existing source prefix; preserve it or review the source separately.'))
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
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_TELEMETRY' -Message 'Existing telemetry cannot be read losslessly; supply a telemetryIdPrefix and leave source wiring disabled until reviewed.'))
            }
        }
    }

    if (-not $ChildModule) {
        if (-not $metadata.Contains('tier')) {
            $metadata.tier = 'maintained'
        }
        $ownerOverride = if ($metadata.Contains('owners')) { $metadata.owners } else { @{} }
        $handles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $individuals = [System.Collections.Generic.List[object]]::new()
        $candidates = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $LegacyRecord) {
            foreach ($names in @(
                    @('PrimaryModuleOwnerGHHandle', 'PrimaryOwnerGitHubHandle'),
                    @('SecondaryModuleOwnerGHHandle', 'SecondaryOwnerGitHubHandle')
                )) {
                try {
                    $handle = Get-AvmLegacyMetadataValue -Record @($row) -Name $names
                    if ($handle) {
                        $candidates.Add($handle)
                    }
                }
                catch [System.ArgumentException] {
                    $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_OWNER' -Message $_.Exception.Message))
                }
            }
        }
        if ($ownerOverride -isnot [System.Collections.IDictionary] -or
            @($ownerOverride.Keys | Where-Object { $_ -cnotin @('individuals', 'team') }).Count -gt 0) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_OWNER' -Message 'Owner overrides accept individuals and team only, never personal names.'))
            $ownerOverride = @{}
        }
        foreach ($owner in @($ownerOverride['individuals'])) {
            if ($null -eq $owner) {
                continue
            }
            if ($owner -isnot [System.Collections.IDictionary] -or @($owner.Keys) -cnotcontains 'githubHandle' -or
                @($owner.Keys | Where-Object { $_ -cne 'githubHandle' }).Count -gt 0) {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_OWNER' -Message 'Owner individuals must contain githubHandle only, never personal names.'))
                continue
            }
            $candidates.Add([string]$owner.githubHandle)
        }
        foreach ($handle in $OwnerGitHubHandle) {
            $candidates.Add($handle)
        }
        foreach ($handle in $candidates) {
            if ($handle -cnotmatch '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$' -or $handle.Length -gt 39) {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_OWNER' -Message 'A supplied owner is not a valid GitHub handle; provide a GitHub handle.'))
            }
            elseif ($handles.Add($handle)) {
                $individuals.Add([ordered]@{ githubHandle = $handle })
            }
        }
        $metadata.owners = [ordered]@{ individuals = $individuals.ToArray() }
        if ($ownerOverride.Contains('team')) {
            $metadata.owners.team = $ownerOverride.team
        }
        else {
            try {
                $team = Get-AvmLegacyMetadataValue -Record $LegacyRecord -Name @('ModuleOwnersGHTeam')
                if ($team) {
                    $metadata.owners.team = $team
                }
            }
            catch [System.ArgumentException] {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_OWNER' -Message $_.Exception.Message))
            }
        }
    }

    $required = @('moduleDisplayName', 'moduleDescription', 'canonicalType')
    if (Test-AvmMetadataTelemetryRequired -Path $Path -Ecosystem $Ecosystem -ModuleType $ModuleType -ChildModule:$ChildModule) {
        $required += 'telemetryIdPrefix'
    }
    foreach ($field in $required) {
        if (-not $metadata.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$metadata[$field])) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_METADATA_REQUIRED' -Message "Cannot infer $field losslessly for '$ModuleId'; supply a explicit value."))
        }
    }
    return [pscustomobject]@{ Candidate = $metadata; Issues = $issues.ToArray() }
}
