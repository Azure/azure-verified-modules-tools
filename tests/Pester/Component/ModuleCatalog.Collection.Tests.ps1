#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    $catalogScripts = Join-Path $repoRoot 'repository-management' 'module-catalog' 'scripts'
    . (Join-Path $catalogScripts 'ModuleCatalog.ps1')
    . (Join-Path $catalogScripts 'ModuleCatalog.Collection.ps1')
    . (Join-Path $catalogScripts 'ModuleCatalog.Publication.ps1')
    $originalOffline = $env:AVM_OFFLINE

    if (-not ('AvmCatalogStubHandler' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public class AvmCatalogStubHandler : HttpMessageHandler
{
    public List<string> Requested = new List<string>();
    public Dictionary<string, int> AttemptsByUri = new Dictionary<string, int>();
    public Dictionary<string, int> TransientByUri = new Dictionary<string, int>();
    public Dictionary<string, int> StatusByUri = new Dictionary<string, int>();
    public HashSet<string> FaultUris = new HashSet<string>();

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        string uri = request.RequestUri.AbsoluteUri;
        lock (Requested)
        {
            Requested.Add(uri);
            AttemptsByUri[uri] = AttemptsByUri.ContainsKey(uri) ? AttemptsByUri[uri] + 1 : 1;
        }
        if (FaultUris.Contains(uri))
        {
            var failed = new TaskCompletionSource<HttpResponseMessage>();
            failed.SetException(new HttpRequestException("stub transport failure"));
            return failed.Task;
        }
        int remaining;
        if (TransientByUri.TryGetValue(uri, out remaining) && remaining > 0)
        {
            TransientByUri[uri] = remaining - 1;
            return Task.FromResult(new HttpResponseMessage((HttpStatusCode)503) { Content = new StringContent("{}") });
        }
        int status;
        if (!StatusByUri.TryGetValue(uri, out status))
        {
            status = 200;
        }
        var response = new HttpResponseMessage((HttpStatusCode)status);
        response.Content = new StringContent("{\"uri\":\"" + uri + "\"}");
        return Task.FromResult(response);
    }
}
'@
    }

    function Use-CatalogStubHandler {
        param([scriptblock] $Body)
        $handler = [AvmCatalogStubHandler]::new()
        $client = [System.Net.Http.HttpClient]::new($handler, $true)
        $client.Timeout = [TimeSpan]::FromSeconds(100)
        Set-Variable -Name AvmCatalogClient -Scope Script -Value $client
        try {
            & $Body $handler
        }
        finally {
            Set-Variable -Name AvmCatalogClient -Scope Script -Value $null
            $client.Dispose()
        }
    }

    function Get-AvmCatalogGraphQlMockRepositoryData {
        param([Parameter(Mandatory)][string] $Body, [Parameter(Mandatory)][scriptblock] $ResolveRepository)

        $query = (ConvertFrom-Json -InputObject $Body -AsHashtable).query
        $data = @{}
        foreach ($match in [regex]::Matches($query, 'g(\d+): repository\(owner: "([^"]+)", name: "([^"]+)"\)')) {
            $alias = "g$($match.Groups[1].Value)"
            $repository = "$($match.Groups[2].Value)/$($match.Groups[3].Value)"
            $data[$alias] = & $ResolveRepository $repository
        }
        return $data
    }
}

AfterAll {
    $env:AVM_OFFLINE = $originalOffline
}

