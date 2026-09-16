function Get-AvmCatalogArchivedRepositories {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $RepositoryRevisions)

    $archived = @{}
    foreach ($revision in $RepositoryRevisions) {
        if ($revision -isnot [System.Collections.IDictionary] -or $revision['repository'] -isnot [string]) {
            throw [System.IO.InvalidDataException]::new('Repository revisions must contain explicit repository identities.')
        }
        $repository = $revision.repository
        if ($repository -cnotmatch '^Azure/terraform-(azurerm|azapi|azure)-avm-(res|ptn|utl)-[a-z0-9-]+$') {
            continue
        }
        if ($archived.ContainsKey($repository)) {
            throw [System.IO.InvalidDataException]::new("Duplicate repository archive state: $repository")
        }
        if ($revision['status'] -ceq 'not-found') {
            if (-not $revision.Contains('archived') -or $null -ne $revision.archived) {
                throw [System.IO.InvalidDataException]::new("An unavailable repository must have unknown archive state: $repository")
            }
        }
        elseif ($revision['status'] -cnotin @('collected', 'empty') -or $revision['archived'] -isnot [bool]) {
            throw [System.IO.InvalidDataException]::new("Repository archive state is missing or invalid for $repository. Collect a new snapshot.")
        }
        if (($revision.status -ceq 'collected' -and [string]$revision['commit'] -cnotmatch '^[0-9a-f]{40}$') -or
            ($revision.status -cne 'collected' -and $null -ne $revision['commit'])) {
            throw [System.IO.InvalidDataException]::new("Repository revision does not match its source availability: $repository")
        }
        $archived[$repository] = $revision.archived
    }
    return $archived
}

function Test-AvmCatalogDeprecationMarker {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Path)

    $markers = @(Get-ChildItem -LiteralPath $Path -Force | Where-Object { $_.Name -ieq 'DEPRECATED.md' })
    if ($markers.Count -eq 0) {
        return $false
    }
    if ($markers.Count -ne 1 -or $markers[0].Name -cne 'DEPRECATED.md' -or $markers[0].PSIsContainer -or
        ($markers[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw [System.IO.InvalidDataException]::new("Deprecation requires one regular file named DEPRECATED.md with exact casing: $Path")
    }
    return $true
}
