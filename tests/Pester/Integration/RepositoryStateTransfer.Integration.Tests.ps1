BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:inspector = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Test-RepositoryStateTransfer.ps1'
    . (Join-Path $script:root 'tests' 'fixtures' 'RepositoryState.ps1')
    $script:module = Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -PassThru
    $script:terraform = (Get-Command terraform -CommandType Application -ErrorAction Stop).Source
    $script:localEnvironment = @{
        GH_TOKEN = $null; GITHUB_TOKEN = $null; TF_IN_AUTOMATION = 'true'; TF_INPUT = 'false'
        TF_WORKSPACE = 'default'; TF_LOG = $null; TF_LOG_PATH = $null
        TF_LOG_CORE = $null; TF_LOG_PROVIDER = $null; CHECKPOINT_DISABLE = '1'
    }
    foreach ($name in [Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -clike 'TF_CLI_ARGS*' }) {
        $script:localEnvironment[$name] = $null
    }

    function Invoke-LocalStateTerraform {
        param([string] $Directory, [string[]] $Arguments, [switch] $FailureExpected)

        if (-not $Directory.StartsWith($TestDrive, [StringComparison]::Ordinal)) {
            throw 'The native state proof is restricted to its disposable TestDrive.'
        }
        $environment = $script:localEnvironment.Clone()
        $environment.TF_DATA_DIR = Join-Path $Directory '.terraform'
        $result = & $script:module {
            param($Executable, $Arguments, $Directory, $Environment)
            Invoke-AvmProcess -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $Directory `
                -EnvVars $Environment -TimeoutSec 60 -IgnoreExitCode
        } $script:terraform $Arguments $Directory $environment
        if ($result.ExitCode -ne 0 -and -not $FailureExpected) {
            $detail = $result.StdErr -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', ''
            throw "Local synthetic Terraform failed: $detail"
        }
        return $result
    }

    function Read-LocalStateFixture {
        param([string] $Path)
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    }

    function Test-StateFixtureEqual {
        param($Left, $Right)
        [System.Text.Json.Nodes.JsonNode]::DeepEquals(
            [System.Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject $Left -Depth 100 -Compress)),
            [System.Text.Json.Nodes.JsonNode]::Parse((ConvertTo-Json -InputObject $Right -Depth 100 -Compress))
        )
    }

    foreach ($directory in @('identity', 'github', 'retired', 'source', 'destination', 'unified')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive $directory)
    }
    @'
resource "terraform_data" "identity" {
  input = { client_id = "synthetic-repository-client", principal_id = "synthetic-repository-principal" }
  lifecycle {
    postcondition {
      condition     = self.output.client_id == "synthetic-repository-client"
      error_message = "Only the synthetic client is allowed."
    }
  }
}
resource "terraform_data" "membership" {
  for_each = toset(["readers", "owners"])
  input = { group = each.key, principal = terraform_data.identity.output.principal_id }
}
output "identity" { value = terraform_data.identity.output }
output "groups" { value = { for key, member in terraform_data.membership : key => member.output } }
'@ | Set-Content -LiteralPath (Join-Path $TestDrive 'identity' 'main.tf') -Encoding utf8NoBOM
    @'
resource "terraform_data" "repository" { input = "synthetic-github-repository" }
output "repository" { value = terraform_data.repository.output }
'@ | Set-Content -LiteralPath (Join-Path $TestDrive 'github' 'main.tf') -Encoding utf8NoBOM
    @'
resource "terraform_data" "retired" { input = "synthetic-old-tenant-object" }
resource "terraform_data" "membership" { input = terraform_data.retired.output }
'@ | Set-Content -LiteralPath (Join-Path $TestDrive 'retired' 'main.tf') -Encoding utf8NoBOM
    @'
terraform {
  backend "local" {}
}
module "azure" { source = "../identity" }
output "test_identity" { value = module.azure.identity }
output "test_group_contract" { value = module.azure.groups }
output "private_marker" {
  value     = "synthetic-preserved-sensitive-output"
  sensitive = true
}
'@ | Set-Content -LiteralPath (Join-Path $TestDrive 'source' 'main.tf') -Encoding utf8NoBOM
    @'
terraform {
  backend "local" {}
}
module "github" {
  source = "../github"
  depends_on = [module.azure]
}
module "azure" {
  source = "../retired"
  count  = 1
}
output "repository" { value = module.github.repository }
'@ | Set-Content -LiteralPath (Join-Path $TestDrive 'destination' 'main.tf') -Encoding utf8NoBOM
    @'
terraform {
  backend "local" {}
}
module "github" { source = "../github" }
module "bami" {
  source = "../identity"
  count  = 1
}
removed {
  from = module.azure
  lifecycle { destroy = false }
}
output "repository" { value = module.github.repository }
output "test_identity" { value = module.bami[0].identity }
output "test_group_contract" { value = module.bami[0].groups }
output "private_marker" {
  value     = "synthetic-preserved-sensitive-output"
  sensitive = true
}
'@ | Set-Content -LiteralPath (Join-Path $TestDrive 'unified' 'main.tf') -Encoding utf8NoBOM
    foreach ($directory in @('source', 'destination', 'unified')) {
        $path = Join-Path $TestDrive $directory
        $null = Invoke-LocalStateTerraform -Directory $path -Arguments @('init', '-input=false', '-no-color')
        if ($directory -cne 'unified') {
            $null = Invoke-LocalStateTerraform -Directory $path -Arguments @('apply', '-auto-approve', '-input=false', '-no-color')
        }
    }
    $script:sourceOriginal = Join-Path $TestDrive 'source' 'terraform.tfstate'
    $script:destinationOriginal = Join-Path $TestDrive 'destination' 'terraform.tfstate'
    $script:sourceHash = (Get-FileHash -LiteralPath $script:sourceOriginal).Hash
    $script:destinationHash = (Get-FileHash -LiteralPath $script:destinationOriginal).Hash
}

Describe 'Integration: local repository state consolidation' -Tag Integration {
    BeforeEach {
        $script:working = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:working
        $script:source = Join-Path $script:working 'source.tfstate'
        $script:destination = Join-Path $script:working 'destination.tfstate'
        Copy-Item -LiteralPath $script:sourceOriginal -Destination $script:source
        Copy-Item -LiteralPath $script:destinationOriginal -Destination $script:destination
        $script:move = @(
            'state', 'mv', "-state=$script:source", "-state-out=$script:destination",
            "-backup=$(Join-Path $script:working 'source.backup')",
            "-backup-out=$(Join-Path $script:working 'destination.backup')",
            'module.azure', 'module.bami[0]'
        )
    }

    AfterEach {
        (Get-FileHash -LiteralPath $script:sourceOriginal).Hash | Should -Be $script:sourceHash
        (Get-FileHash -LiteralPath $script:destinationOriginal).Hash | Should -Be $script:destinationHash
    }

    It 'moves the whole module without changing resource identities, lineages, or original outputs' {
        $beforeSource = Read-LocalStateFixture $script:source
        $beforeDestination = Read-LocalStateFixture $script:destination
        $null = Invoke-LocalStateTerraform -Directory $script:working -Arguments $script:move
        $afterSource = Read-LocalStateFixture $script:source
        $afterDestination = Read-LocalStateFixture $script:destination
        $afterSource.resources | Should -HaveCount 0
        $afterSource.lineage | Should -Be $beforeSource.lineage
        $afterDestination.lineage | Should -Be $beforeDestination.lineage
        $afterSource.serial | Should -Be ($beforeSource.serial + 1)
        $afterDestination.serial | Should -Be ($beforeDestination.serial + 1)
        Test-StateFixtureEqual $afterSource.check_results $beforeSource.check_results | Should -BeTrue
        Test-StateFixtureEqual $afterDestination.check_results $beforeDestination.check_results | Should -BeTrue
        Test-StateFixtureEqual $afterSource.outputs $beforeSource.outputs | Should -BeTrue
        Test-StateFixtureEqual $afterDestination.outputs $beforeDestination.outputs | Should -BeTrue
        $afterDestination.outputs.Contains('test_identity') | Should -BeFalse
        foreach ($resource in $beforeSource.resources) {
            $moved = @($afterDestination.resources | Where-Object {
                $_.module -ceq 'module.bami[0]' -and $_.type -ceq $resource.type -and $_.name -ceq $resource.name
            })
            $moved | Should -HaveCount 1
            $moved[0].provider | Should -Be $resource.provider
            foreach ($instance in $resource.instances) {
                $null = $instance.Remove('dependencies')
            }
            Test-StateFixtureEqual $moved[0].instances $resource.instances | Should -BeTrue
        }
        foreach ($resource in $beforeDestination.resources) {
            $retained = @($afterDestination.resources | Where-Object { $_.module -ceq $resource.module -and $_.name -ceq $resource.name })
            foreach ($instance in $resource.instances) {
                if (@($instance['dependencies'] | Where-Object { $_ -cmatch '^module\.azure(?:$|\.|\[)' }).Count -gt 0) {
                    $null = $instance.Remove('dependencies')
                }
            }
            Test-StateFixtureEqual $retained[0] $resource | Should -BeTrue
        }
        Copy-Item -LiteralPath $script:destination -Destination (Join-Path $TestDrive 'unified' 'terraform.tfstate')
        $null = Invoke-LocalStateTerraform -Directory (Join-Path $TestDrive 'unified') -Arguments @(
            'plan', '-refresh=false', '-input=false', '-no-color', '-out=synthetic.tfplan'
        )
        $result = Invoke-LocalStateTerraform -Directory (Join-Path $TestDrive 'unified') -Arguments @('show', '-json', 'synthetic.tfplan')
        $plan = $result.StdOut | ConvertFrom-Json -AsHashtable -Depth 100
        @($plan.resource_changes | Where-Object { $_.change.actions -contains 'create' -or $_.change.actions -contains 'delete' }) | Should -HaveCount 0
        @($plan.resource_changes | Where-Object { $_.change.actions -contains 'forget' }) | Should -HaveCount 2
        Test-StateFixtureEqual $plan.output_changes.test_identity.after $beforeSource.outputs.test_identity.value | Should -BeTrue
        Test-StateFixtureEqual $plan.output_changes.test_group_contract.after $beforeSource.outputs.test_group_contract.value | Should -BeTrue
        $plan.output_changes.private_marker.after_sensitive | Should -BeTrue
        $null = Invoke-LocalStateTerraform -Directory (Join-Path $TestDrive 'unified') -Arguments @(
            'apply', '-input=false', '-no-color', 'synthetic.tfplan'
        )
        $unified = Read-LocalStateFixture (Join-Path $TestDrive 'unified' 'terraform.tfstate')
        $members = @($unified.resources | Where-Object { $_.module -ceq 'module.bami[0]' -and $_.name -ceq 'membership' })
        foreach ($instance in $members[0].instances) {
            $instance.dependencies | Should -Contain 'module.bami.terraform_data.identity'
        }
    }

    It 'rejects an occupied destination namespace without changing either staged file' {
        $null = Invoke-LocalStateTerraform -Directory $script:working -Arguments $script:move
        Copy-Item -LiteralPath $script:sourceOriginal -Destination $script:source
        $sourceHash = (Get-FileHash -LiteralPath $script:source).Hash
        $destinationHash = (Get-FileHash -LiteralPath $script:destination).Hash
        $result = Invoke-LocalStateTerraform -Directory $script:working -Arguments $script:move -FailureExpected
        $result.ExitCode | Should -Not -Be 0
        (Get-FileHash -LiteralPath $script:source).Hash | Should -Be $sourceHash
        (Get-FileHash -LiteralPath $script:destination).Hash | Should -Be $destinationHash
    }

    It 'resumes a source-first cutover using native local pushes without force or duplicate ownership' {
        $null = Invoke-LocalStateTerraform -Directory $script:working -Arguments $script:move
        $backends = @{}
        foreach ($name in @('source', 'destination')) {
            $directory = Join-Path $script:working "$name-backend"
            $null = New-Item -ItemType Directory -Path $directory
            @'
terraform {
  backend "local" {}
}
'@ | Set-Content -LiteralPath (Join-Path $directory 'main.tf') -Encoding utf8NoBOM
            $null = Invoke-LocalStateTerraform -Directory $directory -Arguments @('init', '-input=false', '-no-color')
            $original = $name -ceq 'source' ? $script:sourceOriginal : $script:destinationOriginal
            Copy-Item -LiteralPath $original -Destination (Join-Path $directory 'terraform.tfstate')
            $backends[$name] = $directory
        }
        $null = Invoke-LocalStateTerraform -Directory $backends.source -Arguments @('state', 'push', $script:source)
        $sourceResult = Invoke-LocalStateTerraform -Directory $backends.source -Arguments @('state', 'pull')
        $sourceState = $sourceResult.StdOut | ConvertFrom-Json -AsHashtable -Depth 100
        $expectedSource = Read-LocalStateFixture $script:source
        $sourceState.serial | Should -Be ($expectedSource.serial + 1)
        $expectedSource.serial++
        Test-StateFixtureEqual $sourceState $expectedSource | Should -BeTrue
        $sourceState.resources | Should -HaveCount 0
        $destinationResult = Invoke-LocalStateTerraform -Directory $backends.destination -Arguments @('state', 'pull')
        Test-StateFixtureEqual ($destinationResult.StdOut | ConvertFrom-Json -AsHashtable -Depth 100) `
            (Read-LocalStateFixture $script:destinationOriginal) | Should -BeTrue

        $stale = Invoke-LocalStateTerraform -Directory $backends.source -Arguments @('state', 'push', $script:sourceOriginal) -FailureExpected
        $stale.ExitCode | Should -Not -Be 0
        $foreign = Invoke-LocalStateTerraform -Directory $backends.source -Arguments @('state', 'push', $script:destinationOriginal) -FailureExpected
        $foreign.ExitCode | Should -Not -Be 0

        $null = Invoke-LocalStateTerraform -Directory $backends.destination -Arguments @('state', 'push', $script:destination)
        $completed = Invoke-LocalStateTerraform -Directory $backends.destination -Arguments @('state', 'pull')
        $expectedDestination = Read-LocalStateFixture $script:destination
        $expectedDestination.serial++
        Test-StateFixtureEqual ($completed.StdOut | ConvertFrom-Json -AsHashtable -Depth 100) $expectedDestination | Should -BeTrue
        $sourceResult = Invoke-LocalStateTerraform -Directory $backends.source -Arguments @('state', 'pull')
        ($sourceResult.StdOut | ConvertFrom-Json -AsHashtable -Depth 100).resources | Should -HaveCount 0
    }

    It 'preserves opaque Azure provider attributes and private data in a native namespace move' {
        $pair = New-AvmTestRepositoryStatePair
        ConvertTo-Json -InputObject $pair.Source -Depth 100 | Set-Content -LiteralPath $script:source -Encoding utf8NoBOM
        ConvertTo-Json -InputObject $pair.Destination -Depth 100 | Set-Content -LiteralPath $script:destination -Encoding utf8NoBOM
        $sourceBefore = Join-Path $script:working 'source-original.tfstate'
        $destinationBefore = Join-Path $script:working 'destination-original.tfstate'
        Copy-Item -LiteralPath $script:source -Destination $sourceBefore
        Copy-Item -LiteralPath $script:destination -Destination $destinationBefore
        $sourceHash = (Get-FileHash -LiteralPath $sourceBefore).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destinationBefore).Hash
        $null = Invoke-LocalStateTerraform -Directory $script:working -Arguments $script:move
        $result = & $script:inspector -SourceBefore $sourceBefore -DestinationBefore $destinationBefore `
            -SourceAfter $script:source -DestinationAfter $script:destination `
            -SourceSha256 $sourceHash -DestinationSha256 $destinationHash -Repository $pair.Repository -Identity $pair.Identity
        @($result) | Should -HaveCount 1
        $result.ResourceBlocks | Should -Be 6
        $result.SourceAfterSha256 | Should -Be (Get-FileHash -LiteralPath $script:source).Hash
        $result.DestinationAfterSha256 | Should -Be (Get-FileHash -LiteralPath $script:destination).Hash
        (Get-FileHash -LiteralPath $sourceBefore).Hash | Should -Be $sourceHash
        (Get-FileHash -LiteralPath $destinationBefore).Hash | Should -Be $destinationHash
    }
}
