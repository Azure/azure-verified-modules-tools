#Requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:AvmCatalogHostConcurrency = @{
    'api.github.com' = 8
    'raw.githubusercontent.com' = 16
    'mcr.microsoft.com' = 16
    'registry.terraform.io' = 8
}
$script:AvmCatalogClient = $null

function Assert-AvmCatalogUri {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uri] $Uri)

    if ($env:AVM_OFFLINE -eq '1') {
        throw [System.InvalidOperationException]::new('AVM_OFFLINE=1: catalog collection requires an existing offline snapshot.')
    }
    if ($Uri.Scheme -cne 'https' -or $Uri.Host -cnotin @('api.github.com', 'raw.githubusercontent.com', 'mcr.microsoft.com', 'registry.terraform.io') -or
        -not $Uri.IsDefaultPort -or $Uri.UserInfo) {
        throw [System.ArgumentException]::new('Catalog collection accepts only the fixed public HTTPS API hosts.')
    }
}

function Assert-AvmCatalogResponseStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [Parameter(Mandatory)][int] $StatusCode,
        [switch] $AllowNotFound,
        [switch] $AllowEmptyRepository
    )

    $emptyRepositoryResponse = $AllowEmptyRepository -and $StatusCode -eq 409 -and $Uri.Host -ceq 'api.github.com' -and
        $Uri.AbsolutePath -match '^/repos/Azure/terraform-(azurerm|azapi|azure)-avm-(res|ptn|utl)-[a-z0-9-]+/commits/'
    if ($StatusCode -ne 200 -and -not ($AllowNotFound -and $StatusCode -eq 404) -and -not $emptyRepositoryResponse) {
        throw [System.Net.Http.HttpRequestException]::new("Catalog collection failed: HTTP $StatusCode from $($Uri.AbsoluteUri). No catalog may be published.")
    }
}

function Test-AvmCatalogTransientStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int] $StatusCode, [System.Collections.IDictionary] $ResponseHeader)

    if ($StatusCode -in @(408, 425, 429, 500, 502, 503, 504)) {
        return $true
    }
    if ($StatusCode -ne 403 -or $null -eq $ResponseHeader) {
        return $false
    }
    return $ResponseHeader.Contains('retry-after') -or
        ($ResponseHeader.Contains('x-ratelimit-remaining') -and $ResponseHeader['x-ratelimit-remaining'] -eq '0')
}

function New-AvmCatalogRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [string] $Accept = 'application/json',
        [switch] $AllowNotFound,
        [switch] $AllowEmptyRepository
    )

    return @{
        Uri = $Uri
        Accept = $Accept
        AllowNotFound = [bool]$AllowNotFound
        AllowEmptyRepository = [bool]$AllowEmptyRepository
    }
}

function Get-AvmCatalogHttpClient {
    [CmdletBinding()]
    param()

    if ($null -eq $script:AvmCatalogClient) {
        $handler = [System.Net.Http.SocketsHttpHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.MaxConnectionsPerServer = 32
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::All
        $handler.SslOptions.EnabledSslProtocols = [System.Security.Authentication.SslProtocols]::Tls12 -bor [System.Security.Authentication.SslProtocols]::Tls13
        $client = [System.Net.Http.HttpClient]::new($handler, $true)
        $client.Timeout = [TimeSpan]::FromSeconds(100)
        $script:AvmCatalogClient = $client
    }
    return $script:AvmCatalogClient
}

function New-AvmCatalogRequestMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [string] $Accept = 'application/json',
        [securestring] $GitHubToken
    )

    $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
    $null = $message.Headers.TryAddWithoutValidation('Accept', $Accept)
    $null = $message.Headers.TryAddWithoutValidation('User-Agent', 'AVM-Module-Catalog/1')
    if ($Uri.Host -ceq 'api.github.com') {
        $null = $message.Headers.TryAddWithoutValidation('X-GitHub-Api-Version', '2022-11-28')
        if ($null -ne $GitHubToken) {
            $null = $message.Headers.TryAddWithoutValidation('Authorization', 'Bearer ' + [System.Net.NetworkCredential]::new('', $GitHubToken).Password)
        }
    }
    return $message
}