Describe 'Component: module catalog HTTP boundary' -Tag Component {
    BeforeEach {
        $env:AVM_OFFLINE = $null
    }

    It 'accepts an intentional module 404 only when the caller explicitly permits not-found' {
        { Assert-AvmCatalogResponseStatus -Uri ([uri]'https://mcr.microsoft.com/v2/bicep/avm/res/test/module/tags/list') -StatusCode 404 -AllowNotFound } |
            Should -Not -Throw
        { Assert-AvmCatalogResponseStatus -Uri ([uri]'https://mcr.microsoft.com/v2/bicep/avm/res/test/module/manifests/1.0.0') -StatusCode 404 } |
            Should -Throw '*HTTP 404*'
    }

    It 'fails on authentication, rate-limit and service errors even at a not-found boundary: <Status>' -TestCases @(
        @{ Status = 401 }, @{ Status = 403 }, @{ Status = 409 }, @{ Status = 429 }, @{ Status = 500 }, @{ Status = 503 }
    ) {
        param($Status)
        { Assert-AvmCatalogResponseStatus -Uri ([uri]'https://registry.terraform.io/v1/modules/Azure/test/azurerm') -StatusCode $Status -AllowNotFound } |
            Should -Throw "*HTTP $Status*"
    }

    It 'treats an empty Git repository as absence only for the Terraform commit endpoint' {
        $commits = [uri]'https://api.github.com/repos/Azure/terraform-azurerm-avm-res-test-module/commits/main'
        { Assert-AvmCatalogResponseStatus -Uri $commits -StatusCode 409 -AllowEmptyRepository } | Should -Not -Throw
        { Assert-AvmCatalogResponseStatus -Uri $commits -StatusCode 409 } | Should -Throw '*HTTP 409*'
        { Assert-AvmCatalogResponseStatus -Uri ([uri]'https://api.github.com/repos/Azure/bicep-registry-modules') -StatusCode 409 -AllowEmptyRepository } |
            Should -Throw '*HTTP 409*'
    }

    It 'retries transient failures rather than losing a whole collection run' {
        foreach ($status in @(408, 429, 500, 502, 503, 504)) {
            Test-AvmCatalogTransientStatus -StatusCode $status | Should -BeTrue
        }
        foreach ($status in @(200, 401, 403, 404, 409)) {
            Test-AvmCatalogTransientStatus -StatusCode $status | Should -BeFalse
        }
        Test-AvmCatalogTransientStatus -StatusCode 403 -ResponseHeader @{ 'x-ratelimit-remaining' = '0' } | Should -BeTrue
        Test-AvmCatalogTransientStatus -StatusCode 403 -ResponseHeader @{ 'x-ratelimit-remaining' = '48' } | Should -BeFalse
        (Get-AvmCatalogRetryDelay -Attempt 1).TotalSeconds | Should -BeLessThan (Get-AvmCatalogRetryDelay -Attempt 3).TotalSeconds
        (Get-AvmCatalogRetryDelay -Attempt 1 -ResponseHeader @{ 'retry-after' = '17' }).TotalSeconds | Should -Be 17
        (Get-AvmCatalogRetryDelay -Attempt 1 -ResponseHeader @{ 'retry-after' = '3600' }).TotalSeconds | Should -Be 60
    }

    It 'restricts transport hosts, credentials and redirects' {
        { Assert-AvmCatalogUri -Uri 'http://api.github.com/users/test' } | Should -Throw '*fixed public HTTPS*'
        { Assert-AvmCatalogUri -Uri 'https://example.invalid/metadata.json' } | Should -Throw '*fixed public HTTPS*'
        { Assert-AvmCatalogUri -Uri 'https://test:secret@api.github.com/users/test' } | Should -Throw '*fixed public HTTPS*'
        $token = ConvertTo-SecureString -String 'offline-test-token' -AsPlainText -Force
        { Assert-AvmCatalogUri -Uri 'https://api.github.com:8443/users/test' } | Should -Throw '*fixed public HTTPS*'
        (Get-AvmCatalogHttpClient).Timeout | Should -BeGreaterThan ([TimeSpan]::FromSeconds(30))
        $registry = New-AvmCatalogRequestMessage -Uri 'https://mcr.microsoft.com/v2/bicep/avm/res/test/module/tags/list' -GitHubToken $token
        try {
            $registry.Headers.Contains('Authorization') | Should -BeFalse
            $registry.Method | Should -Be ([System.Net.Http.HttpMethod]::Get)
        }
        finally {
            $registry.Dispose()
        }
        $github = New-AvmCatalogRequestMessage -Uri 'https://api.github.com/users/test' -GitHubToken $token
        try {
            $github.Headers.GetValues('Authorization') | Should -Be 'Bearer offline-test-token'
        }
        finally {
            $github.Dispose()
        }
    }

    It 'honors offline mode without making a request' {
        $env:AVM_OFFLINE = '1'
        { Assert-AvmCatalogUri -Uri 'https://api.github.com/users/test' } | Should -Throw '*AVM_OFFLINE=1*'
        { Invoke-AvmCatalogRequest -Uri 'https://api.github.com/users/test' } | Should -Throw '*AVM_OFFLINE=1*'
    }

    It 'issues and returns <Count> batched request(s) in the caller supplied order' -TestCases @(
        @{ Count = 1 }
        @{ Count = 2 }
        @{ Count = 25 }
    ) {
        param($Count)
        Use-CatalogStubHandler {
            param($handler)
            $uris = @(1..$Count | ForEach-Object { "https://mcr.microsoft.com/v2/bicep/avm/res/test/module$_/tags/list" })
            $requests = @($uris | ForEach-Object { New-AvmCatalogRequest -Uri $_ })
            $results = Invoke-AvmCatalogRequestSet -Requests $requests
            @($results) | Should -HaveCount $Count
            for ($index = 0; $index -lt $Count; $index++) {
                $results[$index].StatusCode | Should -Be 200
                ($results[$index].Content | ConvertFrom-Json).uri | Should -BeExactly $uris[$index]
            }
            @($handler.Requested) | Should -HaveCount $Count
        }
    }

    It 'returns an empty result set without touching the transport' {
        Use-CatalogStubHandler {
            param($handler)
            $results = Invoke-AvmCatalogRequestSet -Requests @()
            @($results) | Should -HaveCount 0
            @($handler.Requested) | Should -HaveCount 0
        }
    }

    It 'batches across hosts and preserves per-request not-found handling' {
        Use-CatalogStubHandler {
            param($handler)
            $missing = 'https://mcr.microsoft.com/v2/bicep/avm/res/test/absent/tags/list'
            $handler.StatusByUri[$missing] = 404
            $requests = @(
                New-AvmCatalogRequest -Uri 'https://api.github.com/users/owner-one'
                New-AvmCatalogRequest -Uri $missing -AllowNotFound
                New-AvmCatalogRequest -Uri 'https://registry.terraform.io/v1/modules/Azure/test/azurerm'
            )
            $results = Invoke-AvmCatalogRequestSet -Requests $requests
            @($results) | Should -HaveCount 3
            $results[0].StatusCode | Should -Be 200
            $results[1].StatusCode | Should -Be 404
            $results[2].StatusCode | Should -Be 200
        }
    }

    It 'retries a transient failure inside the batch and still returns every result' {
        Use-CatalogStubHandler {
            param($handler)
            $flaky = 'https://mcr.microsoft.com/v2/bicep/avm/res/test/flaky/tags/list'
            $handler.TransientByUri[$flaky] = 2
            $requests = @(
                New-AvmCatalogRequest -Uri 'https://mcr.microsoft.com/v2/bicep/avm/res/test/stable/tags/list'
                New-AvmCatalogRequest -Uri $flaky
            )
            $results = Invoke-AvmCatalogRequestSet -Requests $requests
            @($results) | Should -HaveCount 2
            $results[0].StatusCode | Should -Be 200
            $results[1].StatusCode | Should -Be 200
            $handler.AttemptsByUri[$flaky] | Should -Be 3
            $handler.AttemptsByUri['https://mcr.microsoft.com/v2/bicep/avm/res/test/stable/tags/list'] | Should -Be 1
        }
    }

    It 'surfaces a persistent transport fault rather than returning a partial batch' {
        Use-CatalogStubHandler {
            param($handler)
            $broken = 'https://mcr.microsoft.com/v2/bicep/avm/res/test/broken/tags/list'
            $null = $handler.FaultUris.Add($broken)
            $requests = @(
                New-AvmCatalogRequest -Uri 'https://mcr.microsoft.com/v2/bicep/avm/res/test/stable/tags/list'
                New-AvmCatalogRequest -Uri $broken
            )
            { Invoke-AvmCatalogRequestSet -Requests $requests -MaxAttempt 2 } | Should -Throw '*stub transport failure*'
        }
    }

    It 'routes a single request through the batch path and returns its response' {
        Use-CatalogStubHandler {
            param($handler)
            $result = Invoke-AvmCatalogRequest -Uri 'https://api.github.com/users/owner-one'
            $result.StatusCode | Should -Be 200
            ($result.Content | ConvertFrom-Json).uri | Should -BeExactly 'https://api.github.com/users/owner-one'
        }
    }
}

