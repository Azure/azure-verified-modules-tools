#Requires -Version 7.4

<#
.SYNOPSIS
    Inspect four local state images after an operator-staged Terraform state move.
.DESCRIPTION
    Reads local files only. Original hashes and identity values must come from
    separately verified, frozen inventory. This does not authorize cutover,
    connect to a backend, move state, or prove the files came from that backend.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceBefore,
    [Parameter(Mandatory)] [string] $DestinationBefore,
    [Parameter(Mandatory)] [string] $SourceAfter,
    [Parameter(Mandatory)] [string] $DestinationAfter,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{64}$')] [string] $SourceSha256,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{64}$')] [string] $DestinationSha256,
    [Parameter(Mandatory)] [ValidatePattern('^Azure/terraform-(azurerm|azure|azapi)-avm-(res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*$')] [string] $Repository,
    [Parameter(Mandatory)] [System.Collections.IDictionary] $Identity
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'StateImages.ps1')

$source = Read-TransferImage $SourceBefore
$destination = Read-TransferImage $DestinationBefore
$drained = Read-TransferImage $SourceAfter
$merged = Read-TransferImage $DestinationAfter
if ($source.Hash -ine $SourceSha256 -or $destination.Hash -ine $DestinationSha256) {
    throw 'An original snapshot does not match its frozen inventory hash.'
}
if ($source.State['lineage'] -ceq $destination.State['lineage']) {
    throw 'Source and destination must be independently verified states with different lineages.'
}
foreach ($field in @('tenant_id', 'client_id', 'principal_id')) {
    $id = [guid]::Empty
    if (-not [guid]::TryParseExact([string]$Identity[$field], 'D', [ref]$id) -or $id -eq [guid]::Empty) {
        throw "Frozen identity inventory requires a nonempty GUID for $field."
    }
}
if ([string]$Identity['repository_id'] -cnotmatch '^[1-9][0-9]*$' -or
    [string]$Identity['repository_owner_id'] -cnotmatch '^[1-9][0-9]*$') {
    throw 'Frozen identity inventory requires the verified GitHub repository and owner IDs.'
}
$identitySuffix = '/providers/Microsoft.ManagedIdentity/userAssignedIdentities/' + $Repository.Replace('/', '-').Replace('windows', 'w5s')
if ([string]$Identity['identity_resource_id'] -cnotmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/' -or
    -not ([string]$Identity['identity_resource_id']).EndsWith($identitySuffix, [StringComparison]::Ordinal)) {
    throw 'Frozen identity inventory must identify the selected repository UAMI.'
}
$identityResources = @($source.State['resources'] | Where-Object {
    $_['module'] -ceq 'module.azure' -and $_['mode'] -ceq 'managed' -and $_['type'] -ceq 'azapi_resource' -and $_['name'] -ceq 'identity'
})
if ($identityResources.Count -ne 1 -or $identityResources[0]['instances'].Count -ne 1) {
    throw 'The source must contain exactly one dedicated repository identity; partial or already-cut-over inputs require review.'
}
$attributes = $identityResources[0]['instances'][0]['attributes']
$output = $attributes['output']
if ($output -is [System.Collections.IDictionary] -and $output.Contains('type') -and $output.Contains('value')) {
    $output = $output['value']
}
if ($output -isnot [System.Collections.IDictionary] -or $output['properties'] -isnot [System.Collections.IDictionary] -or
    $attributes['id'] -ine $Identity['identity_resource_id'] -or
    $output['properties']['clientId'] -ine $Identity['client_id'] -or
    $output['properties']['principalId'] -ine $Identity['principal_id'] -or
    $output['properties']['tenantId'] -ine $Identity['tenant_id']) {
    throw 'Source identity IDs or tenant do not match the frozen inventory.'
}
$identityOutput = $source.State['outputs']['test_identity']
if ($identityOutput -isnot [System.Collections.IDictionary] -or $identityOutput['value'] -isnot [System.Collections.IDictionary]) {
    throw 'A partial source without its identity output requires separate operator review.'
}
foreach ($field in @('identity_resource_id', 'tenant_id', 'client_id', 'repository_id', 'repository_owner_id')) {
    if ([string]$identityOutput['value'][$field] -ine [string]$Identity[$field]) {
        throw 'Source identity output does not match the frozen GitHub and BAMI inventory.'
    }
}
$repositories = @($destination.State['resources'] | Where-Object {
    $_['module'] -ceq 'module.github' -and $_['type'] -ceq 'github_repository' -and $_['name'] -ceq 'this'
})
if ($repositories.Count -ne 1 -or $repositories[0]['instances'].Count -ne 1 -or
    [string]$repositories[0]['instances'][0]['attributes']['repo_id'] -cne [string]$Identity['repository_id'] -or
    $repositories[0]['instances'][0]['attributes']['full_name'] -cne $Repository) {
    throw 'Destination GitHub ownership does not match the selected repository; an absent destination needs a separate frozen-inventory procedure.'
}
$expectedResources = @{}
$ownedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($entry in @(@{ Image = $source; Source = $true }, @{ Image = $destination; Source = $false })) {
    foreach ($resource in $entry.Image.State['resources']) {
        $module = [string]$resource['module']
        if (($entry.Source -and $module -cne 'module.azure') -or
            (-not $entry.Source -and $module -cmatch '^module\.bami(?:$|\.|\[)')) {
            throw 'Unexpected, split, or partially consolidated namespace; stop before publication.'
        }
        if ($entry.Source) {
            $provider = if ($resource['type'] -cmatch '^azapi_') { 'provider["registry.terraform.io/azure/azapi"]' }
            elseif ($resource['type'] -cmatch '^azuread_') { 'provider["registry.terraform.io/hashicorp/azuread"]' }
            else { throw 'Unexpected source resource type requires operator review.' }
            if ($resource['provider'] -cne $provider) { throw 'Unexpected source provider binding requires operator review.' }
        }
        if ($resource['mode'] -ceq 'managed') {
            foreach ($instance in $resource['instances']) {
                if (-not $ownedIds.Add((Get-TransferManagedObjectKey -Resource $resource -Instance $instance))) {
                    throw 'Multiple addresses own the same managed object; resolve the legacy ownership collision separately.'
                }
            }
        }
        if ($entry.Source -and $resource['type'] -ceq 'azuread_group_member') {
            foreach ($instance in $resource['instances']) {
                if ($instance['attributes']['member_object_id'] -ine $Identity['principal_id']) {
                    throw 'A foreign membership principal requires operator review.'
                }
            }
        }
        if (-not $entry.Source) {
            foreach ($instance in $resource['instances']) {
                if ($instance['attributes']['id'] -ieq $Identity['identity_resource_id']) {
                    throw 'The destination already owns the live BAMI identity under another address.'
                }
            }
        }
        if ($entry.Source) { $resource['module'] = 'module.bami[0]' }
        foreach ($instance in $resource['instances']) {
            # Native state mv clears affected dependency caches; the first guarded apply rebuilds them.
            if (@($instance['dependencies'] | Where-Object { $_ -cmatch '^module\.azure(?:$|\.|\[)' }).Count -gt 0) {
                $instance.Remove('dependencies')
            }
            if (-not $instance.Contains('identity_schema_version')) { $instance['identity_schema_version'] = 0 }
        }
        $key = Get-TransferResourceKey $resource
        if ($expectedResources.ContainsKey($key)) { throw 'Duplicate resource address in the original snapshots.' }
        $expectedResources[$key] = $resource
    }
}
if ($drained.State['resources'].Count -ne 0 -or $merged.State['resources'].Count -ne $expectedResources.Count) {
    throw 'Incomplete transfer: source must be drained and destination must contain every original resource.'
}
foreach ($resource in $merged.State['resources']) {
    $key = Get-TransferResourceKey $resource
    if (-not $expectedResources.ContainsKey($key)) { throw 'Unexpected resource address after the staged move.' }
    foreach ($image in @($resource, $expectedResources[$key])) {
        $image['instances'] = @($image['instances'] | Sort-Object { ConvertTo-Json -InputObject $_['index_key'] -Compress })
    }
    Assert-TransferValueEqual $resource $expectedResources[$key] "Resource $key (including private data)"
    $expectedResources.Remove($key)
}
foreach ($pair in @(@{ Before = $source; After = $drained }, @{ Before = $destination; After = $merged })) {
    if ($pair.After.State['lineage'] -cne $pair.Before.State['lineage'] -or
        $pair.After.State['serial'] -ne $pair.Before.State['serial'] + 1) {
        throw 'Lineage or serial does not match exactly one native state move.'
    }
    Assert-TransferValueEqual (Get-TransferSnapshotMetadata $pair.After.State) `
        (Get-TransferSnapshotMetadata $pair.Before.State) 'Snapshot metadata'
}
[pscustomobject]@{
    Status = 'Local transfer images verified; backend provenance and cutover are not approved'
    Repository = $Repository
    SourceAfterSha256 = $drained.Hash
    DestinationAfterSha256 = $merged.Hash
    SourceLineage = $drained.State['lineage']
    SourceSerial = $drained.State['serial']
    DestinationLineage = $merged.State['lineage']
    DestinationSerial = $merged.State['serial']
    ResourceBlocks = $merged.State['resources'].Count
}
