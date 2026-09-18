#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    $catalogScripts = Join-Path $repoRoot 'repository-management' 'module-catalog' 'scripts'
    . (Join-Path $catalogScripts 'ModuleCatalog.ps1')
    . (Join-Path $catalogScripts 'ModuleCatalog.Collection.ps1')
    . (Join-Path $catalogScripts 'ModuleCatalog.Publication.ps1')
    $originalOffline = $env:AVM_OFFLINE
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
            foreach ($request in $Requests) {
                $data = if ([string]$request.Uri -like '*/users/*') {
                    @{ login = 'owner-one'; name = $null; type = 'User' }
                }
                else {
                    @{ slug = ([uri]$request.Uri).Segments[-1]; organization = @{ login = 'Azure' } }
                }
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $data }
            }
        }
        $enrichment = Get-AvmCatalogEnrichment -Inventory $inventory
        $enrichment.GitHub.users.Count | Should -Be 1
        $enrichment.GitHub.teams.Count | Should -Be 2
        $enrichment.GitHub.users['owner-one'].name | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 1 -ParameterFilter { @($Requests).Count -eq 1 -and [string]$Requests[0].Uri -like '*/users/owner-one' }
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 1 -ParameterFilter { @($Requests).Count -eq 2 -and [string]$Requests[0].Uri -like '*/orgs/Azure/teams/*' }
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
                $body = if ($url -eq "https://api.github.com/repos/$script:sourceRepository") {
                    @{ full_name = $script:sourceRepository; private = $false; default_branch = 'main'; archived = $script:sourceArchived }
                }
                elseif ($url -like '*/commits/main') {
                    @{ sha = $script:sourceCommit; commit = @{ tree = @{ sha = 'b' * 40 } } }
                }
                elseif ($url -like '*/git/trees/*') {
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
        Mock Invoke-AvmCatalogRequestSet { foreach ($request in $Requests) { [pscustomobject]@{ StatusCode = 404; Content = '{}' } } }
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

    It 'reports a confirmed empty repository without treating other 409 responses as absence' {
        Mock Invoke-AvmCatalogRequestSet {
            [pscustomobject]@{ StatusCode = 409; Content = '{"message":"Git Repository is empty."}' }
        } -ParameterFilter { [string]$Requests[0].Uri -like '*/commits/main' }
        $root = Join-Path $TestDrive 'empty-source'
        $script:sourceArchived = $true
        $result = Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false
        $result.status | Should -BeExactly 'empty'
        $result.archived | Should -BeTrue
        Test-Path -LiteralPath $root | Should -BeFalse
        Mock Invoke-AvmCatalogRequestSet {
            [pscustomobject]@{ StatusCode = 409; Content = '{"message":"Unexpected service state"}' }
        } -ParameterFilter { [string]$Requests[0].Uri -like '*/commits/main' }
        { Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false } | Should -Throw '*not a confirmed empty repository*'
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
                $repository = ($url -replace '^https://api\.github\.com/repos/([^/]+/[^/]+).*$', '$1')
                $body = if ($url -match '^https://api\.github\.com/repos/[^/]+/[^/]+$') {
                    @{ full_name = $repository; private = $false; default_branch = 'main'; archived = $false }
                }
                elseif ($url -like '*/commits/main') {
                    @{ sha = $script:sourceCommit; commit = @{ tree = @{ sha = 'b' * 40 } } }
                }
                else {
                    @{ truncated = $false; tree = $script:sourceEntries }
                }
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $body }
            }
        }
        $results = Save-AvmCatalogTerraformSourceSet -Target $target -Confirm:$false
        @($results).Count | Should -Be 2
        $results[0].repository | Should -BeExactly $script:sourceRepository
        $results[1].repository | Should -BeExactly $second
        foreach ($entry in $target) {
            (Join-Path $entry.Destination 'main.tf') | Should -Exist
        }
        Should -Invoke Invoke-AvmCatalogRequestSet -Times 4 -Exactly
    }
}

Describe 'Component: module catalog preview inputs' -Tag Component {
    It 'reads canonical CSVs rather than preview files and captures both sets of publication bases' {
        $configuration = Read-AvmCatalogConfiguration
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
        $oldPreview = Join-Path $roots.docs $csvs[0].targetPath
        [System.IO.File]::WriteAllText($oldPreview, 'Not a CSV input.')
        $previewHash = (Get-FileHash -LiteralPath $oldPreview -Algorithm SHA256).Hash.ToLowerInvariant()
        $plan = Copy-AvmCatalogInputFile -Configuration $configuration -RepositoryRoots $roots -SnapshotPath $snapshot
        foreach ($csv in $csvs) {
            $copied = Join-Path $snapshot 'legacy' $csv.sourceFile
            (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $originals[$csv.sourcePath]
            $plan.docs.baseFiles[$csv.sourcePath] | Should -BeExactly $originals[$csv.sourcePath]
            Test-Path -LiteralPath (Join-Path $snapshot 'legacy' $csv.file) | Should -BeFalse
            (Get-FileHash -LiteralPath (Join-Path $roots.docs $csv.sourcePath) -Algorithm SHA256).Hash.ToLowerInvariant() |
                Should -BeExactly $originals[$csv.sourcePath]
        }
        $plan.docs.baseFiles[$csvs[0].targetPath] | Should -BeExactly $previewHash
        $plan.docs.baseFiles[$csvs[1].targetPath] | Should -BeNullOrEmpty
        { Assert-AvmCatalogPublicationBase -Root $roots.docs -BaseFiles $plan.docs.baseFiles } | Should -Not -Throw
        [System.IO.File]::AppendAllText((Join-Path $roots.docs $csvs[0].sourcePath), 'new canonical input')
        { Assert-AvmCatalogPublicationBase -Root $roots.docs -BaseFiles $plan.docs.baseFiles } | Should -Throw '*base changed*'
        [System.IO.File]::ReadAllText($oldPreview) | Should -BeExactly 'Not a CSV input.'
    }
}