function Get-AvmCatalogResponseHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Response)

    $headers = @{}
    foreach ($header in @($Response.Headers) + @($Response.Content.Headers)) {
        $headers[$header.Key.ToLowerInvariant()] = ($header.Value -join ',')
    }
    return $headers
}

function Get-AvmCatalogRetryDelay {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int] $Attempt, [System.Collections.IDictionary] $ResponseHeader)

    $seconds = [Math]::Min([Math]::Pow(2, $Attempt - 1), 30)
    $advertised = 0
    if ($null -ne $ResponseHeader -and $ResponseHeader.Contains('retry-after') -and
        [int]::TryParse($ResponseHeader['retry-after'], [ref]$advertised) -and $advertised -gt 0) {
        $seconds = [Math]::Max($seconds, [Math]::Min($advertised, 60))
    }
    return [TimeSpan]::FromSeconds($seconds)
}

function Invoke-AvmCatalogRequestSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary[]] $Requests,
        [securestring] $GitHubToken,
        [string] $Activity,
        [int] $MaxAttempt = 4
    )

    $normalized = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($request in $Requests) {
        $uri = [uri]$request['Uri']
        Assert-AvmCatalogUri -Uri $uri
        $normalized.Add(@{
                Uri = $uri
                Accept = if ($request.Contains('Accept') -and $request['Accept']) { [string]$request['Accept'] } else { 'application/json' }
                AllowNotFound = [bool]$request['AllowNotFound']
                AllowEmptyRepository = [bool]$request['AllowEmptyRepository']
            })
    }
    if ($normalized.Count -eq 0) {
        return , @()
    }
    $client = Get-AvmCatalogHttpClient
    $results = [object[]]::new($normalized.Count)
    $pending = [System.Collections.Generic.List[int]]::new([int[]](0..($normalized.Count - 1)))
    if ($Activity) {
        Write-AvmCatalogProgress ("{0}: issuing {1} request(s)." -f $Activity, $normalized.Count)
    }
    $completed = 0
    $milestone = [Math]::Max(200, [Math]::Ceiling($normalized.Count / 10))
    $reported = 0
    for ($attempt = 1; $attempt -le $MaxAttempt; $attempt++) {
        $retry = [System.Collections.Generic.List[int]]::new()
        $retryHeader = $null
        $lastError = $null
        foreach ($group in ($pending | Group-Object -Property { $normalized[$_].Uri.Host })) {
            $limit = [int]$script:AvmCatalogHostConcurrency[$group.Name]
            $indexes = @($group.Group)
            for ($offset = 0; $offset -lt $indexes.Count; $offset += $limit) {
                $chunk = @($indexes[$offset..([Math]::Min($offset + $limit, $indexes.Count) - 1)])
                $tasks = @{}
                $messages = @{}
                foreach ($index in $chunk) {
                    $entry = $normalized[$index]
                    $messages[$index] = New-AvmCatalogRequestMessage -Uri $entry.Uri -Accept $entry.Accept -GitHubToken $GitHubToken
                    $tasks[$index] = $client.SendAsync($messages[$index], [System.Net.Http.HttpCompletionOption]::ResponseContentRead)
                }
                try {
                    try {
                        [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($chunk | ForEach-Object { $tasks[$_] }))
                    }
                    catch [System.AggregateException] {
                        $lastError = $_.Exception.GetBaseException()
                    }
                    foreach ($index in $chunk) {
                        $entry = $normalized[$index]
                        $task = $tasks[$index]
                        if ($task.IsFaulted -or $task.IsCanceled) {
                            $failure = if ($null -ne $task.Exception) {
                                $task.Exception.GetBaseException()
                            }
                            else {
                                [System.Net.Http.HttpRequestException]::new("Catalog collection was canceled for $($entry.Uri.AbsoluteUri).")
                            }
                            if ($attempt -lt $MaxAttempt) {
                                $lastError = $failure
                                $retry.Add($index)
                                continue
                            }
                            throw $failure
                        }
                        $response = $task.Result
                        $status = [int]$response.StatusCode
                        $header = Get-AvmCatalogResponseHeader -Response $response
                        if ($attempt -lt $MaxAttempt -and (Test-AvmCatalogTransientStatus -StatusCode $status -ResponseHeader $header)) {
                            $retryHeader = $header
                            $retry.Add($index)
                            continue
                        }
                        Assert-AvmCatalogResponseStatus -Uri $entry.Uri -StatusCode $status `
                            -AllowNotFound:$entry.AllowNotFound -AllowEmptyRepository:$entry.AllowEmptyRepository
                        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                        $results[$index] = [pscustomobject]@{
                            StatusCode = $status
                            Content = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
                            Bytes = $bytes
                        }
                        $completed++
                    }
                }
                finally {
                    foreach ($index in $chunk) {
                        if ($tasks[$index].Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                            $tasks[$index].Result.Dispose()
                        }
                        $messages[$index].Dispose()
                    }
                }
                if ($Activity -and ($completed - $reported) -ge $milestone) {
                    $reported = $completed
                    Write-AvmCatalogProgress $Activity -Current $completed -Total $normalized.Count
                }
            }
        }
        if ($retry.Count -eq 0) {
            if ($Activity) {
                Write-AvmCatalogProgress ("{0}: complete." -f $Activity) -Current $normalized.Count -Total $normalized.Count
            }
            return , $results
        }
        if ($attempt -ge $MaxAttempt -and $null -ne $lastError) {
            throw $lastError
        }
        Write-AvmCatalogProgress ("Retrying {0} catalog request(s) after attempt {1}." -f $retry.Count, $attempt)
        Start-Sleep -Milliseconds (Get-AvmCatalogRetryDelay -Attempt $attempt -ResponseHeader $retryHeader).TotalMilliseconds
        $pending = $retry
    }
    return , $results
}

function Invoke-AvmCatalogRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [securestring] $GitHubToken,
        [string] $Accept = 'application/json',
        [switch] $AllowNotFound,
        [switch] $AllowEmptyRepository,
        [int] $MaxAttempt = 4
    )

    $request = New-AvmCatalogRequest -Uri $Uri -Accept $Accept -AllowNotFound:$AllowNotFound -AllowEmptyRepository:$AllowEmptyRepository
    return (Invoke-AvmCatalogRequestSet -Requests @($request) -GitHubToken $GitHubToken -MaxAttempt $MaxAttempt)[0]
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

function Get-AvmCatalogBicepRegistrySet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Identities, [string[]] $Mar)

    $results = @{}
    $tagResponses = Invoke-AvmCatalogRequestSet -Activity 'Bicep registry tag lists' -Requests @(foreach ($identity in $Identities) {
            New-AvmCatalogRequest -Uri "https://mcr.microsoft.com/v2/bicep/$($identity.ModulePath)/tags/list" -AllowNotFound
        })
    $manifestRequests = [System.Collections.Generic.List[hashtable]]::new()
    $manifestOwners = [System.Collections.Generic.List[hashtable]]::new()
    $current = @{}
    for ($index = 0; $index -lt $Identities.Count; $index++) {
        $identity = $Identities[$index]
        $path = $identity.ModulePath
        $registered = $Mar -ccontains $path
        $response = $tagResponses[$index]
        if ($response.StatusCode -eq 404) {
            $results[$identity.Key] = New-AvmCatalogRegistryResult -MarRegistered $registered
            continue
        }
        $body = Get-AvmCatalogResponseJson -Response $response
        if ($body.name -cne "bicep/$path" -or $body.tags -isnot [array]) {
            throw [System.IO.InvalidDataException]::new("Unexpected MCR tag-list contract for $path.")
        }
        $versions = Get-AvmCatalogVersions -Versions $body.tags
        if ($versions.Count -eq 0) {
            $results[$identity.Key] = New-AvmCatalogRegistryResult -MarRegistered $registered
            continue
        }
        if (-not $registered) {
            throw [System.IO.InvalidDataException]::new("Published Bicep module $path is absent from the approved MAR mirror. Refresh the mirror before publication.")
        }
        $current[$identity.Key] = $versions[-1]
        foreach ($version in $versions) {
            $manifestRequests.Add((New-AvmCatalogRequest -Uri "https://mcr.microsoft.com/v2/bicep/$path/manifests/$version" `
                        -Accept 'application/vnd.oci.image.manifest.v1+json'))
            $manifestOwners.Add(@{ Key = $identity.Key; Path = $path; Version = $version })
        }
    }
    $manifestResponses = Invoke-AvmCatalogRequestSet -Activity 'Bicep registry manifests' -Requests @($manifestRequests)
    $first = @{}
    for ($index = 0; $index -lt $manifestOwners.Count; $index++) {
        $owner = $manifestOwners[$index]
        $manifest = Get-AvmCatalogResponseJson -Response $manifestResponses[$index]
        if ($manifest.schemaVersion -ne 2 -or $manifest.mediaType -cne 'application/vnd.oci.image.manifest.v1+json' -or
            -not $manifest.Contains('annotations') -or -not $manifest.annotations.Contains('org.opencontainers.image.created')) {
            throw [System.IO.InvalidDataException]::new("MCR manifest lacks a supported creation timestamp: $($owner.Path)`:$($owner.Version)")
        }
        $date = Get-AvmCatalogPublicationDate -Value $manifest.annotations['org.opencontainers.image.created'] -Identity "$($owner.Path)`:$($owner.Version)"
        if (-not $first.ContainsKey($owner.Key) -or $date -lt $first[$owner.Key]) {
            $first[$owner.Key] = $date
        }
    }
    foreach ($key in $current.Keys) {
        $results[$key] = New-AvmCatalogRegistryResult -Version $current[$key] -FirstPublished $first[$key] -MarRegistered $true
    }
    return $results
}

