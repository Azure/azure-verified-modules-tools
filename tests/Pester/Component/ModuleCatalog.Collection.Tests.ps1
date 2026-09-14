#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..' '..' '..'
    $catalogScripts = Join-Path $repoRoot 'repository-management' 'module-catalog' 'scripts'
    . (Join-Path $catalogScripts 'ModuleCatalog.ps1')
    . (Join-Path $catalogScripts 'ModuleCatalog.Collection.ps1')
    $originalOffline = $env:AVM_OFFLINE
}

AfterAll {
    $env:AVM_OFFLINE = $originalOffline
}

Describe 'Component: module catalog HTTP boundary' -Tag Component {
    BeforeEach {
        $env:AVM_OFFLINE = $null
        $script:catalogHttpStatus = 200
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = $script:catalogHttpStatus
                Content = '{"ok":true}'
                RawContentStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes('{"ok":true}'))
            }
        }
    }

    It 'accepts an intentional module 404 only when the caller explicitly permits not-found' {
        $script:catalogHttpStatus = 404
        (Invoke-AvmCatalogRequest -Uri 'https://mcr.microsoft.com/v2/bicep/avm/res/test/module/tags/list' -AllowNotFound).StatusCode | Should -Be 404
        { Invoke-AvmCatalogRequest -Uri 'https://mcr.microsoft.com/v2/bicep/avm/res/test/module/manifests/1.0.0' } | Should -Throw '*HTTP 404*'
    }

    It 'fails on authentication, rate-limit and service errors even at a not-found boundary: <Status>' -TestCases @(
        @{ Status = 401 }, @{ Status = 403 }, @{ Status = 409 }, @{ Status = 429 }, @{ Status = 500 }, @{ Status = 503 }
    ) {
        param($Status)
        $script:catalogHttpStatus = $Status
        { Invoke-AvmCatalogRequest -Uri 'https://registry.terraform.io/v1/modules/Azure/test/azurerm' -AllowNotFound } | Should -Throw "*HTTP $Status*"
    }

    It 'does not turn a network error into not-published' {
        Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('offline test network failure') }
        { Invoke-AvmCatalogRequest -Uri 'https://registry.terraform.io/v1/modules/Azure/test/azurerm' -AllowNotFound } | Should -Throw '*network failure*'
    }

    It 'restricts transport hosts, credentials and redirects' {
        { Invoke-AvmCatalogRequest -Uri 'http://api.github.com/users/test' } | Should -Throw '*fixed public HTTPS*'
        { Invoke-AvmCatalogRequest -Uri 'https://example.invalid/metadata.json' } | Should -Throw '*fixed public HTTPS*'
        { Invoke-AvmCatalogRequest -Uri 'https://test:secret@api.github.com/users/test' } | Should -Throw '*fixed public HTTPS*'
        $token = ConvertTo-SecureString -String 'offline-test-token' -AsPlainText -Force
        $null = Invoke-AvmCatalogRequest -Uri 'https://mcr.microsoft.com/v2/bicep/avm/res/test/module/tags/list' -GitHubToken $token
        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
            $MaximumRedirection -eq 0 -and -not $Headers.ContainsKey('Authorization') -and $Method -eq 'Get'
        }
    }

    It 'honors offline mode without making a request' {
        $env:AVM_OFFLINE = '1'
        { Invoke-AvmCatalogRequest -Uri 'https://api.github.com/users/test' } | Should -Throw '*AVM_OFFLINE=1*'
        Should -Invoke Invoke-WebRequest -Times 0
    }
}

