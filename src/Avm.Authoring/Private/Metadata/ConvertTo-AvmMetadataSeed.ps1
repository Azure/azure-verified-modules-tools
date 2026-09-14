function ConvertTo-AvmMetadataSeed {
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
    $seed = [ordered]@{ '$schema' = $schema.'$id'; schemaVersion = 1 }
    foreach ($key in $Override.Keys) {
        if ($allowed -cnotcontains $key) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_OVERRIDE' -Message "Unsupported $shape override field '$key'."))
        }
        else {
            $seed[$key] = $Override[$key]
        }
    }

    $source = $null
    try {
        $source = Get-AvmMetadataSeedSource -Path $Path -Ecosystem $Ecosystem
    }
    catch [System.ArgumentException] {
        $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_SOURCE' -Message $_.Exception.Message))
    }
    $fields = [ordered]@{
        moduleDisplayName = @('ModuleDisplayName')
        moduleDescription = @('ModuleDescription')
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
            if ($seed.Contains($field) -and $seed[$field] -cne $value) {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_SOURCE' -Message "$field must match the existing Bicep literal; the backfill does not rewrite metadata literals."))
            }
            $seed[$field] = $value
            continue
        }
        if ($seed.Contains($field)) {
            continue
        }
        try {
            $value = Get-AvmMetadataSeedLegacyValue -Record $LegacyRecord -Name $fields[$field]
            if ($null -ne $value) {
                $seed[$field] = if ($field -eq 'alternativeNames') {
                    @($value.Split(',').Trim() | Where-Object { $_.Length -gt 0 } | Select-Object -Unique)
                }
                else { $value }
            }
        }
        catch [System.ArgumentException] {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_LEGACY' -Message "$field : $($_.Exception.Message)"))
        }
    }

    if (-not $seed.Contains('canonicalType')) {
        if ($ModuleType -eq 'resource') {
            try {
                $provider = Get-AvmMetadataSeedLegacyValue -Record $LegacyRecord -Name @('ProviderNamespace')
                $resourceType = Get-AvmMetadataSeedLegacyValue -Record $LegacyRecord -Name @('ProviderResourceType', 'ResourceType')
                if ($provider -and $resourceType) {
                    $seed.canonicalType = "$provider/$resourceType"
                }
                elseif ($ChildModule -and $Ecosystem -eq 'bicep' -and $null -ne $source -and
                    -not $source.UnresolvedResource -and $source.CanonicalTypes.Count -eq 1) {
                    $seed.canonicalType = $source.CanonicalTypes[0]
                }
            }
            catch [System.ArgumentException] {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_LEGACY' -Message "canonicalType : $($_.Exception.Message)"))
            }
        }
        elseif ($Ecosystem -eq 'bicep' -and $ModuleId -cmatch '^avm/(ptn|utl)/(?<taxonomy>[a-z0-9-]+(?:/[a-z0-9-]+)+)$') {
            $seed.canonicalType = $Matches.taxonomy
        }
    }

    if ($null -ne $source) {
        if ($source.TelemetryPrefixes.Count -eq 1) {
            if ($seed.Contains('telemetryIdPrefix') -and $seed.telemetryIdPrefix -cne $source.TelemetryPrefixes[0]) {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_TELEMETRY' -Message 'telemetryIdPrefix conflicts with the existing source prefix; preserve it or review the source separately.'))
            }
            else {
                $seed.telemetryIdPrefix = $source.TelemetryPrefixes[0]
            }
        }
        elseif (-not $seed.Contains('telemetryIdPrefix')) {
            $kind = @{ resource = 'res'; pattern = 'ptn'; utility = 'utl' }[$ModuleType]
            if ($Ecosystem -eq 'terraform' -and -not $ChildModule -and -not $source.TelemetryPresent -and
                $ModuleType -ne 'utility' -and $ModuleId -cmatch "^avm-$kind-(?<logical>[a-z0-9-]+)$") {
                $seed.telemetryIdPrefix = "46d3xtrf.$kind.$($Matches.logical)"
            }
            elseif ($source.TelemetryPresent) {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_TELEMETRY' -Message 'Existing telemetry cannot be read losslessly; supply a reviewed telemetryIdPrefix and leave source wiring disabled until reviewed.'))
            }
        }
    }

    if (-not $ChildModule) {
        if (-not $seed.Contains('tier')) {
            $seed.tier = 'maintained'
        }
        $ownerOverride = if ($seed.Contains('owners')) { $seed.owners } else { @{} }
        $handles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $individuals = [System.Collections.Generic.List[object]]::new()
        $candidates = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $LegacyRecord) {
            foreach ($names in @(
                    @('PrimaryModuleOwnerGHHandle', 'PrimaryOwnerGitHubHandle'),
                    @('SecondaryModuleOwnerGHHandle', 'SecondaryOwnerGitHubHandle')
                )) {
                try {
                    $handle = Get-AvmMetadataSeedLegacyValue -Record @($row) -Name $names
                    if ($handle) {
                        $candidates.Add($handle)
                    }
                }
                catch [System.ArgumentException] {
                    $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_OWNER' -Message $_.Exception.Message))
                }
            }
        }
        if ($ownerOverride -isnot [System.Collections.IDictionary] -or
            @($ownerOverride.Keys | Where-Object { $_ -cnotin @('individuals', 'team') }).Count -gt 0) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_OWNER' -Message 'Owner overrides accept individuals and team only, never personal names.'))
            $ownerOverride = @{}
        }
        foreach ($owner in @($ownerOverride['individuals'])) {
            if ($null -eq $owner) {
                continue
            }
            if ($owner -isnot [System.Collections.IDictionary] -or @($owner.Keys) -cnotcontains 'githubHandle' -or
                @($owner.Keys | Where-Object { $_ -cne 'githubHandle' }).Count -gt 0) {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_OWNER' -Message 'Owner individuals must contain githubHandle only, never personal names.'))
                continue
            }
            $candidates.Add([string]$owner.githubHandle)
        }
        foreach ($handle in $OwnerGitHubHandle) {
            $candidates.Add($handle)
        }
        foreach ($handle in $candidates) {
            if ($handle -cnotmatch '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$' -or $handle.Length -gt 39) {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_OWNER' -Message 'A supplied owner is not a valid GitHub handle; provide a reviewed handle-only mapping.'))
            }
            elseif ($handles.Add($handle)) {
                $individuals.Add([ordered]@{ githubHandle = $handle })
            }
        }
        $seed.owners = [ordered]@{ individuals = $individuals.ToArray() }
        if ($ownerOverride.Contains('team')) {
            $seed.owners.team = $ownerOverride.team
        }
        else {
            try {
                $team = Get-AvmMetadataSeedLegacyValue -Record $LegacyRecord -Name @('ModuleOwnersGHTeam')
                if ($team) {
                    $seed.owners.team = $team
                }
            }
            catch [System.ArgumentException] {
                $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_OWNER' -Message $_.Exception.Message))
            }
        }
    }

    foreach ($field in @('moduleDisplayName', 'moduleDescription', 'canonicalType') + $(if ($ModuleType -ne 'utility') { @('telemetryIdPrefix') } else { @() })) {
        if (-not $seed.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$seed[$field])) {
            $issues.Add((New-AvmMetadataIssue -Code 'AVM_SEED_REQUIRED' -Message "Cannot infer $field losslessly for '$ModuleId'; supply a reviewed override."))
        }
    }
    return [pscustomobject]@{ Candidate = $seed; Issues = $issues.ToArray() }
}
