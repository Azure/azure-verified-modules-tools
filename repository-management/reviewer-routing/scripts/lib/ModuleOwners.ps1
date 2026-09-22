#Requires -Version 7.4

# Resolves the owners of a Bicep AVM module for PR/issue routing.
#
# Two sources, index-first with a fallback:
#  - The published module catalog (Azure-Verified-Modules v1/modules.json),
#    refreshed roughly every 4 hours, already carries GitHub-enriched
#    {handle, type, displayName} owner objects for every module.
#  - A direct read of the module's own metadata.json at the pull request head
#    commit, used when the module is absent from the (lagging) index, or the
#    change itself touches that module's metadata.json. metadata.json only
#    ever stores raw owner handle strings (bare username or @org/team-slug);
#    catalog enrichment happens later in the catalog pipeline, not here.
#
# Only the module's top-level metadata.json can declare owners -- the schema
# (avm-module-metadata.schema.json) forbids an "owners" property on child
# module metadata, so unlike the retired bicep-registry-modules script this
# never needs to walk up through intermediate folders.

$script:AvmReviewerRoutingCatalogRepository = 'Azure/Azure-Verified-Modules'
$script:AvmReviewerRoutingCatalogPath = 'docs/static/module-indexes/v1/modules.json'
$script:AvmReviewerRoutingCatalogRef = 'main'

function Get-AvmBicepTopLevelModulePath {
    <#
    .SYNOPSIS
    Reduces a changed-file path to its top-level AVM module folder, or
    returns $null when the path is not inside a module folder at all.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)

    $segments = @($Path.Trim('/') -split '/')
    if ($segments.Count -lt 4 -or $segments[0] -cne 'avm' -or $segments[1] -cnotin @('res', 'ptn', 'utl')) {
        return $null
    }
    return ($segments[0..3] -join '/')
}

function ConvertTo-AvmReviewerRoutingOwner {
    <#
    .SYNOPSIS
    Normalizes catalog owner entries. Requires the live {handle, type,
    displayName} object shape and throws on anything else, rather than
    silently skipping an owner it doesn't understand.

    .NOTES
    The catalog stores team handles with a leading '@' (for example
    '@Azure/team-slug'), matching metadata.json. That prefix is stripped
    here so both owner sources converge on the bare 'org/team-slug' form
    that `gh pr edit --add-reviewer` expects for teams.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()] [object[]] $Owners = @())

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($owner in $Owners) {
        $isRecord = $owner -is [System.Collections.IDictionary]
        if (-not $isRecord -or -not $owner.Contains('handle') -or -not $owner.Contains('type') -or
            [string]::IsNullOrWhiteSpace([string]$owner.handle)) {
            throw [System.IO.InvalidDataException]::new(
                "Catalog owners must be {handle,type,displayName} objects. Got: $($owner | ConvertTo-Json -Compress -Depth 4)")
        }
        if ($owner.type -cnotin @('user', 'team')) {
            throw [System.IO.InvalidDataException]::new(
                "Catalog owner '$($owner.handle)' has an unrecognized type '$($owner.type)'.")
        }
        $handle = [string]$owner.handle
        if ($owner.type -ceq 'team' -and $handle.StartsWith('@')) {
            $handle = $handle.Substring(1)
        }
        $result.Add([ordered]@{ Handle = $handle; Type = [string]$owner.type })
    }
    return $result.ToArray()
}

function ConvertTo-AvmReviewerRoutingMetadataOwner {
    <#
    .SYNOPSIS
    Normalizes raw metadata.json owner handle strings (bare username or
    @organization/team-slug) into the same {Handle, Type} shape used for
    catalog owners, deduplicated case-insensitively.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()] [object[]] $Owners = @(),
        [Parameter(Mandatory)] [string] $Source
    )

    $individualPattern = '^(?=.{1,39}$)[A-Za-z0-9]+(-[A-Za-z0-9]+)*$'
    $teamPattern = '^@[A-Za-z0-9]+(-[A-Za-z0-9]+)*/[a-z0-9]+(-[a-z0-9]+)*$'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($owner in $Owners) {
        if ([string]::IsNullOrWhiteSpace([string]$owner)) {
            continue
        }
        $handle = ([string] $owner).Trim()
        if ($handle -cmatch $teamPattern) {
            $normalized = $handle.Substring(1)
            $type = 'team'
        }
        elseif ($handle -cmatch $individualPattern) {
            $normalized = $handle
            $type = 'user'
        }
        else {
            throw [System.IO.InvalidDataException]::new("Invalid owner handle '$owner' in $Source.")
        }
        if ($seen.Add($normalized)) {
            $result.Add([ordered]@{ Handle = $normalized; Type = $type })
        }
    }
    return $result.ToArray()
}