Describe 'Component: module catalog registry collection' -Tag Component {
    BeforeEach {
        Mock Invoke-AvmCatalogRequest { throw [System.InvalidOperationException]::new("Unexpected offline request: $Uri") }
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
        Mock Invoke-AvmCatalogRequest {
            if ([string]$Uri -like '*/tags/list') {
                $data = @{ name = 'bicep/avm/res/test/module'; tags = @('1.9.0', '1.10.0') }
            }
            else {
                $date = if ([string]$Uri -like '*/1.9.0') { '2024-03-10T00:00:00Z' } else { '2024-02-10T00:00:00Z' }
                $data = @{ schemaVersion = 2; mediaType = 'application/vnd.oci.image.manifest.v1+json'; annotations = @{ 'org.opencontainers.image.created' = $date } }
            }
            [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $data }
        }
        $record = Get-AvmCatalogBicepRegistry -Identity $identity -Mar @($identity.ModulePath)
        $record.status | Should -BeExactly 'available'
        $record.currentVersion | Should -BeExactly '1.10.0'
        $record.firstPublishedIn | Should -BeExactly '2024-02'
        $record.marRegistered | Should -BeTrue
        $record.downloads | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmCatalogRequest -Times 2 -ParameterFilter { $Accept -eq 'application/vnd.oci.image.manifest.v1+json' }
    }

    It 'keeps approved unpublished Bicep modules in the MAR contract' {
        $identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/module'
        Mock Invoke-AvmCatalogRequest { [pscustomobject]@{ StatusCode = 404; Content = '{}' } }
        $record = Get-AvmCatalogBicepRegistry -Identity $identity -Mar @($identity.ModulePath)
        $record.status | Should -BeExactly 'not-published'
        $record.currentVersion | Should -BeNullOrEmpty
        $record.marRegistered | Should -BeTrue
    }

    It 'fails for a published module missing from MAR instead of inventing mirror membership' {
        $identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/module'
        Mock Invoke-AvmCatalogRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '{"name":"bicep/avm/res/test/module","tags":["1.0.0"]}' }
        }
        { Get-AvmCatalogBicepRegistry -Identity $identity -Mar @() } | Should -Throw '*absent from the approved MAR mirror*'
    }

    It 'rejects unsupported publication timestamp data rather than guessing first-published month' {
        $identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/module'
        Mock Invoke-AvmCatalogRequest {
            $body = if ([string]$Uri -like '*/tags/list') {
                '{"name":"bicep/avm/res/test/module","tags":["1.0.0"]}'
            }
            else {
                '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","annotations":{}}'
            }
            [pscustomobject]@{ StatusCode = 200; Content = $body }
        }
        { Get-AvmCatalogBicepRegistry -Identity $identity -Mar @($identity.ModulePath) } | Should -Throw '*lacks a supported creation timestamp*'
    }

    It 'derives Terraform child availability and dates from releases containing that submodule, without attributing root downloads' {
        $identity = New-AvmCatalogIdentity -Ecosystem terraform -Repository 'Azure/terraform-azure-avm-res-test-module' -ModulePath '.'
        Mock Invoke-AvmCatalogRequest {
            $version = if ([string]$Uri -like '*/1.9.0') { '1.9.0' } else { '1.10.0' }
            $data = @{
                namespace = 'Azure'; name = 'avm-res-test-module'; provider = 'azure'
                version = $version; versions = @('1.9.0', '1.10.0'); downloads = 678
                published_at = if ($version -eq '1.9.0') { '2024-03-01T00:00:00Z' } else { '2024-02-01T00:00:00Z' }
                submodules = @(if ($version -eq '1.9.0') { @{ path = 'modules/old_child' } } else { @{ path = 'modules/new_child' } })
            }
            [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $data }
        }
        $family = Get-AvmCatalogTerraformRegistry -Identity $identity
        $family.Root.currentVersion | Should -BeExactly '1.10.0'
        $family.Root.firstPublishedIn | Should -BeExactly '2024-02'
        $family.Root.downloads | Should -Be 678
        $family.Children['modules/old_child'].firstPublishedIn | Should -BeExactly '2024-03'
        $family.Children['modules/old_child'].currentVersion | Should -BeExactly '1.9.0'
        $family.Children['modules/new_child'].downloads | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmCatalogRequest -Times 2
    }

    It 'represents a Terraform Registry module 404 explicitly as not-published' {
        $identity = New-AvmCatalogIdentity -Ecosystem terraform -Repository 'Azure/terraform-azapi-avm-utl-test-module' -ModulePath '.'
        Mock Invoke-AvmCatalogRequest { [pscustomobject]@{ StatusCode = 404; Content = '{}' } }
        (Get-AvmCatalogTerraformRegistry -Identity $identity).Root.status | Should -BeExactly 'not-published'
    }

    It 'caches every migrated user and team across modules and permits profiles with no personal name' {
        $owners = @{ individuals = @(@{ githubHandle = 'owner-one' }); team = '@Azure/avm-core-modules' }
        $inventory = [pscustomobject]@{
            Mar = @('avm/res/test/module', 'avm/res/test/other')
            Items = @(
                [pscustomobject]@{ Identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/module'; Record = @{ metadataSource = 'metadata'; owners = $owners } },
                [pscustomobject]@{ Identity = New-AvmCatalogIdentity -Ecosystem bicep -Repository 'Azure/bicep-registry-modules' -ModulePath 'avm/res/test/other'; Record = @{ metadataSource = 'metadata'; owners = $owners } }
            )
        }
        Mock Get-AvmCatalogBicepRegistry { New-AvmCatalogRegistryResult -MarRegistered $true }
        Mock Invoke-AvmCatalogRequest {
            $data = if ([string]$Uri -like '*/users/*') {
                @{ login = 'owner-one'; name = $null; type = 'User' }
            }
            else {
                @{ slug = 'avm-core-modules'; organization = @{ login = 'Azure' } }
            }
            [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $data }
        }
        $enrichment = Get-AvmCatalogEnrichment -Inventory $inventory
        $enrichment.GitHub.users.Count | Should -Be 1
        $enrichment.GitHub.teams.Count | Should -Be 1
        $enrichment.GitHub.users['owner-one'].name | Should -BeNullOrEmpty
        Should -Invoke Invoke-AvmCatalogRequest -Times 2
    }

    It 'rejects truncated GitHub discovery instead of publishing a partial fleet' {
        Mock Invoke-AvmCatalogRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '{"incomplete_results":true,"total_count":2,"items":[]}' }
        }
        { Get-AvmCatalogTerraformRepositories -LegacyPath $TestDrive } | Should -Throw '*GitHub search is incomplete*'
    }
}

