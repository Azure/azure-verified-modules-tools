<#
.SYNOPSIS
    Prepare a deterministic manifest and unresolved-field report without changing modules.
#>
#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][ValidateSet('bicep', 'terraform')][string] $Ecosystem,
    [string[]] $LegacyCsvPath = @(),
    [string] $OverridePath,
    [string] $OwnerMappingPath,
    [string] $BicepOwnerSnapshotPath,
    [string] $OutputPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'MetadataBackfill.ps1')
if ($BicepOwnerSnapshotPath -and $Ecosystem -ne 'bicep') {
    throw [System.ArgumentException]::new('BicepOwnerSnapshotPath is supported only for Bicep seed preparation.')
}
if (-not (Get-Module -Name Avm.Authoring)) {
    Import-Module Avm.Authoring -ErrorAction Stop
}
Assert-AvmMetadataBackfillCapability
$root = Resolve-AvmMetadataBackfillRoot -Path $RepositoryRoot
$modules = @(Get-AvmMetadataBackfillModule -Root $root -Ecosystem $Ecosystem -Repository $Repository)
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($csv in $LegacyCsvPath) {
    foreach ($row in Import-Csv -LiteralPath $csv) {
        $record = @{}
        foreach ($property in $row.PSObject.Properties) {
            $record[$property.Name] = $property.Value
        }
        $rows.Add($record)
    }
}

$overrides = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
if ($OverridePath) {
    $overrideFile = Read-AvmMetadataBackfillJson -Path $OverridePath
    Assert-AvmMetadataBackfillShape -Value $overrideFile -Required @('schemaVersion', 'repository', 'ecosystem', 'reviewed', 'modules') -Label 'Override manifest'
    if ($overrideFile.schemaVersion -ne 1 -or $overrideFile.repository -cne $Repository -or $overrideFile.ecosystem -cne $Ecosystem -or
        $overrideFile.reviewed -isnot [bool] -or -not $overrideFile.reviewed -or $overrideFile.modules -isnot [array]) {
        throw [System.ArgumentException]::new('Overrides must be a reviewed v1 manifest for this repository and ecosystem.')
    }
    foreach ($entry in $overrideFile.modules) {
        Assert-AvmMetadataBackfillShape -Value $entry -Required @('path', 'metadata') -Optional @('updateSource', 'descriptionSource') -Label 'Override'
        if ($entry.path -isnot [string] -or $entry.metadata -isnot [System.Collections.IDictionary] -or
            ($entry.Contains('updateSource') -and $entry.updateSource -isnot [bool])) {
            throw [System.ArgumentException]::new('Overrides require a module path, metadata object, and optional boolean updateSource.')
        }
        $null = Resolve-AvmMetadataBackfillPath -Root $root -RelativePath $entry.path
        if (@($modules.Path) -cnotcontains $entry.path -or -not $overrides.TryAdd($entry.path, $entry)) {
            throw [System.ArgumentException]::new("Unknown or duplicate override module '$($entry.path)'.")
        }
    }
}

