BeforeAll {
    $script:repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot ".." ".." ".." ".."
    )).Path
    $script:discoveryScript = Join-Path $script:repoRoot (
        "repository-management/repository-sync/actions/avm-repos/scripts/" +
        "Get-RepositoriesWhereAppInstalled.ps1"
    )

    $script:discoveryManifest = Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
    $script:discoveryModule = Import-Module $script:discoveryManifest -Force -PassThru
    $script:schemaId = (Get-Content (Join-Path $script:discoveryModule.ModuleBase 'Resources' 'Schemas' 'v1' 'avm-module-metadata.schema.json') -Raw |
            ConvertFrom-Json).'$id'

    function New-TestRepository {
        param(
            [Parameter(Mandatory)]
            [string]$Name
        )

        [pscustomobject]@{
            name      = $Name
            full_name = "Azure/$Name"
            html_url  = "https://github.com/Azure/$Name"
            archived  = $false
            default_branch = 'main'
        }
    }

    function New-DiscoveryMetadata {
        @{
            '$schema' = $script:schemaId
            moduleDisplayName = 'Azure Storage'
            moduleDescription = 'Deploys a storage account.'
            canonicalType = 'Microsoft.Storage/storageAccounts'
            telemetryIdPrefix = '46d3xtrf.res.a1b2c3d'
            owners = @('first-owner', 'second-owner', 'third-owner', '@Azure/storage-owners')
        }
    }

    function ConvertTo-DiscoveryFile {
        param([string] $Json)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $header = [System.Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)$([char]0)")
        @{
            type = 'file'
            path = 'metadata.json'
            encoding = 'base64'
            size = $bytes.Length
            content = [System.Convert]::ToBase64String($bytes)
            sha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA1]::HashData([byte[]]($header + $bytes))).ToLowerInvariant()
        }
    }

    function Invoke-RepositoryDiscovery {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [array]$InstalledRepositories,

            [hashtable]$Parameters = @{}
        )

        $script:discoveryState.Installation = @{
            repositories = @($InstalledRepositories)
            total_count  = @($InstalledRepositories).Count
        }

        & $script:discoveryScript `
            -outputDirectory $TestDrive `
            @Parameters
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe "Repository discovery built-in exclusions" {
    BeforeEach {
        $script:discoveryState = @{
            Installation = $null
            Pages = @{}
            Metadata = @{
                'Azure/terraform-azurerm-avm-res-normal' = (New-DiscoveryMetadata | ConvertTo-Json -Depth 10)
                'Azure/terraform-azurerm-avm-res-custom' = (New-DiscoveryMetadata | ConvertTo-Json -Depth 10)
            }
            FileOverrides = @{}
            Failures = @{}
            Requests = [System.Collections.Generic.List[string]]::new()
        }
        $fixtureModule = $script:discoveryModule
        $fixture = $script:discoveryState
        $encodeFile = ${function:ConvertTo-DiscoveryFile}
        Mock Import-Module -MockWith ({ $fixtureModule }.GetNewClosure()) -ParameterFilter { $Name -like '*Avm.Authoring.psd1' }
        Mock Get-Command { [pscustomobject]@{ Source = 'fixture-gh' } } -ParameterFilter { $Name -eq 'gh' }
        Mock Invoke-AvmProcess -ModuleName Avm.Authoring -MockWith ({
            param($FilePath, $ArgumentList)
            if ($FilePath -cne 'fixture-gh' -or $ArgumentList[0] -cne 'api' -or $ArgumentList -notcontains 'GET') {
                throw "Unexpected discovery command: $FilePath $ArgumentList"
            }
            $endpoint = $ArgumentList[-1]
            $fixture.Requests.Add($endpoint)
            if ($fixture.Failures.ContainsKey($endpoint)) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $fixture.Failures[$endpoint] }
            }
            if ($endpoint.StartsWith('/installation/repositories?')) {
                $page = $endpoint.Split('=')[-1]
                $data = if ($fixture.Pages.ContainsKey($page)) { $fixture.Pages[$page] } else { $fixture.Installation }
                return [pscustomobject]@{ ExitCode = 0; StdOut = ($data | ConvertTo-Json -Depth 10); StdErr = '' }
            }
            $fileMatch = [regex]::Match($endpoint, '^repos/(.+)/contents/metadata\.json\?ref=.+$')
            if (-not $fileMatch.Success) { throw "Unexpected API endpoint: $endpoint" }
            $repository = $fileMatch.Groups[1].Value
            if (-not $fixture.Metadata.ContainsKey($repository)) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'gh: Not Found (HTTP 404)' }
            }
            $file = & $encodeFile -Json $fixture.Metadata[$repository]
            if ($fixture.FileOverrides.ContainsKey($repository)) {
                foreach ($key in $fixture.FileOverrides[$repository].Keys) {
                    $file[$key] = $fixture.FileOverrides[$repository][$key]
                }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = ($file | ConvertTo-Json -Depth 10); StdErr = '' }
        }.GetNewClosure())
        Mock Import-Csv { throw 'Repository discovery must not read CSV.' }
        Mock ConvertFrom-Csv { throw 'Repository discovery must not read CSV.' }
        Remove-Item (Join-Path $TestDrive "issues.log.json") -ErrorAction SilentlyContinue
    }

    It "applies built-in exclusions when no additional parameter is supplied" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "terraform-azurerm-avm-template")
                (New-TestRepository -Name "avm-terraform-governance")
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            )
        )

        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
    }

    It "applies built-in exclusions when the additional parameter is explicitly empty" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "terraform-azurerm-avm-template")
                (New-TestRepository -Name "avm-terraform-governance")
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            ) -Parameters @{
                additionalReposToSkip = @()
            }
        )

        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
    }

    It "adds caller-supplied exclusions to the built-in exclusions" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "terraform-azurerm-avm-template")
                (New-TestRepository -Name "avm-terraform-governance")
                (New-TestRepository -Name "terraform-azurerm-avm-res-custom")
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            ) -Parameters @{
                additionalReposToSkip = @("terraform-azurerm-avm-res-custom")
            }
        )

        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
    }

    It "matches built-in exclusions case-insensitively" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "TERRAFORM-AZURERM-AVM-TEMPLATE")
                (New-TestRepository -Name "AVM-TERRAFORM-GOVERNANCE")
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            )
        )

        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
    }

    It "includes a normal repository" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            )
        )

        $repositories | Should -HaveCount 1
        $repositories[0].repoId | Should -Be "avm-res-normal"
        $repositories[0].repoName | Should -Be "terraform-azurerm-avm-res-normal"
        $repositories[0].repoMetaData.moduleDisplayName | Should -BeExactly 'Azure Storage'
        @($repositories[0].repoMetaData.owners) | Should -Be @('first-owner', 'second-owner', 'third-owner', '@Azure/storage-owners')
        $repositories[0].repoMetaData.Contains('isArchived') | Should -BeFalse
        Should -Invoke Import-Csv -Times 0 -Exactly
        Should -Invoke ConvertFrom-Csv -Times 0 -Exactly
    }

    It "skips tooling repositories before validation without warning or issue artifacts" -ForEach @(
        @{ ToolingName = "policy-library-avm" }
        @{ ToolingName = "mapotf" }
        @{ ToolingName = "azure-verified-modules-tools" }
        @{ ToolingName = "POLICY-LIBRARY-AVM" }
        @{ ToolingName = "MAPOTF" }
        @{ ToolingName = "AZURE-VERIFIED-MODULES-TOOLS" }
    ) {
        $result = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name $ToolingName)
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            ) 3>&1
        )
        $warningRecords = @($result | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $repositories = @($result | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })

        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
        $warningRecords | Should -BeNullOrEmpty
        Test-Path (Join-Path $TestDrive "issues.log.json") | Should -BeFalse
    }

    It "still reports an unexpected non-module repository" {
        $repositories = @(
            Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name "unexpected-repository")
                (New-TestRepository -Name "terraform-azurerm-avm-res-normal")
            )
        )
        $repositories.repoName | Should -Be @("terraform-azurerm-avm-res-normal")
        $issues = @(Get-Content -Raw (Join-Path $TestDrive "issues.log.json") | ConvertFrom-Json)
        $issues.Count | Should -Be 1
        $issues[0].repoId | Should -Be "unexpected-repository"
        $issues[0].severity | Should -Be "error"
        $issues[0].message | Should -BeLike "*does not match the required naming convention*"
    }

    It 'skips archived repositories using GitHub state without requesting metadata' {
        $archived = New-TestRepository -Name 'terraform-azurerm-avm-res-archived'
        $archived.archived = $true
        $repositories = @(Invoke-RepositoryDiscovery -InstalledRepositories @($archived))
        $repositories | Should -HaveCount 0
        $script:discoveryState.Requests | Should -HaveCount 1
        Test-Path (Join-Path $TestDrive 'issues.log.json') | Should -BeFalse
    }

    It 'filters before metadata lookups and encodes the actual default branch' {
        $selected = New-TestRepository -Name 'terraform-azurerm-avm-res-normal'
        $selected.default_branch = 'release/current'
        $repositories = @(Invoke-RepositoryDiscovery -InstalledRepositories @(
                $selected
                (New-TestRepository -Name 'terraform-azurerm-avm-res-custom')
            ) -Parameters @{ repoFilter = @('avm-res-normal') })
        $repositories | Should -HaveCount 1
        $script:discoveryState.Requests | Should -Be @(
            '/installation/repositories?per_page=100&page=1'
            'repos/Azure/terraform-azurerm-avm-res-normal/contents/metadata.json?ref=release%2Fcurrent'
        )
    }

    It 'warns on missing metadata while retaining the repository for remaining rollout work' {
        $repositories = @(Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name 'terraform-azurerm-avm-res-missing')
            ))
        $repositories | Should -HaveCount 1
        $repositories[0].repoMetaData | Should -BeNullOrEmpty
        $issues = @(Get-Content (Join-Path $TestDrive 'issues.log.json') -Raw | ConvertFrom-Json)
        $issues | Should -HaveCount 1
        $issues[0].severity | Should -BeExactly 'warning'
        $issues[0].message | Should -BeLike '*direct collaborator cleanup will be skipped*'
    }

    It 'excludes repositories with unreadable metadata rather than treating <Failure> as a missing file' -TestCases @(
        @{ Failure = 'gh: Forbidden (HTTP 403)' }
        @{ Failure = 'gh: rate limited (HTTP 429)' }
        @{ Failure = 'gh: server error (HTTP 500)' }
        @{ Failure = 'connection failed' }
    ) {
        param($Failure)
        $script:discoveryState.Failures['repos/Azure/terraform-azurerm-avm-res-normal/contents/metadata.json?ref=main'] = $Failure
        $repositories = @(Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name 'terraform-azurerm-avm-res-normal')
            ))
        $repositories | Should -HaveCount 0
        $issues = @(Get-Content (Join-Path $TestDrive 'issues.log.json') -Raw | ConvertFrom-Json)
        $issues[0].severity | Should -BeExactly 'error'
        $issues[0].message | Should -BeLike "*$Failure*"
    }

    It 'rejects invalid metadata: <Case>' -TestCases @(
        @{ Case = 'invalid JSON'; Json = '{' }
        @{ Case = 'missing root fields'; Json = '{"moduleDisplayName":"not enough"}' }
        @{ Case = 'duplicate JSON keys'; Json = '{"owners":[],"owners":["owner"]}' }
        @{ Case = 'non-object root'; Json = '[]' }
    ) {
        param($Case, $Json)
        $script:discoveryState.Metadata['Azure/terraform-azurerm-avm-res-normal'] = $Json
        $repositories = @(Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name 'terraform-azurerm-avm-res-normal')
            ))
        $repositories | Should -HaveCount 0
        $issues = @(Get-Content (Join-Path $TestDrive 'issues.log.json') -Raw | ConvertFrom-Json)
        $issues[0].severity | Should -BeExactly 'error'
        $issues[0].message | Should -BeLike '*Invalid *metadata.json*'
    }

    It 'validates full metadata semantics: <Field>' -TestCases @(
        @{ Field = 'canonicalType'; Value = 'networking/hub' }
        @{ Field = 'owners'; Value = @('same-owner', 'SAME-OWNER') }
        @{ Field = 'telemetryIdPrefix'; Value = '46d3xbcp.res.storage-account' }
        @{ Field = 'isArchived'; Value = $false }
    ) {
        param($Field, $Value)
        $metadata = New-DiscoveryMetadata
        $metadata[$Field] = $Value
        $script:discoveryState.Metadata['Azure/terraform-azurerm-avm-res-normal'] = $metadata | ConvertTo-Json -Depth 10
        @(Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name 'terraform-azurerm-avm-res-normal')
            )) | Should -HaveCount 0
        $issues = @(Get-Content (Join-Path $TestDrive 'issues.log.json') -Raw | ConvertFrom-Json)
        $issues[0].severity | Should -BeExactly 'error'
    }

    It 'accepts telemetry-free utility roots and empty ownership' {
        $metadata = New-DiscoveryMetadata
        $metadata.canonicalType = 'naming'
        $metadata.owners = @()
        $metadata.Remove('telemetryIdPrefix')
        $script:discoveryState.Metadata['Azure/terraform-azure-avm-utl-naming'] = $metadata | ConvertTo-Json -Depth 10
        $repositories = @(Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name 'terraform-azure-avm-utl-naming')
            ))
        $repositories | Should -HaveCount 1
        $repositories[0].repoSubType | Should -BeExactly 'utility'
        $repositories[0].repoMetaData.owners | Should -HaveCount 0
        Test-Path (Join-Path $TestDrive 'issues.log.json') | Should -BeFalse
    }

    It 'rejects an incomplete or substituted GitHub file: <Field>' -TestCases @(
        @{ Field = 'type'; Value = 'dir' }
        @{ Field = 'path'; Value = 'Metadata.json' }
        @{ Field = 'encoding'; Value = 'none' }
        @{ Field = 'size'; Value = 0 }
        @{ Field = 'sha'; Value = ('0' * 40) }
    ) {
        param($Field, $Value)
        $script:discoveryState.FileOverrides['Azure/terraform-azurerm-avm-res-normal'] = @{ $Field = $Value }
        @(Invoke-RepositoryDiscovery -InstalledRepositories @(
                (New-TestRepository -Name 'terraform-azurerm-avm-res-normal')
            )) | Should -HaveCount 0
        $issues = @(Get-Content (Join-Path $TestDrive 'issues.log.json') -Raw | ConvertFrom-Json)
        $issues[0].severity | Should -BeExactly 'error'
    }

    It 'reads every installation page and returns a stable repository order' {
        $script:discoveryState.Pages['1'] = @{
            repositories = @((New-TestRepository -Name 'terraform-azurerm-avm-res-normal'))
            total_count = 101
        }
        $script:discoveryState.Pages['2'] = @{
            repositories = @((New-TestRepository -Name 'terraform-azurerm-avm-res-custom'))
            total_count = 101
        }
        $repositories = @(Invoke-RepositoryDiscovery -InstalledRepositories @())
        @($repositories.repoId) | Should -Be @('avm-res-custom', 'avm-res-normal')
        $script:discoveryState.Requests | Should -Contain '/installation/repositories?per_page=100&page=2'
    }

    It 'stops on installation lookup failure before returning any repository' {
        $script:discoveryState.Failures['/installation/repositories?per_page=100&page=1'] = 'gh: authentication failed (HTTP 401)'
        { Invoke-RepositoryDiscovery -InstalledRepositories @() } | Should -Throw "*Cannot list the app's repositories*"
        $script:discoveryState.Requests | Should -HaveCount 1
    }
}