Describe 'Component: module catalog immutable source snapshots' -Tag Component {
    BeforeEach {
        $script:sourceRepository = 'Azure/terraform-azurerm-avm-res-test-module'
        $script:sourceCommit = 'a' * 40
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
        Mock Invoke-AvmCatalogRequest {
            $url = [string]$Uri
            $body = if ($url -eq "https://api.github.com/repos/$script:sourceRepository") {
                @{ full_name = $script:sourceRepository; private = $false; default_branch = 'main' }
            }
            elseif ($url -like '*/commits/main') {
                @{ sha = $script:sourceCommit; commit = @{ tree = @{ sha = 'b' * 40 } } }
            }
            elseif ($url -like '*/git/trees/*') {
                @{ truncated = $false; tree = $script:sourceEntries }
            }
            elseif ($url -like 'https://raw.githubusercontent.com/*') {
                $fileName = $url.Substring($url.LastIndexOf('/') + 1)
                return [pscustomobject]@{
                    StatusCode = 200; Bytes = $script:sourceBytes[$fileName]
                    Content = [System.Text.Encoding]::UTF8.GetString($script:sourceBytes[$fileName])
                }
            }
            else {
                throw [System.InvalidOperationException]::new("Unexpected offline source request: $url")
            }
            [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-AvmCatalogJson -Value $body }
        }
    }

    It 'fetches commit-pinned blobs, verifies their Git hashes and preserves invalid metadata bytes for the shared validator' {
        $root = Join-Path $TestDrive 'source-copy'
        $result = Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false
        $result.commit | Should -BeExactly $script:sourceCommit
        [System.IO.File]::ReadAllBytes((Join-Path $root 'metadata.json')) | Should -Be $script:sourceBytes['metadata.json']
        Should -Invoke Invoke-AvmCatalogRequest -Times 2 -ParameterFilter { [string]$Uri -like "https://raw.githubusercontent.com/*/$script:sourceCommit/*" }
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
        Mock Invoke-AvmCatalogRequest {
            [pscustomobject]@{ StatusCode = 409; Content = '{"message":"Git Repository is empty."}' }
        } -ParameterFilter { [string]$Uri -like '*/commits/main' }
        $root = Join-Path $TestDrive 'empty-source'
        (Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false).status | Should -BeExactly 'empty'
        Test-Path -LiteralPath $root | Should -BeFalse
        Mock Invoke-AvmCatalogRequest {
            [pscustomobject]@{ StatusCode = 409; Content = '{"message":"Unexpected service state"}' }
        } -ParameterFilter { [string]$Uri -like '*/commits/main' }
        { Save-AvmCatalogTerraformSource -Repository $script:sourceRepository -Destination $root -Confirm:$false } | Should -Throw '*not a confirmed empty repository*'
    }
}