Describe 'Component: module catalog registry collection' -Tag Component {
    BeforeEach {
        Mock Invoke-AvmCatalogRequestSet { throw [System.InvalidOperationException]::new("Unexpected offline request: $($Requests[0].Uri)") }
    }

    It 'preserves the UTC month after PowerShell decodes a registry timestamp as DateTime' {
        $response = [pscustomobject]@{ StatusCode = 200; Content = '{"published_at":"2024-07-01T00:30:00Z"}' }
        $data = Get-AvmCatalogResponseJson -Response $response
        $date = Get-AvmCatalogPublicationDate -Value $data.published_at -Identity 'test-release'
        $date.ToString('yyyy-MM') | Should -BeExactly '2024-07'
        $date.Offset | Should -Be ([TimeSpan]::Zero)
    }

    It 'requires an explicit time zone rather than treating an ambiguous date as local time' {
        { Get-AvmCatalogPublicationDate -Value '2024-07-01T00:30:00' -Identity 'test-release' } | Should -Throw '*publication timestamp*'
        { Get-AvmCatalogPublicationDate -Value ([datetime]::new(2024, 7, 1)) -Identity 'test-release' } | Should -Throw '*publication timestamp*'
        (Get-AvmCatalogPublicationDate -Value '2024-07-01T00:30:00+01:00' -Identity 'test-release').ToString('yyyy-MM') | Should -BeExactly '2024-06'
    }

    It 'uses MAR membership, semantic current versions and actual minimum publication dates for Bicep' {
        $identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/module'
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                $data = if ([string]$request.Uri -like '*/tags/list') {
                    @{ name = 'bicep/avm/res/test/module'; tags = @('1.9.0', '1.10.0') }
                }
                else {
                    $date = if ([string]$request.Uri -like '*/1.9.0') { '2024-03-10T00:00:00Z' } else { '2024-02-10T00:00:00Z' }
                    @{ schemaVersion = 2; mediaType = 'application/vnd.oci.image.manifest.v1+json'; annotations = @{ 'org.opencontainers.image.created' = $date } }
                }
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $data }
            }
        }
        $record = Get-AvmCatalogBicepRegistry -Identity $identity -Mar @($identity.ModulePath)
        $record.status | Should -BeExactly 'available'
        $record.currentVersion | Should -BeExactly '1.10.0'
        $record.firstPublishedIn | Should -BeExactly '2024-02'
        $record.marRegistered | Should -BeTrue
        $record.downloads | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 1 -ParameterFilter {
            @($Requests | Where-Object { $_.Accept -eq 'application/vnd.oci.image.manifest.v1+json' }).Count -eq 2
        }
    }

    It 'collects every module in a single batched pass rather than one request at a time' {
        $identities = @(
            (New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/first'),
            (New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/second')
        )
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                $path = ([string]$request.Uri) -replace '^https://mcr\.microsoft\.com/v2/bicep/(.+?)/(tags|manifests)/.*$', '$1'
                $data = if ([string]$request.Uri -like '*/tags/list') {
                    @{ name = "bicep/$path"; tags = @('1.0.0') }
                }
                else {
                    @{ schemaVersion = 2; mediaType = 'application/vnd.oci.image.manifest.v1+json'; annotations = @{ 'org.opencontainers.image.created' = '2024-05-01T00:00:00Z' } }
                }
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $data }
            }
        }
        $records = Get-AvmCatalogBicepRegistrySet -Identities $identities -Mar @($identities | ForEach-Object { $_.ModulePath })
        $records.Count | Should -Be 2
        foreach ($identity in $identities) {
            $records[$identity.Key].currentVersion | Should -BeExactly '1.0.0'
            $records[$identity.Key].firstPublishedIn | Should -BeExactly '2024-05'
        }
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 2 -Exactly
    }

    It 'keeps approved unpublished Bicep modules in the MAR contract' {
        $identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/module'
        Mock Invoke-AvmCatalogRequestSet { foreach ($request in $Requests) { [pscustomobject]@{ StatusCode = 404; Content = '{}' } } }
        $record = Get-AvmCatalogBicepRegistry -Identity $identity -Mar @($identity.ModulePath)
        $record.status | Should -BeExactly 'not-published'
        $record.currentVersion | Should -BeNullOrEmpty
        $record.marRegistered | Should -BeTrue
    }

    It 'fails for a published module missing from MAR instead of inventing mirror membership' {
        $identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/module'
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                [pscustomobject]@{ StatusCode = 200; Content = '{"name":"bicep/avm/res/test/module","tags":["1.0.0"]}' }
            }
        }
        { Get-AvmCatalogBicepRegistry -Identity $identity -Mar @() } | Should -Throw '*absent from the approved MAR mirror*'
    }

    It 'rejects unsupported publication timestamp data rather than guessing first-published month' {
        $identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/module'
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                $body = if ([string]$request.Uri -like '*/tags/list') {
                    '{"name":"bicep/avm/res/test/module","tags":["1.0.0"]}'
                }
                else {
                    '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","annotations":{}}'
                }
                [pscustomobject]@{ StatusCode = 200; Content = $body }
            }
        }
        { Get-AvmCatalogBicepRegistry -Identity $identity -Mar @($identity.ModulePath) } | Should -Throw '*lacks a supported creation timestamp*'
    }

    It 'derives Terraform child availability and dates from releases containing that submodule, without attributing root downloads' {
        $identity = New-AvmCatalogIdentity -Ecosystem terraform -Repository 'Azure/terraform-azure-avm-res-test-module' -ModulePath '.'
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                $version = if ([string]$request.Uri -like '*/1.9.0') { '1.9.0' } else { '1.10.0' }
                $data = @{
                    namespace = 'Azure'; name = 'avm-res-test-module'; provider = 'azure'
                    version = $version; versions = @('1.9.0', '1.10.0'); downloads = 678
                    published_at = if ($version -eq '1.9.0') { '2024-03-01T00:00:00Z' } else { '2024-02-01T00:00:00Z' }
                    submodules = @(if ($version -eq '1.9.0') { @{ path = 'modules/old_child' } } else { @{ path = 'modules/new_child' } })
                }
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $data }
            }
        }
        $family = Get-AvmCatalogTerraformRegistry -Identity $identity
        $family.Root.currentVersion | Should -BeExactly '1.10.0'
        $family.Root.firstPublishedIn | Should -BeExactly '2024-02'
        $family.Root.downloads | Should -Be 678
        $family.Children['modules/old_child'].firstPublishedIn | Should -BeExactly '2024-03'
        $family.Children['modules/old_child'].currentVersion | Should -BeExactly '1.9.0'
        $family.Children['modules/new_child'].downloads | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 2 -Exactly
    }

    It 'represents a Terraform Registry module 404 explicitly as not-published' {
        $identity = New-AvmCatalogIdentity -Ecosystem terraform -Repository 'Azure/terraform-azapi-avm-utl-test-module' -ModulePath '.'
        Mock Invoke-AvmCatalogRequestSet { foreach ($request in $Requests) { [pscustomobject]@{ StatusCode = 404; Content = '{}' } } }
        (Get-AvmCatalogTerraformRegistry -Identity $identity).Root.status | Should -BeExactly 'not-published'
    }

    It 'caches every migrated user and team across modules and permits profiles with no personal name' {
        $owners = @('owner-one', '@Azure/avm-core-modules', '@Azure/second-team')
        $inventory = [pscustomobject]@{
            Mar = @('avm/res/test/module', 'avm/res/test/other')
            Items = @(
                [pscustomobject]@{ Identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/module'; Record = @{ metadataSource = 'metadata'; owners = $owners } },
                [pscustomobject]@{ Identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/other'; Record = @{ metadataSource = 'metadata'; owners = $owners } }
            )
        }
        Mock Get-AvmCatalogBicepRegistrySet { @{} }
        Mock Invoke-AvmCatalogRequestSet {
            $data = @{}
            foreach ($request in $Requests) {
                $query = (ConvertFrom-Json -InputObject $request.Body -AsHashtable).query
                foreach ($match in [regex]::Matches($query, 'g(\d+): user\(login: "([^"]+)"\)')) {
                    $data["g$($match.Groups[1].Value)"] = @{ login = 'owner-one'; name = $null; __typename = 'User' }
                }
                foreach ($match in [regex]::Matches($query, 'g(\d+): organization\(login: "Azure"\) \{ team\(slug: "([^"]+)"\)')) {
                    $data["g$($match.Groups[1].Value)"] = @{ team = @{ slug = $match.Groups[2].Value; organization = @{ login = 'Azure' } } }
                }
            }
            [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value @{ data = $data } }
        }
        $enrichment = Get-AvmCatalogEnrichment -Inventory $inventory
        $enrichment.GitHub.users.Count | Should -Be 1
        $enrichment.GitHub.teams.Count | Should -Be 2
        $enrichment.GitHub.users['owner-one'].name | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 1 -Exactly -ParameterFilter {
            if (@($Requests).Count -ne 1 -or $Requests[0].Method -ne 'POST' -or [string]$Requests[0].Uri -ne 'https://api.github.com/graphql' -or -not $Requests[0].Body) {
                return $false
            }
            $query = (ConvertFrom-Json -InputObject $Requests[0].Body -AsHashtable).query
            $query -match 'user\(login: "owner-one"\)' -and
            @([regex]::Matches($query, 'organization\(login: "Azure"\) \{ team\(slug: "[^"]+"\)')).Count -eq 2
        }
    }

    It 'rejects truncated GitHub discovery instead of publishing a partial fleet' {
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                [pscustomobject]@{ StatusCode = 200; Content = '{"incomplete_results":true,"total_count":2,"items":[]}' }
            }
        }
        { Get-AvmCatalogTerraformRepositories -LegacyPath $TestDrive } | Should -Throw '*GitHub search is incomplete*'
    }
}

