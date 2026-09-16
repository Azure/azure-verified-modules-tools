#Requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-AvmCatalogRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [securestring] $GitHubToken,
        [string] $Accept = 'application/json',
        [switch] $AllowNotFound,
        [switch] $AllowEmptyRepository
    )

    if ($env:AVM_OFFLINE -eq '1') {
        throw [System.InvalidOperationException]::new('AVM_OFFLINE=1: catalog collection requires an existing offline snapshot.')
    }
    if ($Uri.Scheme -cne 'https' -or $Uri.Host -cnotin @('api.github.com', 'raw.githubusercontent.com', 'mcr.microsoft.com', 'registry.terraform.io') -or
        -not $Uri.IsDefaultPort -or $Uri.UserInfo) {
        throw [System.ArgumentException]::new('Catalog collection accepts only the fixed public HTTPS API hosts.')
    }
    $headers = @{ Accept = $Accept; 'User-Agent' = 'AVM-Module-Catalog/1' }
    if ($Uri.Host -eq 'api.github.com') {
        $headers['X-GitHub-Api-Version'] = '2022-11-28'
        if ($null -ne $GitHubToken) {
            $headers.Authorization = 'Bearer ' + [System.Net.NetworkCredential]::new('', $GitHubToken).Password
        }
    }
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -Headers $headers -TimeoutSec 60 `
            -SslProtocol Tls12,Tls13 -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction Stop
    }
    finally {
        $headers.Remove('Authorization')
    }
    $status = [int]$response.StatusCode
    $emptyRepositoryResponse = $AllowEmptyRepository -and $status -eq 409 -and $Uri.Host -ceq 'api.github.com' -and
        $Uri.AbsolutePath -match '^/repos/Azure/terraform-(azurerm|azapi|azure)-avm-(res|ptn|utl)-[a-z0-9-]+/commits/'
    if ($status -ne 200 -and -not ($AllowNotFound -and $status -eq 404) -and -not $emptyRepositoryResponse) {
        throw [System.Net.Http.HttpRequestException]::new("Catalog collection failed: HTTP $status from $($Uri.AbsoluteUri). No catalog may be published.")
    }
    $buffer = [System.IO.MemoryStream]::new()
    try {
        $response.RawContentStream.Position = 0
        $response.RawContentStream.CopyTo($buffer)
        $bytes = $buffer.ToArray()
    }
    finally {
        $buffer.Dispose()
    }
    return [pscustomobject]@{
        StatusCode = $status
        Content = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        Bytes = $bytes
    }
}

function Copy-AvmCatalogInputFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $RepositoryRoots,
        [Parameter(Mandatory)][string] $SnapshotPath
    )

    $publication = [ordered]@{ schemaVersion = 1; manifestHash = $Configuration.hash }
    foreach ($role in $Configuration.destinations.Keys) {
        $publication[$role] = [ordered]@{ repository = $Configuration.repositories[$role]; baseFiles = [ordered]@{} }
    }
    $copies = [System.Collections.Generic.List[object]]::new()
    foreach ($output in $Configuration.outputs | Where-Object { $null -ne $_.destination }) {
        $path = Join-Path $RepositoryRoots[$output.destination] $output.targetPath
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $publication[$output.destination].baseFiles[$output.targetPath] = if ($exists) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        if ($output.kind -in @('csv', 'mar')) {
            if ($output.kind -eq 'csv') {
                $path = Join-Path $RepositoryRoots[$output.destination] $output.sourcePath
                $exists = Test-Path -LiteralPath $path -PathType Leaf
            }
            if (-not $exists) {
                throw [System.IO.FileNotFoundException]::new("Required legacy catalog is missing: $path")
            }
            if ($output.kind -eq 'csv') {
                $publication[$output.destination].baseFiles[$output.sourcePath] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            $relative = if ($output.kind -eq 'csv') {
                "legacy/$($output.sourceFile)"
            }
            else {
                "legacy/$($output.file)"
            }
            $copies.Add(@{ Source = $path; Target = Join-Path $SnapshotPath $relative })
        }
    }
    if ($PSCmdlet.ShouldProcess($SnapshotPath, 'Copy configured catalog inputs and capture publication bases')) {
        foreach ($copy in $copies) {
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($copy.Target))
            [System.IO.File]::Copy($copy.Source, $copy.Target)
        }
    }
    return $publication
}

function Get-AvmCatalogResponseJson {
    [CmdletBinding()]
    param([object] $Response)

    if ($Response.StatusCode -ne 200) {
        throw [System.IO.InvalidDataException]::new('Expected a successful JSON response.')
    }
    $document = [System.Text.Json.JsonDocument]::Parse($Response.Content)
    $document.Dispose()
    return ConvertFrom-Json -InputObject $Response.Content -AsHashtable -Depth 100 -NoEnumerate
}

function Copy-AvmCatalogBicepSource {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Sources,
        [Parameter(Mandatory)][string] $Destination
    )

    foreach ($source in $Sources) {
        $directory = Join-Path $Destination $source.ModulePath
        if ($PSCmdlet.ShouldProcess($directory, 'Copy Bicep source and deprecation evidence into the catalog snapshot')) {
            $null = [System.IO.Directory]::CreateDirectory($directory)
            foreach ($file in @(Get-ChildItem -LiteralPath $source.Directory -File |
                    Where-Object { $_.Name -cin @('main.bicep', 'metadata.json', 'version.json', 'DEPRECATED.md') })) {
                [System.IO.File]::Copy($file.FullName, (Join-Path $directory $file.Name))
            }
        }
    }
}

function Get-AvmCatalogPublicationDate {
    [CmdletBinding()]
    param([object] $Value, [string] $Identity)

    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime()
    }
    if ($Value -is [DateTime] -and $Value.Kind -ne [DateTimeKind]::Unspecified) {
        return [DateTimeOffset]::new($Value).ToUniversalTime()
    }

    $date = [DateTimeOffset]::MinValue
    if ($Value -isnot [string] -or
        $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' -or
        -not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$date)) {
        throw [System.IO.InvalidDataException]::new("Registry does not provide a supported publication timestamp for $Identity.")
    }
    return $date.ToUniversalTime()
}

function Get-AvmCatalogVersions {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]] $Versions)

    $unique = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($version in $Versions) {
        $parsed = $null
        if ($version -isnot [string] -or $version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+' -or
            -not [System.Management.Automation.SemanticVersion]::TryParse($version, [ref]$parsed)) {
            throw [System.IO.InvalidDataException]::new("Registry returned an unsupported version: $version")
        }
        if (-not $unique.Add($version)) {
            throw [System.IO.InvalidDataException]::new("Registry returned a duplicate version: $version")
        }
    }
    return ,@($unique | Sort-Object { [System.Management.Automation.SemanticVersion]::Parse($_) })
}

function New-AvmCatalogRegistryResult {
    [CmdletBinding()]
    param(
        [string] $Version,
        [AllowNull()][object] $FirstPublished,
        [AllowNull()][object] $Downloads,
        [AllowNull()][object] $MarRegistered
    )

    return [ordered]@{
        status = if ($Version) { 'available' } else { 'not-published' }
        currentVersion = if ($Version) { $Version } else { $null }
        firstPublishedIn = if ($null -ne $FirstPublished) { $FirstPublished.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
        downloads = $Downloads
        marRegistered = $MarRegistered
    }
}

function Get-AvmCatalogBicepRegistry {
    [CmdletBinding()]
    param([object] $Identity, [string[]] $Mar)

    $path = $Identity.ModulePath
    $registered = $Mar -ccontains $path
    $response = Invoke-AvmCatalogRequest -Uri "https://mcr.microsoft.com/v2/bicep/$path/tags/list" -AllowNotFound
    if ($response.StatusCode -eq 404) {
        return New-AvmCatalogRegistryResult -MarRegistered $registered
    }
    $body = Get-AvmCatalogResponseJson -Response $response
    if ($body.name -cne "bicep/$path" -or $body.tags -isnot [array]) {
        throw [System.IO.InvalidDataException]::new("Unexpected MCR tag-list contract for $path.")
    }
    $versions = Get-AvmCatalogVersions -Versions $body.tags
    if ($versions.Count -eq 0) {
        return New-AvmCatalogRegistryResult -MarRegistered $registered
    }
    if (-not $registered) {
        throw [System.IO.InvalidDataException]::new("Published Bicep module $path is absent from the approved MAR mirror. Refresh the mirror before publication.")
    }
    $first = [DateTimeOffset]::MaxValue
    foreach ($version in $versions) {
        $response = Invoke-AvmCatalogRequest -Uri "https://mcr.microsoft.com/v2/bicep/$path/manifests/$version" `
            -Accept 'application/vnd.oci.image.manifest.v1+json'
        $manifest = Get-AvmCatalogResponseJson -Response $response
        if ($manifest.schemaVersion -ne 2 -or $manifest.mediaType -cne 'application/vnd.oci.image.manifest.v1+json' -or
            -not $manifest.Contains('annotations') -or -not $manifest.annotations.Contains('org.opencontainers.image.created')) {
            throw [System.IO.InvalidDataException]::new("MCR manifest lacks a supported creation timestamp: $path`:$version")
        }
        $date = Get-AvmCatalogPublicationDate -Value $manifest.annotations['org.opencontainers.image.created'] -Identity "$path`:$version"
        if ($date -lt $first) {
            $first = $date
        }
    }
    return New-AvmCatalogRegistryResult -Version $versions[-1] -FirstPublished $first -MarRegistered $registered
}