function Get-AvmCatalogBicepRegistry {
    [CmdletBinding()]
    param([object] $Identity, [string[]] $Mar)

    return (Get-AvmCatalogBicepRegistrySet -Identities @($Identity) -Mar $Mar)[$Identity.Key]
}

function Get-AvmCatalogTerraformRegistrySet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Identities)

    $roots = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($identity in $Identities) {
        if ($seen.Add($identity.Repository)) {
            $roots.Add(@{
                    Repository = $identity.Repository
                    Base = "https://registry.terraform.io/v1/modules/Azure/$($identity.RepositoryId)/$($identity.Provider)"
                    Identity = $identity
                })
        }
    }
    $rootResponses = Invoke-AvmCatalogRequestSet -Activity 'Terraform registry modules' -Requests @(foreach ($root in $roots) {
            New-AvmCatalogRequest -Uri $root.Base -AllowNotFound
        })
    $results = @{}
    $releaseRequests = [System.Collections.Generic.List[hashtable]]::new()
    $releaseOwners = [System.Collections.Generic.List[hashtable]]::new()
    for ($index = 0; $index -lt $roots.Count; $index++) {
        $root = $roots[$index]
        $identity = $root.Identity
        $response = $rootResponses[$index]
        if ($response.StatusCode -eq 404) {
            $results[$root.Repository] = [pscustomobject]@{ Root = New-AvmCatalogRegistryResult; Children = @{} }
            continue
        }
        $latest = Get-AvmCatalogResponseJson -Response $response
        if ($latest.namespace -cne 'Azure' -or $latest.name -cne $identity.RepositoryId -or $latest.provider -cne $identity.Provider -or
            $latest.versions -isnot [array] -or $latest.versions.Count -eq 0) {
            throw [System.IO.InvalidDataException]::new("Unexpected Terraform Registry module identity: $($identity.Repository)")
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
        $root.Latest = $latest
        $root.Versions = $versions
        $root.Downloads = $downloads
        foreach ($version in $versions) {
            if ($version -ceq $latest.version) {
                continue
            }
            $releaseRequests.Add((New-AvmCatalogRequest -Uri "$($root.Base)/$version"))
            $releaseOwners.Add(@{ Repository = $root.Repository; Version = $version })
        }
    }
    $releaseResponses = Invoke-AvmCatalogRequestSet -Activity 'Terraform registry versions' -Requests @($releaseRequests)
    $releases = @{}
    for ($index = 0; $index -lt $releaseOwners.Count; $index++) {
        $owner = $releaseOwners[$index]
        $releases["$($owner.Repository)/$($owner.Version)"] = Get-AvmCatalogResponseJson -Response $releaseResponses[$index]
    }
    foreach ($root in $roots) {
        if ($results.ContainsKey($root.Repository)) {
            continue
        }
        $latest = $root.Latest
        $first = [DateTimeOffset]::MaxValue
        $children = @{}
        foreach ($version in $root.Versions) {
            $release = if ($version -ceq $latest.version) { $latest } else { $releases["$($root.Repository)/$version"] }
            if ($release.version -cne $version -or $release.submodules -isnot [array]) {
                throw [System.IO.InvalidDataException]::new("Unsupported Terraform release contract: $($root.Base)/$version")
            }
            $date = Get-AvmCatalogPublicationDate -Value $release.published_at -Identity "$($root.Base)/$version"
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
        $childResults = @{}
        foreach ($path in $children.Keys) {
            $childResults[$path] = New-AvmCatalogRegistryResult -Version $children[$path].Version -FirstPublished $children[$path].First
        }
        $results[$root.Repository] = [pscustomobject]@{
            Root = New-AvmCatalogRegistryResult -Version $latest.version -FirstPublished $first -Downloads $root.Downloads
            Children = $childResults
        }
    }
    return $results
}

function Get-AvmCatalogTerraformRegistry {
    [CmdletBinding()]
    param([object] $Identity)

    return (Get-AvmCatalogTerraformRegistrySet -Identities @($Identity))[$Identity.Repository]
}

function Get-AvmCatalogEnrichment {
    [CmdletBinding()]
    param([object] $Inventory, [securestring] $GitHubToken)

    $github = [ordered]@{ users = @{}; teams = @{} }
    $handles = [System.Collections.Generic.List[string]]::new()
    $teams = [System.Collections.Generic.List[string]]::new()
    $known = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Inventory.Items) {
        if ($item.Record.metadataSource -ne 'metadata') {
            continue
        }
        foreach ($owner in $item.Record.owners) {
            if (-not $known.Add($owner)) {
                continue
            }
            if (-not $owner.StartsWith('@')) {
                $handles.Add($owner)
                continue
            }
            if ($owner -cnotmatch '^@Azure/(?<slug>[a-z0-9]+(-[a-z0-9]+)*)$') {
                throw [System.IO.InvalidDataException]::new("Only Azure owner teams are supported: $owner")
            }
            $teams.Add($owner)
        }
    }
    $profiles = Invoke-AvmCatalogRequestSet -Activity 'GitHub owner profiles' -GitHubToken $GitHubToken -Requests @(foreach ($handle in $handles) {
            New-AvmCatalogRequest -Uri "https://api.github.com/users/$handle"
        })
    for ($index = 0; $index -lt $handles.Count; $index++) {
        $body = Get-AvmCatalogResponseJson -Response $profiles[$index]
        $github.users[$handles[$index]] = [ordered]@{ login = $body.login; name = $body.name; type = $body.type }
    }
    $memberships = Invoke-AvmCatalogRequestSet -Activity 'GitHub team memberships' -GitHubToken $GitHubToken -Requests @(foreach ($team in $teams) {
            New-AvmCatalogRequest -Uri "https://api.github.com/orgs/Azure/teams/$($team.Substring('@Azure/'.Length))"
        })
    for ($index = 0; $index -lt $teams.Count; $index++) {
        $body = Get-AvmCatalogResponseJson -Response $memberships[$index]
        $github.teams[$teams[$index]] = [ordered]@{ slug = $body.slug; organization = $body.organization.login }
    }
    foreach ($item in $Inventory.Items) {
        if ($item.Record.metadataSource -eq 'metadata') {
            $null = Resolve-AvmCatalogOwnerProfiles -Owners $item.Record.owners -Cache $github
        }
    }
    $bicep = Get-AvmCatalogBicepRegistrySet -Mar $Inventory.Mar `
        -Identities @($Inventory.Items | Where-Object { $_.Identity.Ecosystem -eq 'bicep' } | ForEach-Object { $_.Identity })
    $terraform = Get-AvmCatalogTerraformRegistrySet `
        -Identities @($Inventory.Items | Where-Object { $_.Identity.Ecosystem -ne 'bicep' } | ForEach-Object { $_.Identity })
    $registry = [ordered]@{}
    foreach ($item in $Inventory.Items) {
        if ($item.Identity.Ecosystem -eq 'bicep') {
            $registry[$item.Identity.Key] = $bicep[$item.Identity.Key]
            continue
        }
        $family = $terraform[$item.Identity.Repository]
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

function Get-AvmCatalogTerraformSourcePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Repository, [Parameter(Mandatory)][object] $Tree)

    if ($Tree.truncated -ne $false -or $Tree.tree -isnot [array]) {
        throw [System.IO.InvalidDataException]::new("GitHub returned a truncated tree for $Repository.")
    }
    $files = @{}
    $sourceDirectories = @{}
    foreach ($entry in $Tree.tree) {
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
    return $files
}

function Save-AvmCatalogTerraformSourceSet {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Target, [securestring] $GitHubToken)

    $repositories = @($Target | ForEach-Object { [string]$_.Repository })
    $revisions = [ordered]@{}
    $active = [System.Collections.Generic.List[hashtable]]::new()
    $repoResponses = Invoke-AvmCatalogRequestSet -Activity 'Terraform repository metadata' -GitHubToken $GitHubToken -Requests @(foreach ($repository in $repositories) {
            New-AvmCatalogRequest -Uri "https://api.github.com/repos/$repository" -AllowNotFound
        })
    for ($index = 0; $index -lt $repositories.Count; $index++) {
        $repository = $repositories[$index]
        $response = $repoResponses[$index]
        if ($response.StatusCode -eq 404) {
            $revisions[$repository] = [ordered]@{ repository = $repository; commit = $null; status = 'not-found'; archived = $null }
            continue
        }
        $repositoryInfo = Get-AvmCatalogResponseJson -Response $response
        if ($repositoryInfo.full_name -cne $repository -or $repositoryInfo.private) {
            throw [System.IO.InvalidDataException]::new("Expected a public, unrenamed repository: $repository")
        }
        if ($repositoryInfo['archived'] -isnot [bool]) {
            throw [System.IO.InvalidDataException]::new("GitHub did not return a valid archived flag for $repository. Collect a new snapshot.")
        }
        $active.Add(@{
                Repository = $repository
                Destination = [string]$Target[$index].Destination
                Archived = $repositoryInfo.archived
                Branch = [uri]::EscapeDataString($repositoryInfo.default_branch)
            })
    }
    $commitResponses = Invoke-AvmCatalogRequestSet -Activity 'Terraform repository commits' -GitHubToken $GitHubToken -Requests @(foreach ($entry in $active) {
            New-AvmCatalogRequest -Uri "https://api.github.com/repos/$($entry.Repository)/commits/$($entry.Branch)" -AllowEmptyRepository
        })
    $trees = [System.Collections.Generic.List[hashtable]]::new()
    for ($index = 0; $index -lt $active.Count; $index++) {
        $entry = $active[$index]
        $response = $commitResponses[$index]
        if ($response.StatusCode -eq 409) {
            $errorBody = ConvertFrom-Json -InputObject $response.Content -AsHashtable
            if ($errorBody.message -cne 'Git Repository is empty.') {
                throw [System.IO.InvalidDataException]::new("GitHub commit lookup failed with HTTP 409 for $($entry.Repository); it is not a confirmed empty repository.")
            }
            $revisions[$entry.Repository] = [ordered]@{ repository = $entry.Repository; commit = $null; status = 'empty'; archived = $entry.Archived }
            continue
        }
        $commit = Get-AvmCatalogResponseJson -Response $response
        if ($commit.sha -cnotmatch '^[0-9a-f]{40}$') {
            throw [System.IO.InvalidDataException]::new("Cannot resolve an immutable source commit for $($entry.Repository).")
        }
        $entry.Commit = $commit.sha
        $entry.TreeSha = $commit.commit.tree.sha
        $trees.Add($entry)
    }
    $treeResponses = Invoke-AvmCatalogRequestSet -Activity 'Terraform repository trees' -GitHubToken $GitHubToken -Requests @(foreach ($entry in $trees) {
            New-AvmCatalogRequest -Uri "https://api.github.com/repos/$($entry.Repository)/git/trees/$($entry.TreeSha)?recursive=1"
        })
    $blobRequests = [System.Collections.Generic.List[hashtable]]::new()
    $blobOwners = [System.Collections.Generic.List[hashtable]]::new()
    for ($index = 0; $index -lt $trees.Count; $index++) {
        $entry = $trees[$index]
        $files = Get-AvmCatalogTerraformSourcePath -Repository $entry.Repository -Tree (Get-AvmCatalogResponseJson -Response $treeResponses[$index])
        foreach ($path in (Get-AvmCatalogOrdinal -Values @($files.Keys))) {
            $file = $files[$path]
            if ($file.type -cne 'blob' -or $file.mode -cnotin @('100644', '100755') -or $file.size -gt 5MB) {
                throw [System.IO.InvalidDataException]::new("Unsupported source entry (link, submodule or oversized blob): $($entry.Repository)/$path")
            }
            $blobRequests.Add((New-AvmCatalogRequest -Uri "https://raw.githubusercontent.com/$($entry.Repository)/$($entry.Commit)/$path" -Accept 'text/plain'))
            $blobOwners.Add(@{ Entry = $entry; Path = $path; Sha = $file.sha })
        }
        $revisions[$entry.Repository] = [ordered]@{ repository = $entry.Repository; commit = $entry.Commit; status = 'collected'; archived = $entry.Archived }
    }
    $blobResponses = Invoke-AvmCatalogRequestSet -Activity 'Terraform source blobs' -GitHubToken $GitHubToken -Requests @($blobRequests)
    for ($index = 0; $index -lt $blobOwners.Count; $index++) {
        $owner = $blobOwners[$index]
        $content = $blobResponses[$index]
        $prefix = [System.Text.Encoding]::UTF8.GetBytes("blob $($content.Bytes.Length)`0")
        $blob = [byte[]]::new($prefix.Length + $content.Bytes.Length)
        $prefix.CopyTo($blob, 0)
        $content.Bytes.CopyTo($blob, $prefix.Length)
        $sha = [Convert]::ToHexString([System.Security.Cryptography.SHA1]::HashData($blob)).ToLowerInvariant()
        if ($sha -cne $owner.Sha) {
            throw [System.Security.SecurityException]::new("Git blob verification failed for $($owner.Entry.Repository)/$($owner.Path).")
        }
        $owner.Bytes = $content.Bytes
    }
    foreach ($owner in $blobOwners) {
        if ($PSCmdlet.ShouldProcess("$($owner.Entry.Repository)/$($owner.Path)", 'Save read-only catalog source snapshot')) {
            $target = Join-Path $owner.Entry.Destination $owner.Path
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
            [System.IO.File]::WriteAllBytes($target, $owner.Bytes)
        }
    }
    return , @($repositories | ForEach-Object { $revisions[$_] })
}

function Save-AvmCatalogTerraformSource {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Repository, [string] $Destination, [securestring] $GitHubToken)

    return (Save-AvmCatalogTerraformSourceSet -GitHubToken $GitHubToken `
            -Target @(@{ Repository = $Repository; Destination = $Destination }))[0]
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