$ownerMappings = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
if ($OwnerMappingPath) {
    $owners = Read-AvmMetadataBackfillJson -Path $OwnerMappingPath
    Assert-AvmMetadataBackfillShape -Value $owners -Required @('schemaVersion', 'repository', 'reviewed', 'modules') -Label 'Owner mapping'
    if ($owners.schemaVersion -ne 1 -or $owners.repository -cne $Repository -or $owners.reviewed -isnot [bool] -or
        -not $owners.reviewed -or $owners.modules -isnot [array]) {
        throw [System.ArgumentException]::new('Owner mappings must be a reviewed v1 handle-only snapshot for this repository.')
    }
    foreach ($entry in $owners.modules) {
        Assert-AvmMetadataBackfillShape -Value $entry -Required @('path', 'githubHandles') -Label 'Owner mapping entry'
        if ($entry.path -isnot [string] -or $entry.githubHandles -isnot [array] -or
            @($entry.githubHandles | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$' -or $_.Length -gt 39 }).Count -gt 0) {
            throw [System.ArgumentException]::new('Owner mappings accept GitHub handle strings only, not personal names.')
        }
        $family = @($modules | Where-Object { $_.Path -ceq $entry.path -and $null -eq $_.ParentPath })
        if ($family.Count -ne 1 -or -not $ownerMappings.TryAdd($entry.path, $entry.githubHandles)) {
            throw [System.ArgumentException]::new("Unknown, child, or duplicate owner mapping '$($entry.path)'.")
        }
    }
}

$recordsByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($module in $modules) {
    $recordsByPath.Add($module.Path, @(Get-AvmMetadataBackfillLegacyRecord -Record $rows.ToArray() `
                -Module $module -Repository $Repository -Ecosystem $Ecosystem))
}
$snapshotMapping = $null
$snapshotIssues = @()
if ($BicepOwnerSnapshotPath) {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'BicepOwnerSnapshot.ps1')
    $snapshot = Read-AvmBicepOwnerSnapshot -Path $BicepOwnerSnapshotPath
    $snapshotMapping = Get-AvmBicepOwnerSnapshotMapping -Snapshot $snapshot -Module $modules -LegacyRecordByPath $recordsByPath
    $snapshotIssues = @($snapshotMapping.Summary.Issues)
}

$entries = [System.Collections.Generic.List[object]]::new()
$reports = [System.Collections.Generic.List[object]]::new()
foreach ($module in $modules) {
    $recordMatches = @($recordsByPath[$module.Path])
    $override = [ordered]@{}
    $updateSource = $false
    $descriptionSource = $null
    if ($overrides.ContainsKey($module.Path)) {
        $entry = $overrides[$module.Path]
        foreach ($key in $entry.metadata.Keys) {
            $override[$key] = $entry.metadata[$key]
        }
        if ($entry.Contains('updateSource')) {
            $updateSource = $entry.updateSource
        }
        if ($entry.Contains('descriptionSource')) {
            if ($override.Contains('moduleDescription')) {
                throw [System.ArgumentException]::new("Module '$($module.Path)' specifies both moduleDescription and descriptionSource.")
            }
            $descriptionSource = $entry.descriptionSource
        }
    }
    if ($Ecosystem -eq 'terraform' -and -not $override.Contains('moduleDescription')) {
        $legacyDescriptions = @($recordMatches | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_['ModuleDescription']) })
        if ($descriptionSource -or $legacyDescriptions.Count -eq 0) {
            $description = Get-AvmMetadataBackfillDescription -Root $root -ModulePath $module.Path -Source $descriptionSource
            if ($description) {
                $override.moduleDescription = $description
            }
        }
    }
    elseif ($descriptionSource) {
        throw [System.ArgumentException]::new('Bicep descriptions must come from the existing metadata literal, not descriptionSource.')
    }
    $handles = @(if ($ownerMappings.ContainsKey($module.Path)) { $ownerMappings[$module.Path] })
    $snapshotAssignment = $null
    $removedLegacyTeams = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($snapshotMapping -and $null -eq $module.ParentPath) {
        if ($snapshotMapping.ByPath.ContainsKey($module.Path)) {
            $snapshotAssignment = $snapshotMapping.ByPath[$module.Path]
            $handles += @($snapshotAssignment.Team.GitHubHandles)
        }
        $recordMatches = @(
            foreach ($record in $recordMatches) {
                $copy = @{} + $record
                $slug = ConvertTo-AvmBicepOwnerTeamSlug -Reference $copy['ModuleOwnersGHTeam']
                if ($slug -and ($snapshotMapping.Slugs.Contains($slug) -or $slug.EndsWith('-module-owners-bicep', [System.StringComparison]::Ordinal))) {
                    $copy['ModuleOwnersGHTeam'] = ''
                    $null = $removedLegacyTeams.Add($slug)
                }
                $copy
            }
        )
        if ($override.Contains('owners') -and $override.owners -is [System.Collections.IDictionary]) {
            $slug = ConvertTo-AvmBicepOwnerTeamSlug -Reference $override.owners['team']
            if ($slug -and ($snapshotMapping.Slugs.Contains($slug) -or $slug.EndsWith('-module-owners-bicep', [System.StringComparison]::Ordinal))) {
                throw [System.ArgumentException]::new("$($module.Path): owners.team must not reference a deleted per-module Bicep team. Remove the team override; snapshot members become individuals.")
            }
        }
    }
    $existingMetadata = Test-Path -LiteralPath (Join-Path -Path $module.FullPath -ChildPath 'metadata.json') -PathType Leaf
    $seed = New-AvmModuleMetadataSeed -Path $module.FullPath -ModuleId $module.ModuleId -Ecosystem $Ecosystem `
        -ModuleType $module.ModuleType -ChildModule:($null -ne $module.ParentPath) `
        -LegacyRecord $recordMatches -Override $override -OwnerGitHubHandle $handles -SkipModuleVersionCheck
    $moduleReport = [ordered]@{
        path       = $module.Path
        parentPath = $module.ParentPath
        status     = $seed.Status
        issues     = $seed.Issues
        candidate  = $seed.Candidate
    }
    if ($snapshotMapping) {
        $enrichment = [ordered]@{
            status                      = if ($null -ne $module.ParentPath) { 'inherited' } else { 'not-matched' }
            teamSlug                    = $null
            matchMethod                 = $null
            memberCount                 = 0
            missingSnapshotHandles      = @()
            removedLegacyTeamReferences = @(if (-not $existingMetadata) { $removedLegacyTeams | Sort-Object -CaseSensitive })
            unmatchedLegacyTeams        = @()
        }
        if ($snapshotAssignment) {
            $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            if ($seed.Status -eq 'pass') {
                foreach ($owner in $seed.Metadata.owners.individuals) {
                    $null = $present.Add($owner.githubHandle)
                }
            }
            $enrichment.status = if ($seed.Status -ne 'pass') { 'blocked' } elseif ($existingMetadata) { 'skipped-existing-metadata' } else { 'seeded' }
            $enrichment.teamSlug = $snapshotAssignment.Team.Slug
            $enrichment.matchMethod = $snapshotAssignment.Method
            $enrichment.memberCount = $snapshotAssignment.Team.GitHubHandles.Count
            $enrichment.unmatchedLegacyTeams = $snapshotAssignment.UnmatchedLegacyTeams
            $enrichment.missingSnapshotHandles = @($snapshotAssignment.Team.GitHubHandles | Where-Object { -not $present.Contains($_) })
            if ($seed.Status -eq 'pass' -and -not $existingMetadata -and $enrichment.missingSnapshotHandles.Count -gt 0) {
                throw [System.InvalidOperationException]::new("$($module.Path): seed conversion omitted snapshot handles; no manifest was written.")
            }
            if ($existingMetadata) {
                $moduleReport.issues = @($moduleReport.issues) + @([pscustomobject]@{
                        Code     = 'AVM_OWNER_ENRICHMENT_SKIPPED'
                        Severity = 'warning'
                        Message  = "$($module.Path): existing metadata was preserved; snapshot enrichment was skipped. $($enrichment.missingSnapshotHandles.Count) snapshot handle(s) require manual review."
                    })
            }
        }
        $moduleReport.ownerSnapshot = $enrichment
    }
    $reports.Add([pscustomobject]$moduleReport)
    if ($seed.Status -eq 'pass') {
        $entries.Add([ordered]@{
                path         = $module.Path
                moduleType   = $module.ModuleType
                parentPath   = $module.ParentPath
                updateSource = $updateSource
                metadata     = $seed.Metadata
            })
    }
}
$failed = @($reports | Where-Object { $_.status -ne 'pass' })
$success = $failed.Count -eq 0 -and $snapshotIssues.Count -eq 0
$manifest = if ($success) {
    [ordered]@{
        schemaVersion = 1
        repository    = $Repository
        ecosystem     = $Ecosystem
        reviewed      = $false
        modules       = $entries.ToArray()
    }
}
else { $null }
if ($OutputPath) {
    if (-not $success) {
        $details = (@($failed | ForEach-Object { "$($_.path): $($_.issues.Message -join ' ')" }) +
            @($snapshotIssues | ForEach-Object { $_.Message })) -join "`n"
        throw [System.ArgumentException]::new("Seed preparation failed; no manifest or module files were written.`n$details")
    }
    $outputParent = Split-Path -Parent $OutputPath
    if (-not $outputParent) {
        $outputParent = $PWD.Path
    }
    $parent = Resolve-AvmMetadataBackfillRoot -Path $outputParent
    $output = Resolve-AvmMetadataBackfillPath -Root $parent -RelativePath (Split-Path -Leaf $OutputPath) -AllowMissingLeaf
    if ([System.IO.Path]::GetExtension($output) -cne '.json') {
        throw [System.ArgumentException]::new('The review manifest output must be a .json file.')
    }
    $relativeOutput = [System.IO.Path]::GetRelativePath($root, $output)
    if ($relativeOutput -eq '.' -or (-not [System.IO.Path]::IsPathRooted($relativeOutput) -and
            $relativeOutput -notmatch '^\.\.[\\/]')) {
        throw [System.ArgumentException]::new('Write the review manifest outside the module checkout, not beside module source.')
    }
    if (Test-Path -LiteralPath $output) {
        throw [System.IO.IOException]::new("Output already exists and will not be overwritten: $output")
    }
    if ($PSCmdlet.ShouldProcess($output, 'Write unreviewed metadata seed manifest')) {
        [System.IO.File]::WriteAllText($output, (ConvertTo-Json -InputObject $manifest -Depth 50).Replace("`r`n", "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    }
}
$report = [ordered]@{
    Status   = if ($success) { 'pass' } else { 'fail' }
    Manifest = $manifest
    Modules  = $reports.ToArray()
}
if ($snapshotMapping) {
    $report.OwnerSnapshot = $snapshotMapping.Summary
}
[pscustomobject]$report