function Get-AvmCatalogTerraformRegistry {
    [CmdletBinding()]
    param([object] $Identity)

    $base = "https://registry.terraform.io/v1/modules/Azure/$($Identity.RepositoryId)/$($Identity.Provider)"
    $response = Invoke-AvmCatalogRequest -Uri $base -AllowNotFound
    if ($response.StatusCode -eq 404) {
        return [pscustomobject]@{ Root = New-AvmCatalogRegistryResult; Children = @{} }
    }
    $latest = Get-AvmCatalogResponseJson -Response $response
    if ($latest.namespace -cne 'Azure' -or $latest.name -cne $Identity.RepositoryId -or $latest.provider -cne $Identity.Provider -or
        $latest.versions -isnot [array] -or $latest.versions.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new("Unexpected Terraform Registry module identity: $($Identity.Repository)")
    }
    $versions = Get-AvmCatalogVersions -Versions $latest.versions
    if ($versions -cnotcontains $latest.version) {
        throw [System.IO.InvalidDataException]::new('Terraform Registry current version is not in its version list.')
    }
    $downloads = $null
    if ($latest.Contains('downloads') -and $null -ne $latest.downloads) {
        if ($latest.downloads -isnot [long] -and $latest.downloads -isnot [int]) {
            throw [System.IO.InvalidDataException]::new('Terraform Registry downloads must be an integer when supplied.')
        }
        if ($latest.downloads -lt 0) {
            throw [System.IO.InvalidDataException]::new('Terraform Registry downloads cannot be negative.')
        }
        $downloads = $latest.downloads
    }
    $first = [DateTimeOffset]::MaxValue
    $children = @{}
    foreach ($version in $versions) {
        $release = if ($version -ceq $latest.version) {
            $latest
        }
        else {
            Get-AvmCatalogResponseJson -Response (Invoke-AvmCatalogRequest -Uri "$base/$version")
        }
        if ($release.version -cne $version -or $release.submodules -isnot [array]) {
            throw [System.IO.InvalidDataException]::new("Unsupported Terraform release contract: $base/$version")
        }
        $date = Get-AvmCatalogPublicationDate -Value $release.published_at -Identity "$base/$version"
        if ($date -lt $first) {
            $first = $date
        }
        foreach ($child in $release.submodules) {
            if ($child.path -cnotmatch '^modules/[a-z0-9_-]+$') {
                continue
            }
            if (-not $children.ContainsKey($child.path)) {
                $children[$child.path] = @{ First = $date; Version = $version }
            }
            if ($date -lt $children[$child.path].First) {
                $children[$child.path].First = $date
            }
            $children[$child.path].Version = $version
        }
    }
    $results = @{}
    foreach ($path in $children.Keys) {
        $results[$path] = New-AvmCatalogRegistryResult -Version $children[$path].Version -FirstPublished $children[$path].First
    }
    return [pscustomobject]@{
        Root = New-AvmCatalogRegistryResult -Version $latest.version -FirstPublished $first -Downloads $downloads
        Children = $results
    }
}