Describe 'Component: module catalog immutable source snapshots' -Tag Component {
    BeforeEach {
        $script:sourceRepository = 'Azure/terraform-azurerm-avm-res-test-module'
        $script:sourceCommit = 'a' * 40
        $script:sourceArchived = $false
        $script:sourceBytes = @{
            'main.tf' = [System.Text.Encoding]::UTF8.GetBytes("terraform {}`n")
            'metadata.json' = [byte[]]@(239, 187, 191, 123, 125)
        }
        $script:sourceEntries = @()
        foreach ($path in $script:sourceBytes.Keys) {
            $bytes = $script:sourceBytes[$path]
            $prefix = [System.Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)`0")
            $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA1]::HashData([byte[]]($prefix + $bytes))).ToLowerInvariant()
            $script:sourceEntries += @{ path = $path; type = 'blob'; mode = '100644'; size = $bytes.Length; sha = $hash }
        }
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                $url = [string]$request.Uri
                if ($url -like 'https://raw.githubusercontent.com/*') {
                    $fileName = $url.Substring($url.LastIndexOf('/') + 1)
                    [pscustomobject]@{
                        StatusCode = 200; Bytes = $script:sourceBytes[$fileName]
                        Content = [System.Text.Encoding]::UTF8.GetString($script:sourceBytes[$fileName])
                    }
                    continue
                }
                if ($url -eq 'https://api.github.com/graphql') {
                    [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value @{
                            data = Get-AvmCatalogGraphQlMockRepositoryData -Body $request.Body -ResolveRepository {
                                param($repository)
                                if ($repository -ne $script:sourceRepository) { return $null }
                                @{
                                    nameWithOwner = $repository; isPrivate = $false; isArchived = $script:sourceArchived
                                    defaultBranchRef = @{ target = @{ oid = $script:sourceCommit; tree = @{ oid = 'b' * 40 } } }
                                }
                            }
                        }
                    }
                    continue
                }
                $body = if ($url -like '*/git/trees/*') {
                    @{ truncated = $false; tree = $script:sourceEntries }
                }
                else {
                    throw [System.InvalidOperationException]::new("Unexpected offline source request: $url")
                }
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $body }
            }
        }
    }

    It 'fetches commit-pinned blobs, verifies their Git hashes and preserves invalid metadata bytes for the shared validator' {
        $root = Join-Path $TestDrive 'source-copy'
        $result = Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false
        $result.commit | Should -BeExactly $script:sourceCommit
        $result.archived | Should -BeFalse
        [System.IO.File]::ReadAllBytes((Join-Path $root 'metadata.json')) | Should -Be $script:sourceBytes['metadata.json']
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 1 -ParameterFilter {
            @($Requests | Where-Object { [string]$_.Uri -like "https://raw.githubusercontent.com/*/$script:sourceCommit/*" }).Count -eq 2
        }
    }

    It 'records an archived repository without skipping its source' {
        $script:sourceArchived = $true
        $root = Join-Path $TestDrive 'archived-source-copy'
        $result = Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false
        $result.archived | Should -BeTrue
        $result.status | Should -Be 'collected'
        (Join-Path $root 'main.tf') | Should -Exist
    }

    It 'rejects unknown archive state instead of defaulting it to active: <Value>' -TestCases @(
        @{ Value = $null }
        @{ Value = 'false' }
        @{ Value = 0 }
    ) {
        param($Value)
        $script:sourceArchived = $Value
        $root = Join-Path $TestDrive 'invalid-archive-state'
        { Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false } |
            Should -Throw '*valid archived flag*'
        Test-Path $root | Should -BeFalse
    }

    It 'does not infer archive state for an unavailable repository' {
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) { [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value @{ data = @{ g0 = $null } } } }
        }
        $result = Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $TestDrive -Confirm:$false
        $result.status | Should -Be 'not-found'
        $result.archived | Should -BeNullOrEmpty
    }

    It 'rejects linked source files rather than following or executing them' {
        foreach ($entry in $script:sourceEntries) {
            $entry.mode = '120000'
        }
        $root = Join-Path $TestDrive 'rejected-link'
        { Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false } | Should -Throw '*Unsupported source entry*'
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'rejects a mismatched blob hash' {
        foreach ($entry in $script:sourceEntries) {
            $entry.sha = 'c' * 40
        }
        $root = Join-Path $TestDrive 'rejected-hash'
        { Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false } | Should -Throw '*Git blob verification failed*'
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'reports a confirmed empty repository without inventing a default commit' {
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value @{
                        data = @{ g0 = @{ nameWithOwner = $script:sourceRepository; isPrivate = $false; isArchived = $true; defaultBranchRef = $null } }
                    }
                }
            }
        }
        $root = Join-Path $TestDrive 'empty-source'
        $result = Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false
        $result.status | Should -BeExactly 'empty'
        $result.archived | Should -BeTrue
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'rejects an unresolved commit or tree for a repository that is not confirmed empty' {
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value @{
                        data = @{ g0 = @{ nameWithOwner = $script:sourceRepository; isPrivate = $false; isArchived = $false; defaultBranchRef = @{ target = @{ oid = 'not-a-sha' } } } }
                    }
                }
            }
        }
        { Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $TestDrive -Confirm:$false } |
            Should -Throw '*Cannot resolve an immutable source commit*'
    }

    It 'collects every repository through shared batched phases' {
        $second = 'Azure/terraform-azurerm-avm-res-test-other'
        $target = @(
            @{ Repository = $script:sourceRepository; Destination = (Join-Path $TestDrive 'batch' 'first') },
            @{ Repository = $second; Destination = (Join-Path $TestDrive 'batch' 'second') }
        )
        Mock Invoke-AvmCatalogRequestSet {
            foreach ($request in $Requests) {
                $url = [string]$request.Uri
                if ($url -like 'https://raw.githubusercontent.com/*') {
                    $fileName = $url.Substring($url.LastIndexOf('/') + 1)
                    [pscustomobject]@{
                        StatusCode = 200; Bytes = $script:sourceBytes[$fileName]
                        Content = [System.Text.Encoding]::UTF8.GetString($script:sourceBytes[$fileName])
                    }
                    continue
                }
                if ($url -eq 'https://api.github.com/graphql') {
                    [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value @{
                            data = Get-AvmCatalogGraphQlMockRepositoryData -Body $request.Body -ResolveRepository {
                                param($repository)
                                @{
                                    nameWithOwner = $repository; isPrivate = $false; isArchived = $false
                                    defaultBranchRef = @{ target = @{ oid = $script:sourceCommit; tree = @{ oid = 'b' * 40 } } }
                                }
                            }
                        }
                    }
                    continue
                }
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value @{ truncated = $false; tree = $script:sourceEntries } }
            }
        }
        $results = Save-AvmCatalogTerraformSourceSet -Target $target -Confirm:$false
        @($results).Count | Should -Be 2
        $results[0].repository | Should -BeExactly $script:sourceRepository
        $results[1].repository | Should -BeExactly $second
        foreach ($entry in $target) {
            (Join-Path $entry.Destination 'main.tf') | Should -Exist
        }
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 3 -Exactly
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 1 -Exactly -ParameterFilter {
            @($Requests).Count -eq 1 -and $Requests[0].Method -eq 'POST' -and [string]$Requests[0].Uri -eq 'https://api.github.com/graphql'
        }
    }
}

Describe 'Component: module catalog publication inputs' -Tag Component {
    It 'reads canonical CSVs and captures publication bases for <Destination> outputs' -TestCases @(
        @{ Destination = 'canonical' }
        @{ Destination = 'preview' }
    ) {
        param($Destination)
        $configuration = Read-AvmCatalogConfiguration
        if ($Destination -eq 'preview') {
            $raw = Read-AvmCatalogJson -Path (Join-Path $catalogScripts '..' 'config.json')
            foreach ($csv in $raw.outputs | Where-Object kind -eq 'csv') { $csv.file = "test-$($csv.sourceFile)" }
            $configurationPath = Join-Path $TestDrive 'preview-manifest.json'
            [System.IO.File]::WriteAllText($configurationPath, (ConvertTo-AvmCatalogJson -Value $raw))
            $configuration = Read-AvmCatalogConfiguration -Path $configurationPath
        }
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $roots = @{ docs = Join-Path $root 'docs'; tools = Join-Path $root 'tools' }
        $snapshot = Join-Path $root 'snapshot'
        $originals = @{}
        foreach ($output in $configuration.outputs | Where-Object { $_.kind -in @('csv', 'mar') }) {
            $sourcePath = if ($output.kind -eq 'csv') { $output.sourcePath } else { $output.targetPath }
            $file = Join-Path $roots[$output.destination] $sourcePath
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
            $text = if ($output.kind -eq 'csv') {
                "ModuleName,ModuleDisplayName,RepoURL,ModuleStatus,Description`n"
            }
            else {
                "[]`n"
            }
            [System.IO.File]::WriteAllText($file, $text, [System.Text.UTF8Encoding]::new($false))
            $originals[$sourcePath] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $csvs = @($configuration.outputs | Where-Object kind -eq 'csv')
        $previewPath = "$($configuration.destinations.docs.path)/test-$($csvs[0].sourceFile)"
        $oldPreview = Join-Path $roots.docs $previewPath
        [System.IO.File]::WriteAllText($oldPreview, 'Not a CSV input.')
        $previewHash = (Get-FileHash -LiteralPath $oldPreview -Algorithm SHA256).Hash.ToLowerInvariant()
        $plan = Copy-AvmCatalogInputFile -Configuration $configuration -RepositoryRoots $roots -SnapshotPath $snapshot
        foreach ($csv in $csvs) {
            $copied = Join-Path $snapshot 'legacy' $csv.sourceFile
            (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $originals[$csv.sourcePath]
            $plan.docs.baseFiles[$csv.sourcePath] | Should -BeExactly $originals[$csv.sourcePath]
            Test-Path -LiteralPath (Join-Path $snapshot 'legacy' "test-$($csv.sourceFile)") | Should -BeFalse
            (Get-FileHash -LiteralPath (Join-Path $roots.docs $csv.sourcePath) -Algorithm SHA256).Hash.ToLowerInvariant() |
                Should -BeExactly $originals[$csv.sourcePath]
        }
        if ($Destination -eq 'preview') {
            $plan.docs.baseFiles[$csvs[0].targetPath] | Should -BeExactly $previewHash
            $plan.docs.baseFiles[$csvs[1].targetPath] | Should -BeNullOrEmpty
            $plan.docs.baseFiles.Count | Should -Be 14
        }
        else {
            $plan.docs.baseFiles.Contains($previewPath) | Should -BeFalse
            $plan.docs.baseFiles.Count | Should -Be 8
        }
        { Assert-AvmCatalogPublicationBase -Root $roots.docs -BaseFiles $plan.docs.baseFiles } | Should -Not -Throw
        [System.IO.File]::AppendAllText((Join-Path $roots.docs $csvs[0].sourcePath), 'new canonical input')
        { Assert-AvmCatalogPublicationBase -Root $roots.docs -BaseFiles $plan.docs.baseFiles } | Should -Throw '*base changed*'
        [System.IO.File]::ReadAllText($oldPreview) | Should -BeExactly 'Not a CSV input.'
    }
}