function Get-AvmReviewerRoutingCatalogIndex {
    <#
    .SYNOPSIS
    Fetches and flattens the published module catalog into a modulePath ->
    catalog-entry index for one repository's Bicep modules.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Repository)

    $file = Get-AvmRepositoryFileAtRef -Repository $script:AvmReviewerRoutingCatalogRepository `
        -Path $script:AvmReviewerRoutingCatalogPath -Ref $script:AvmReviewerRoutingCatalogRef
    # The index has keys differing only by case (for example
    # "Microsoft.App/Jobs" vs "Microsoft.App/jobs"), which plain
    # ConvertFrom-Json throws on.
    $catalog = $file.Content | ConvertFrom-Json -AsHashtable -Depth 64
    if ($catalog -isnot [System.Collections.IDictionary] -or -not $catalog.Contains('modules')) {
        throw [System.IO.InvalidDataException]::new('Published module catalog is missing the expected modules map.')
    }

    $index = @{}
    foreach ($canonicalEntry in $catalog.modules.Values) {
        foreach ($bicepModule in @($canonicalEntry['bicep'])) {
            if ($bicepModule.repository -ceq $Repository) {
                $index[[string]$bicepModule.modulePath] = $bicepModule
            }
        }
    }
    return $index
}

function Get-AvmBicepModuleMetadataOwners {
    <#
    .SYNOPSIS
    Reads a top-level module's own metadata.json at a specific commit and
    returns its declared owners, normalized. An absent metadata.json (a
    brand new module folder that has not added one yet) returns an empty
    array, which the caller treats as orphaned.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $TopLevelModulePath,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Ref
    )

    $metadataPath = "$TopLevelModulePath/metadata.json"
    $file = Get-AvmRepositoryFileAtRef -Repository $Repository -Path $metadataPath -Ref $Ref -AllowMissing
    if ($null -eq $file) {
        return @()
    }
    $metadata = $file.Content | ConvertFrom-Json -AsHashtable -Depth 64
    return @(ConvertTo-AvmReviewerRoutingMetadataOwner -Owners @($metadata['owners']) -Source "$Repository@$Ref`:$metadataPath")
}

function Test-AvmBicepModuleExists {
    <#
    .SYNOPSIS
    Returns whether a top-level module folder is known: either indexed in the
    published catalog, or it has its own metadata.json at the given ref.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $TopLevelModulePath,
        [Parameter(Mandatory)] [hashtable] $CatalogIndex,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Ref
    )

    if ($CatalogIndex.Contains($TopLevelModulePath)) {
        return $true
    }
    $file = Get-AvmRepositoryFileAtRef -Repository $Repository -Path "$TopLevelModulePath/metadata.json" -Ref $Ref -AllowMissing
    return $null -ne $file
}

function Get-AvmModuleOwners {
    <#
    .SYNOPSIS
    Resolves a module's owners: index-first, metadata.json fallback.

    .PARAMETER TopLevelModulePath
    The module's top-level folder, e.g. 'avm/res/storage/storage-account'.

    .PARAMETER ForceMetadataLookup
    Set when the pull request itself changes this module's metadata.json,
    so the (lagging, up to ~4h stale) catalog index is bypassed even when it
    already has an entry for this module.

    .OUTPUTS
    An array of {Handle, Type} owner records. Empty means orphaned.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $TopLevelModulePath,
        [Parameter(Mandatory)] [hashtable] $CatalogIndex,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Ref,
        [switch] $ForceMetadataLookup
    )

    if (-not $ForceMetadataLookup -and $CatalogIndex.Contains($TopLevelModulePath)) {
        return @(ConvertTo-AvmReviewerRoutingOwner -Owners @($CatalogIndex[$TopLevelModulePath]['owners']))
    }
    return @(Get-AvmBicepModuleMetadataOwners -TopLevelModulePath $TopLevelModulePath -Repository $Repository -Ref $Ref)
}