function Get-AvmCatalogEnrichment {
    [CmdletBinding()]
    param([object] $Inventory, [securestring] $GitHubToken)

    $github = [ordered]@{ users = @{}; teams = @{} }
    $registry = [ordered]@{}
    $terraform = @{}
    foreach ($item in $Inventory.Items) {
        if ($item.Record.metadataSource -eq 'metadata') {
            foreach ($handle in @($item.Record.owners | Where-Object { -not $_.StartsWith('@') })) {
                if (-not $github.users.ContainsKey($handle)) {
                    $profile = Get-AvmCatalogResponseJson -Response (Invoke-AvmCatalogRequest -Uri "https://api.github.com/users/$handle" -GitHubToken $GitHubToken)
                    $github.users[$handle] = [ordered]@{ login = $profile.login; name = $profile.name; type = $profile.type }
                }
            }
            foreach ($team in @($item.Record.owners | Where-Object { $_.StartsWith('@') })) {
                if ($github.teams.ContainsKey($team)) {
                    continue
                }
                if ($team -cnotmatch '^@Azure/(?<slug>[a-z0-9]+(-[a-z0-9]+)*)$') {
                    throw [System.IO.InvalidDataException]::new("Only Azure owner teams are supported: $team")
                }
                $slug = $team.Substring('@Azure/'.Length)
                $response = Get-AvmCatalogResponseJson -Response (Invoke-AvmCatalogRequest -Uri "https://api.github.com/orgs/Azure/teams/$slug" -GitHubToken $GitHubToken)
                $github.teams[$team] = [ordered]@{ slug = $response.slug; organization = $response.organization.login }
            }
            $null = Resolve-AvmCatalogOwnerProfiles -Owners $item.Record.owners -Cache $github
        }
    }
    foreach ($item in $Inventory.Items) {
        if ($item.Identity.Ecosystem -eq 'bicep') {
            $registry[$item.Identity.Key] = Get-AvmCatalogBicepRegistry -Identity $item.Identity -Mar $Inventory.Mar
        }
        else {
            $repository = $item.Identity.Repository
            if (-not $terraform.ContainsKey($repository)) {
                $terraform[$repository] = Get-AvmCatalogTerraformRegistry -Identity $item.Identity
            }
            $family = $terraform[$repository]
            $path = $item.Identity.ModulePath
            $registry[$item.Identity.Key] = if ($path -eq '.') {
                $family.Root
            }
            elseif ($family.Children.ContainsKey($path)) {
                $family.Children[$path]
            }
            else {
                New-AvmCatalogRegistryResult
            }
        }
    }
    return [pscustomobject]@{ GitHub = $github; Registry = $registry }
}

function Get-AvmCatalogTerraformRepositories {
    [CmdletBinding()]
    param(
        [securestring] $GitHubToken,
        [string] $LegacyPath,
        [System.Collections.IDictionary] $Configuration = (Read-AvmCatalogConfiguration)
    )

    $repositories = @{}
    foreach ($provider in @('azurerm', 'azapi', 'azure')) {
        foreach ($kind in @('res', 'ptn', 'utl')) {
            $prefix = "terraform-$provider-avm-$kind-"
            $query = [uri]::EscapeDataString("org:Azure is:public fork:false in:name $prefix")
            $page = 1
            $received = 0
            do {
                $result = Get-AvmCatalogResponseJson -Response (Invoke-AvmCatalogRequest `
                        -Uri "https://api.github.com/search/repositories?q=$query&per_page=100&page=$page" -GitHubToken $GitHubToken)
                if ($result.incomplete_results -ne $false -or $result.total_count -gt 1000 -or $result.items -isnot [array]) {
                    throw [System.IO.InvalidDataException]::new("GitHub search is incomplete for $prefix; refusing a partial fleet snapshot.")
                }
                foreach ($repository in $result.items) {
                    if ($repository.full_name -cmatch "^Azure/$prefix[a-z0-9-]+$" -and -not $repository.private -and -not $repository.fork) {
                        $repositories[$repository.full_name] = $true
                    }
                }
                $received += $result.items.Count
                if ($result.items.Count -eq 0 -and $received -lt $result.total_count) {
                    throw [System.IO.InvalidDataException]::new("GitHub search pagination ended early for $prefix.")
                }
                $page++
            } while ($received -lt $result.total_count)
        }
    }
    foreach ($output in $Configuration.outputs | Where-Object { $_.kind -ceq 'csv' -and $_.ecosystem -ceq 'terraform' }) {
        $table = Read-AvmCatalogCsv -Path (Join-Path $LegacyPath $output.sourceFile)
        foreach ($row in $table.Rows) {
            $match = [regex]::Match([string]$row.RepoURL, '^https://github\.com/(?<repository>Azure/terraform-(azurerm|azapi|azure)-avm-(res|ptn|utl)-[a-z0-9-]+)(/|$)')
            if ($match.Success) {
                $repositories[$match.Groups['repository'].Value] = $true
            }
        }
    }
    return Get-AvmCatalogOrdinal -Values @($repositories.Keys)
}

function Save-AvmCatalogTerraformSource {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Repository, [string] $Destination, [securestring] $GitHubToken)

    $repoResponse = Invoke-AvmCatalogRequest -Uri "https://api.github.com/repos/$Repository" -GitHubToken $GitHubToken -AllowNotFound
    if ($repoResponse.StatusCode -eq 404) {
        return [ordered]@{ repository = $Repository; commit = $null; status = 'not-found'; archived = $null }
    }
    $repositoryInfo = Get-AvmCatalogResponseJson -Response $repoResponse
    if ($repositoryInfo.full_name -cne $Repository -or $repositoryInfo.private) {
        throw [System.IO.InvalidDataException]::new("Expected a public, unrenamed repository: $Repository")
    }
    if ($repositoryInfo['archived'] -isnot [bool]) {
        throw [System.IO.InvalidDataException]::new("GitHub did not return a valid archived flag for $Repository. Collect a new snapshot.")
    }
    $branch = [uri]::EscapeDataString($repositoryInfo.default_branch)
    $commitResponse = Invoke-AvmCatalogRequest -Uri "https://api.github.com/repos/$Repository/commits/$branch" -GitHubToken $GitHubToken -AllowEmptyRepository
    if ($commitResponse.StatusCode -eq 409) {
        $errorBody = ConvertFrom-Json -InputObject $commitResponse.Content -AsHashtable
        if ($errorBody.message -ceq 'Git Repository is empty.') {
            return [ordered]@{ repository = $Repository; commit = $null; status = 'empty'; archived = $repositoryInfo.archived }
        }
        throw [System.IO.InvalidDataException]::new("GitHub commit lookup failed with HTTP 409 for $Repository; it is not a confirmed empty repository.")
    }
    $commit = Get-AvmCatalogResponseJson -Response $commitResponse
    if ($commit.sha -cnotmatch '^[0-9a-f]{40}$') {
        throw [System.IO.InvalidDataException]::new("Cannot resolve an immutable source commit for $Repository.")
    }
    $tree = Get-AvmCatalogResponseJson -Response (Invoke-AvmCatalogRequest -Uri "https://api.github.com/repos/$Repository/git/trees/$($commit.commit.tree.sha)?recursive=1" -GitHubToken $GitHubToken)
    if ($tree.truncated -ne $false -or $tree.tree -isnot [array]) {
        throw [System.IO.InvalidDataException]::new("GitHub returned a truncated tree for $Repository.")
    }
    $files = @{}
    $sourceDirectories = @{}
    foreach ($entry in $tree.tree) {
        if ($entry.path -cmatch '^(modules/[^/]+/)?[^/]+\.tf(\.json)?$') {
            $directory = if ($entry.path.Contains('/')) { $entry.path.Substring(0, $entry.path.LastIndexOf('/')) } else { '.' }
            if ($directory -cnotmatch '^(\.|modules/[a-z0-9_-]+)$') {
                throw [System.IO.InvalidDataException]::new("Unsupported Terraform module directory in $Repository`: $directory")
            }
            if (-not $sourceDirectories.ContainsKey($directory)) {
                $sourceDirectories[$directory] = $entry
            }
        }
        if ($entry.path -imatch '^(modules/[^/]+/)?metadata\.json$') {
            $files[$entry.path] = $entry
        }
    }
    foreach ($entry in $sourceDirectories.Values) {
        $files[$entry.path] = $entry
    }
    foreach ($path in (Get-AvmCatalogOrdinal -Values @($files.Keys))) {
        $entry = $files[$path]
        if ($entry.type -cne 'blob' -or $entry.mode -cnotin @('100644', '100755') -or $entry.size -gt 5MB) {
            throw [System.IO.InvalidDataException]::new("Unsupported source entry (link, submodule or oversized blob): $Repository/$path")
        }
        $content = Invoke-AvmCatalogRequest -Uri "https://raw.githubusercontent.com/$Repository/$($commit.sha)/$path" -Accept 'text/plain'
        $prefix = [System.Text.Encoding]::UTF8.GetBytes("blob $($content.Bytes.Length)`0")
        $blob = [byte[]]::new($prefix.Length + $content.Bytes.Length)
        $prefix.CopyTo($blob, 0)
        $content.Bytes.CopyTo($blob, $prefix.Length)
        $sha = [Convert]::ToHexString([System.Security.Cryptography.SHA1]::HashData($blob)).ToLowerInvariant()
        if ($sha -cne $entry.sha) {
            throw [System.Security.SecurityException]::new("Git blob verification failed for $Repository/$path.")
        }
        if ($PSCmdlet.ShouldProcess("$Repository/$path", 'Save read-only catalog source snapshot')) {
            $target = Join-Path $Destination $path
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
            [System.IO.File]::WriteAllBytes($target, $content.Bytes)
        }
    }
    return [ordered]@{ repository = $Repository; commit = $commit.sha; status = 'collected'; archived = $repositoryInfo.archived }
}

function Invoke-AvmCatalogProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList,
        [string] $WorkingDirectory,
        [hashtable] $EnvVars,
        [switch] $IgnoreExitCode
    )

    $module = Get-Module -Name Avm.Authoring
    if ($null -eq $module) {
        throw [System.InvalidOperationException]::new('Import the trusted local Avm.Authoring manifest before invoking catalog processes.')
    }
    $parameters = @{
        FilePath = $FilePath; ArgumentList = $ArgumentList; WorkingDirectory = $WorkingDirectory
        EnvVars = $EnvVars; IgnoreExitCode = $IgnoreExitCode; TimeoutSec = 300
    }
    return & $module { param($Arguments) Invoke-AvmProcess @Arguments } $parameters
}
