BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:lib = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib'
    . (Join-Path $script:root 'tests' 'fixtures' 'RepositoryState.ps1')
    . (Join-Path $script:lib 'TestTenant.ps1')
    . (Join-Path $script:lib 'Logging.ps1')
    . (Join-Path $script:lib 'StateMigration.ps1')
    . (Join-Path $script:lib 'StateMigrationStorage.ps1')
    $script:module = Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force -PassThru
    $script:tool = & $script:module { Resolve-AvmTool -Name terraform }
    $script:nativeTerraform = (Get-Command Invoke-RepositoryMigrationTerraform).ScriptBlock

    $script:nativeIdentityDefinition = @'
variable "client_id" {
  default = "synthetic-client"
  validation {
    condition     = length(var.client_id) > 0
    error_message = "A client is required."
  }
}
variable "principal_id" {
  default = "synthetic-principal"
  validation {
    condition     = length(var.principal_id) > 0
    error_message = "A principal is required."
  }
}
resource "terraform_data" "identity" {
  input = { client_id = var.client_id, principal_id = var.principal_id }
  lifecycle {
    postcondition {
      condition     = self.output.client_id == var.client_id
      error_message = "The client must be preserved."
    }
  }
}
resource "terraform_data" "membership" {
  for_each = toset(["readers", "owners"])
  input = { group = each.key, principal = terraform_data.identity.output.principal_id }
}
check "identity" {
  assert {
    condition     = terraform_data.identity.output.principal_id == var.principal_id
    error_message = "The principal must be preserved."
  }
}
output "identity" {
  value = terraform_data.identity.output
  precondition {
    condition     = terraform_data.identity.output.client_id == var.client_id
    error_message = "The output must identify the client."
  }
}
output "groups" { value = { for key, member in terraform_data.membership : key => member.output } }
'@
    $script:nativeGitHubDefinition = @'
variable "repository" {
  default = "synthetic-repository"
  validation {
    condition     = length(var.repository) > 0
    error_message = "A repository is required."
  }
}
resource "terraform_data" "repository" {
  input = var.repository
  lifecycle {
    postcondition {
      condition     = self.output == var.repository
      error_message = "The repository must be preserved."
    }
  }
}
check "repository" {
  assert {
    condition     = terraform_data.repository.output == var.repository
    error_message = "The repository must be preserved."
  }
}
output "repository" {
  value = terraform_data.repository.output
  precondition {
    condition     = terraform_data.repository.output == var.repository
    error_message = "The output must identify the repository."
  }
}
'@
    $generated = Join-Path $TestDrive 'generated-checks'
    foreach ($name in @('identity', 'github', 'source', 'destination')) {
        $null = [IO.Directory]::CreateDirectory((Join-Path $generated $name))
    }
    [IO.File]::WriteAllText((Join-Path $generated 'identity' 'main.tf'), $script:nativeIdentityDefinition)
    [IO.File]::WriteAllText((Join-Path $generated 'github' 'main.tf'), $script:nativeGitHubDefinition)
    $script:generatedChecks = @{}
    foreach ($side in @('source', 'destination')) {
        $directory = Join-Path $generated $side
        $definition = $side -ceq 'source' ? 'module "azure" { source = "../identity" }' : 'module "github" { source = "../github" }'
        [IO.File]::WriteAllText((Join-Path $directory 'main.tf'), $definition)
        $null = Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root $directory `
            -Arguments @('init', '-input=false', '-no-color') -PrivateOutput
        $null = Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root $directory `
            -Arguments @('apply', '-input=false', '-auto-approve', '-no-color') -PrivateOutput
        $script:generatedChecks[$side] = (Read-TransferImage (Join-Path $directory 'terraform.tfstate')).State.check_results
    }

    function Get-TestMigrationBlobPath {
        param([string] $Name)
        foreach ($part in $Name.Split('/')) {
            if ($part -in @('', '.', '..')) { throw 'Unsafe synthetic blob name.' }
        }
        $keyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Name)))
        return Join-Path $script:store "$keyHash.blob"
    }

    function Write-TestMigrationState {
        param([string] $Name, [object] $State)
        $path = Get-TestMigrationBlobPath $Name
        $null = [IO.Directory]::CreateDirectory((Split-Path $path))
        [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $State -Depth 100), [Text.UTF8Encoding]::new($false))
    }

    function New-TestMigrationTransfer {
        $transfer = New-RepositoryMigrationTransfer -Scope $script:scope -Directory (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) `
            -Terraform $script:tool.Path -TerraformVersion $script:tool.Version
        $transfer['BackendDirectory'] = Join-Path $script:store 'backends'
        return $transfer
    }
}

Describe 'Integration: automatic repository state migration' -Tag Integration {
    BeforeEach {
        $script:store = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:pair = New-AvmTestMigrationStatePair
        foreach ($stateSide in @('Source', 'Destination')) {
            $script:pair[$stateSide].check_results = ConvertFrom-TransferJson (
                ConvertTo-Json -InputObject $script:generatedChecks[$stateSide] -Depth 100
            )
            $script:pair[$stateSide].terraform_version = $script:tool.Version
        }
        $script:scope = Get-RepositoryMigrationScope -Backend $script:pair.Backend -Settings $script:pair.Settings `
            -RepoId 'avm-ptn-example-repo' -Repository $script:pair.GitHubRepository -RepositorySyncRepositoryId '5678'
        Write-TestMigrationState -Name $script:scope.SourceKey -State $script:pair.Source
        Write-TestMigrationState -Name $script:scope.DestinationKey -State $script:pair.Destination
        $script:events = [Collections.Generic.List[string]]::new()
        $script:interruptAfter = ''
        $script:completionFailure = $false
        Mock Assert-RepositoryMigrationWriters { $script:events.Add('writers') }
        Mock Assert-RepositoryMigrationContext { }
        Mock Invoke-RepositoryMigrationAzure { throw 'Real Azure transport is forbidden in native local tests.' }
        Mock Invoke-RepositoryGitHubApi { throw 'Real GitHub transport is forbidden in native local tests.' }
        Mock Get-RepositoryMigrationBlob {
            param($Backend, $Name, $Path)
            $source = Get-TestMigrationBlobPath $Name
            if (-not (Test-Path -LiteralPath $source)) { return $false }
            Copy-Item -LiteralPath $source -Destination $Path -Force
            return $true
        }
        Mock Save-RepositoryMigrationBlob {
            param($Backend, $Name, $Path)
            if ($script:completionFailure -and $Name.EndsWith('/complete.json')) { throw 'Synthetic completion upload interruption.' }
            $destination = Get-TestMigrationBlobPath $Name
            if (Test-Path -LiteralPath $destination) {
                if ((Get-FileHash $Path).Hash -cne (Get-FileHash $destination).Hash) { throw 'Synthetic create-only conflict.' }
                return
            }
            $null = [IO.Directory]::CreateDirectory((Split-Path $destination))
            $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $inputFile = [IO.File]::OpenRead($Path)
            try { $inputFile.CopyTo($output) }
            finally { $inputFile.Dispose(); $output.Dispose() }
            $script:events.Add($Name.EndsWith('/backup.zip') ? 'backup' : 'complete')
        }
        Mock Initialize-RepositoryMigrationBackend {
            param($Backend, $Key, $Root, $Terraform)
            $null = [IO.Directory]::CreateDirectory($Root)
            $path = ConvertTo-Json -InputObject (Get-TestMigrationBlobPath $Key) -Compress
            [IO.File]::WriteAllText((Join-Path $Root 'main.tf'), "terraform {`n  backend `"local`" {`n    path = $path`n  }`n}`n")
            Invoke-RepositoryMigrationTerraform -Terraform $Terraform -Root $Root -Arguments @('init', '-input=false', '-no-color', '-reconfigure', '-upgrade')
        }
        Mock Invoke-RepositoryMigrationTerraform {
            param($Terraform, $Root, $Arguments, $PrivateOutput)
            if (-not $Root.StartsWith($TestDrive, [StringComparison]::Ordinal)) { throw 'Native commands are restricted to TestDrive.' }
            if ($Arguments -contains '-force' -or $Arguments -contains '-lock=false') { throw 'Unsafe native state command.' }
            $side = if ($Arguments[0] -ceq 'state' -and $Arguments[1] -ceq 'push') {
                (Split-Path $Root -Leaf).Replace('-backend', '')
            } else { '' }
            & $script:nativeTerraform -Terraform $Terraform -Root $Root -Arguments $Arguments -PrivateOutput:$PrivateOutput
            if ($side) {
                $script:events.Add("push:$side")
                if ($script:interruptAfter -ceq $side) { throw "Synthetic response lost after $side push." }
            }
        }
    }

    It 'publishes validated whole-module ownership with untouched backups and native locks' {
        foreach ($side in @('Source', 'Destination')) {
            foreach ($kind in @('var', 'resource', 'check', 'output')) {
                $script:pair[$side].check_results.object_kind | Should -Contain $kind
            }
        }
        $transfer = New-TestMigrationTransfer
        $transfer.Position | Should -Be 'Prepared'
        foreach ($stateSide in @('source', 'destination')) {
            $before = $transfer.Images["$stateSide-before"].State.check_results
            $after = $transfer.Images["$stateSide-after"].State.check_results
            Write-Information "Terraform $($script:tool.Version) $stateSide check kinds: $($before.object_kind -join ', ') -> $($after.object_kind -join ', ')." -InformationAction Continue
        }
        Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false | Should -Be 'Complete'
        ($script:events | Where-Object { $_ -cne 'writers' }) | Should -Be @('backup', 'push:source', 'push:destination', 'complete')
        $position = Get-RepositoryMigrationPosition $transfer
        $position.Status | Should -Be 'Complete'
        $position.Current.source.State.resources | Should -HaveCount 0
        Test-TransferValueEqual $position.Current.source.State.outputs $script:pair.Source.outputs | Should -BeTrue
        Test-TransferValueEqual $position.Current.destination.State.outputs $script:pair.Destination.outputs | Should -BeTrue
        $position.Current.source.State.lineage | Should -Be $script:pair.Source.lineage
        $position.Current.destination.State.lineage | Should -Be $script:pair.Destination.lineage
        Assert-RepositoryMigrationOwnership -Scope $script:scope -State $position.Current.destination.State `
            -Identity $script:pair.Identity -Module 'module.bami[0]' -Destination
        $recovered = New-TestMigrationTransfer
        $recovered.Images['source-before'].Hash | Should -Be $transfer.Images['source-before'].Hash
        $recovered.Images['destination-before'].Hash | Should -Be $transfer.Images['destination-before'].Hash
        $recovered.BackupHash | Should -Be $transfer.BackupHash
        Invoke-RepositoryMigrationTransfer -Transfer $recovered -Confirm:$false | Should -Be 'Complete'
        @($script:events | Where-Object { $_ -like 'push:*' }) | Should -HaveCount 2
    }

    It 'stages plan-only without backup uploads, backend initialization, or state writes' {
        $transfer = New-TestMigrationTransfer
        Invoke-RepositoryMigrationTransfer -Transfer $transfer -PlanOnly | Should -Be 'Preview'
        Should -Invoke Save-RepositoryMigrationBlob -Times 0 -Exactly
        Should -Invoke Initialize-RepositoryMigrationBackend -Times 0 -Exactly
        (Get-RepositoryMigrationPosition $transfer).Status | Should -Be 'Prepared'
    }

    It 'runs native publication and a completed rerun without modifying historical repository states' {
        $script:aliasPair = New-AvmTestLegacyAliasStatePair
        $flatStates = @{
            'avm-template.tfstate' = New-AvmTestHistoricalRepositoryState -Repository 'Azure/terraform-azurerm-avm-template' -RepositoryId 2345
            'avm-gh-app.tfstate' = New-AvmTestHistoricalRepositoryState -Repository 'Azure/avm-gh-app' -RepositoryId 3456
            'avm-container-images-cicd-agents-and-runners.tfstate' = New-AvmTestHistoricalRepositoryState -Repository 'Azure/avm-container-images-cicd-agents-and-runners' -RepositoryId 4567
        }
        $script:historicalStates = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($key in $flatStates.Keys) {
            $script:historicalStates.Add($key, $flatStates[$key])
        }
        $script:historicalStates.Add($script:aliasPair.CanonicalKey, $script:aliasPair.Canonical.Destination)
        $script:historicalStates.Add($script:aliasPair.LegacyKey, $script:aliasPair.Legacy)
        $historicalHashes = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        foreach ($key in $script:historicalStates.Keys) {
            Write-TestMigrationState -Name $key -State $script:historicalStates[$key]
            $historicalHashes[$key] = (Get-FileHash -LiteralPath (Get-TestMigrationBlobPath $key)).Hash
        }
        Mock Assert-RepositoryMigrationStorage { }
        Mock Resolve-AvmRepositorySyncFederationContext { @{ OrganizationId = $script:scope.RepositoryOwnerId } }
        Mock Invoke-RepositoryGitHubApi {
            param($Endpoint)
            foreach ($pair in @($script:pair, $script:aliasPair.Canonical)) {
                if ($Endpoint -ceq "repos/$($pair.Repository)") { return $pair.GitHubRepository }
            }
        } -ParameterFilter {
            $Endpoint -cin (@($script:pair, $script:aliasPair.Canonical) | ForEach-Object { "repos/$($_.Repository)" })
        }
        Mock Get-RepositoryMigrationBlobList {
            param($Backend, $Prefix)
            foreach ($key in (@(
                $script:scope.SourceKey, $script:scope.DestinationKey,
                "bami-consolidation/$($script:scope.TenantId)/$($script:scope.RepoId)/backup.zip",
                "bami-consolidation/$($script:scope.TenantId)/$($script:scope.RepoId)/complete.json"
            ) + @($script:historicalStates.Keys))) {
                if ($key.StartsWith($Prefix, [StringComparison]::Ordinal) -and
                    (Test-Path -LiteralPath (Get-TestMigrationBlobPath $key))) {
                    @{ name = $key }
                }
            }
        }
        $previous = @{}
        foreach ($name in @('TMP', 'TEMP', 'TMPDIR', 'GITHUB_OUTPUT', 'GITHUB_REPOSITORY_ID')) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        try {
            foreach ($name in @('TMP', 'TEMP', 'TMPDIR')) { [Environment]::SetEnvironmentVariable($name, $TestDrive, 'Process') }
            $env:GITHUB_OUTPUT = Join-Path $TestDrive 'native-migration-output'
            $env:GITHUB_REPOSITORY_ID = '5678'
            $driver = Join-Path $script:lib '..' 'Invoke-RepositoryStateMigration.ps1'
            # Keep transport mocks in Pester's script scope.
            $preview = . $driver -Backend $script:pair.Backend -BamiSettings $script:pair.Settings -PlanOnly -Confirm:$false
            $preview.Ready | Should -BeFalse
            $preview.MigrationRequired | Should -Be 1
            Should -Invoke Save-RepositoryMigrationBlob -Times 0 -Exactly
            Should -Invoke Initialize-RepositoryMigrationBackend -Times 0 -Exactly
            $first = . $driver -Backend $script:pair.Backend -BamiSettings $script:pair.Settings -PlanOnly:$false -Confirm:$false
            $first.Ready | Should -BeTrue
            $first.MigrationRequired | Should -Be 1
            $second = . $driver -Backend $script:pair.Backend -BamiSettings $script:pair.Settings -PlanOnly:$false -Confirm:$false
            $second.Ready | Should -BeTrue
            $second.MigrationRequired | Should -Be 0
            @($script:events | Where-Object { $_ -like 'push:*' }) | Should -Be @('push:source', 'push:destination')
            @($script:events | Where-Object { $_ -ceq 'backup' }) | Should -HaveCount 1
            @($script:events | Where-Object { $_ -ceq 'complete' }) | Should -HaveCount 1
            foreach ($key in $historicalHashes.Keys) {
                (Get-FileHash -LiteralPath (Get-TestMigrationBlobPath $key)).Hash | Should -BeExactly $historicalHashes[$key]
            }
            Should -Invoke Save-RepositoryMigrationBlob -Times 0 -Exactly -ParameterFilter {
                $Name -cnotlike "bami-consolidation/$($script:scope.TenantId)/$($script:scope.RepoId)/*"
            }
            Should -Invoke Initialize-RepositoryMigrationBackend -Times 0 -Exactly -ParameterFilter { $Key -cin $script:historicalStates.Keys }
            Get-Content -LiteralPath $env:GITHUB_OUTPUT | Should -Be @('ready=false', 'ready=true', 'ready=true')
        }
        finally {
            foreach ($name in $previous.Keys) {
                $value = $previous[$name]
                [Environment]::SetEnvironmentVariable($name, ($null -eq $value ? [NullString]::Value : $value), 'Process')
            }
        }
    }

    It 'resumes a lost response after the <Side> publication without repeating it' -ForEach @(
        @{ Side = 'source'; Position = 'SourcePublished'; CacheChange = 'result' }
        @{ Side = 'destination'; Position = 'DestinationPublished'; CacheChange = 'order' }
    ) {
        $transfer = New-TestMigrationTransfer
        $script:interruptAfter = $Side
        { Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false } | Should -Throw "*response lost after $Side push*"
        $checkpoint = Get-RepositoryMigrationPosition $transfer
        $checkpoint.Status | Should -Be $Position
        $state = $checkpoint.Current[$Side].State
        if ($CacheChange -ceq 'result') {
            $state.check_results[0].status = 'unknown'
        } else {
            [array]::Reverse($state.check_results)
        }
        $key = $Side -ceq 'source' ? $script:scope.SourceKey : $script:scope.DestinationKey
        Write-TestMigrationState -Name $key -State $state
        $script:interruptAfter = ''
        $recovered = New-TestMigrationTransfer
        $recovered.Position | Should -Be $Position
        Invoke-RepositoryMigrationTransfer -Transfer $recovered -Confirm:$false | Should -Be 'Complete'
        @($script:events | Where-Object { $_ -ceq 'push:source' }) | Should -HaveCount 1
        @($script:events | Where-Object { $_ -ceq 'push:destination' }) | Should -HaveCount 1
    }

    It 'rejects a stale <Side> before publication without creating a backup' -ForEach @(
        @{ Side = 'Source' }, @{ Side = 'Destination' }
    ) {
        $transfer = New-TestMigrationTransfer
        $script:pair[$Side].serial++
        $key = $Side -ceq 'Source' ? $script:scope.SourceKey : $script:scope.DestinationKey
        Write-TestMigrationState -Name $key -State $script:pair[$Side]
        { Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false } | Should -Throw '*not an exact supported migration checkpoint*'
        Should -Invoke Save-RepositoryMigrationBlob -Times 0 -Exactly
        Should -Invoke Initialize-RepositoryMigrationBackend -Times 0 -Exactly
        @($script:events | Where-Object { $_ -like 'push:*' }) | Should -HaveCount 0
    }

    It 'recovers a completion-record interruption without another state push' {
        $transfer = New-TestMigrationTransfer
        $script:completionFailure = $true
        { Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false } | Should -Throw '*completion upload interruption*'
        (Get-RepositoryMigrationPosition $transfer).Status | Should -Be 'DestinationPublished'
        $script:completionFailure = $false
        Invoke-RepositoryMigrationTransfer -Transfer (New-TestMigrationTransfer) -Confirm:$false | Should -Be 'Complete'
        @($script:events | Where-Object { $_ -like 'push:*' }) | Should -HaveCount 2
    }

    It 'stops after an interrupted source push if the destination no longer matches its checkpoint' {
        $transfer = New-TestMigrationTransfer
        $script:interruptAfter = 'source'
        { Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false } | Should -Throw '*response lost*'
        $script:pair.Destination.serial++
        Write-TestMigrationState -Name $script:scope.DestinationKey -State $script:pair.Destination
        $script:interruptAfter = ''
        { New-TestMigrationTransfer } | Should -Throw '*not an exact supported migration checkpoint*'
        @($script:events | Where-Object { $_ -like 'push:*' }) | Should -Be @('push:source')
    }

    It 'rejects changed source ownership after completion rather than overwriting it' {
        $transfer = New-TestMigrationTransfer
        Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false | Should -Be 'Complete'
        Write-TestMigrationState -Name $script:scope.SourceKey -State $script:pair.Source
        { New-TestMigrationTransfer } | Should -Throw '*disagrees with the verified migration*'
        @($script:events | Where-Object { $_ -like 'push:*' }) | Should -HaveCount 2
    }

    It 'accepts legitimate later destination outputs and permission retirement without another migration' {
        $transfer = New-TestMigrationTransfer
        Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false | Should -Be 'Complete'
        $position = Get-RepositoryMigrationPosition $transfer
        $changed = $position.Current.destination.State
        $changed.resources = @($changed.resources | Where-Object { $_.name -cnotin @('example', 'identity_role_assignment') })
        $changed.outputs['new_ordinary_output'] = @{ value = 'synthetic-ordinary-apply'; type = 'string' }
        $changed.serial++
        $path = Join-Path $TestDrive 'evolved.tfstate'
        [IO.File]::WriteAllText($path, (ConvertTo-Json $changed -Depth 100))
        Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root (Join-Path $transfer.BackendDirectory 'destination-backend') `
            -Arguments @('state', 'push', '-lock-timeout=30s', $path)
        $pushes = @($script:events | Where-Object { $_ -like 'push:*' }).Count
        $recovered = New-TestMigrationTransfer
        Invoke-RepositoryMigrationTransfer -Transfer $recovered -Confirm:$false | Should -Be 'Complete'
        @($script:events | Where-Object { $_ -like 'push:*' }) | Should -HaveCount $pushes
        (Get-RepositoryMigrationPosition $recovered).Current.destination.State.outputs.new_ordinary_output.value |
            Should -Be 'synthetic-ordinary-apply'
    }

    It 'runs the native publisher, an ordinary unified saved-plan apply, and a no-op migration rerun' {
        $configuration = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($name in @('identity', 'github', 'source', 'destination', 'unified', 'images')) {
            $null = [IO.Directory]::CreateDirectory((Join-Path $configuration $name))
        }
        $identityDefinition = $script:nativeIdentityDefinition
        [IO.File]::WriteAllText((Join-Path $configuration 'identity' 'main.tf'), $identityDefinition)
        [IO.File]::WriteAllText((Join-Path $configuration 'github' 'main.tf'), $script:nativeGitHubDefinition)
        $script:scope.SourceKey = 'synthetic-source.tfstate'
        $script:scope.DestinationKey = 'synthetic-destination.tfstate'
        foreach ($side in @('source', 'destination', 'unified')) {
            $key = $side -ceq 'source' ? $script:scope.SourceKey : $script:scope.DestinationKey
            $backendPath = ConvertTo-Json -InputObject (Get-TestMigrationBlobPath $key) -Compress
            $definition = "terraform {`n  backend `"local`" {`n    path = $backendPath`n  }`n}`n"
            if ($side -cne 'source') {
                $definition += "module `"github`" { source = `"../github`" }`n"
                $definition += "output `"repository`" { value = module.github.repository }`n"
            }
            if ($side -ceq 'source') {
                $definition += "module `"azure`" { source = `"../identity`" }`n"
                $definition += "output `"test_identity`" { value = module.azure.identity }`n"
                $definition += "output `"private_marker`" {`n value = `"synthetic-preserved-output`"`n sensitive = true`n}`n"
            }
            if ($side -ceq 'unified') {
                $definition += "module `"bami`" {`n source = `"../identity`"`n count = 1`n}`n"
                $definition += "output `"test_identity`" { value = module.bami[0].identity }`n"
                $definition += "output `"test_group_contract`" { value = module.bami[0].groups }`n"
            }
            $directory = Join-Path $configuration $side
            [IO.File]::WriteAllText((Join-Path $directory 'main.tf'), $definition)
            $null = Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root $directory `
                -Arguments @('init', '-input=false', '-no-color') -PrivateOutput
            if ($side -cne 'unified') {
                $null = Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root $directory `
                    -Arguments @('apply', '-input=false', '-auto-approve', '-no-color') -PrivateOutput
            }
        }
        $paths = @{}
        foreach ($side in @('source', 'destination')) {
            foreach ($version in @('before', 'after')) {
                $paths["$side-$version"] = Join-Path $configuration 'images' "$side-$version.tfstate"
                $key = $side -ceq 'source' ? $script:scope.SourceKey : $script:scope.DestinationKey
                Copy-Item -LiteralPath (Get-TestMigrationBlobPath $key) -Destination $paths["$side-$version"]
            }
        }
        $null = Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root $configuration -PrivateOutput -Arguments @(
            'state', 'mv', '-lock-timeout=30s', "-state=$($paths['source-after'])", "-state-out=$($paths['destination-after'])",
            "-backup=$(Join-Path $configuration 'source.backup')", "-backup-out=$(Join-Path $configuration 'destination.backup')",
            'module.azure', 'module.bami[0]'
        )
        $images = @{}
        foreach ($name in $paths.Keys) { $images[$name] = Read-TransferImage $paths[$name] }
        foreach ($side in @('source', 'destination')) {
            foreach ($kind in @('var', 'resource', 'check', 'output')) {
                $images["$side-before"].State.check_results.object_kind | Should -Contain $kind
            }
            Test-TransferValueEqual (Get-TransferSnapshotMetadata $images["$side-before"].State) `
                (Get-TransferSnapshotMetadata $images["$side-after"].State) | Should -BeTrue
        }
        $archive = Join-Path $configuration 'backup.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $configuration 'images'), $archive)
        $transfer = @{
            Scope = $script:scope; Directory = $configuration; Terraform = $script:tool.Path
            Prefix = "bami-consolidation/$($script:scope.TenantId)/$($script:scope.RepoId)"
            Paths = $paths; Images = $images; BackupPath = $archive; BackupHash = (Get-FileHash $archive).Hash
        }
        Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false | Should -Be 'Complete'
        $migrated = Get-RepositoryMigrationPosition $transfer
        $publishedSerial = $migrated.Current.destination.State.serial
        $identity = @($migrated.Current.destination.State.resources | Where-Object name -CEQ 'identity')[0].instances[0].attributes.id
        $unified = Join-Path $configuration 'unified'
        $null = Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root $unified -PrivateOutput -Arguments @(
            'plan', '-input=false', '-no-color', '-refresh=false', '-out=unified.tfplan'
        )
        $plan = Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root $unified -PrivateOutput `
            -Arguments @('show', '-json', 'unified.tfplan') | ConvertFrom-Json -AsHashtable -Depth 100
        $plan.resource_changes | Should -HaveCount 4
        @($plan.resource_changes | Where-Object { $_.change.actions -contains 'create' -or $_.change.actions -contains 'delete' }) |
            Should -HaveCount 0
        foreach ($change in $plan.resource_changes) {
            $change.change.actions | Should -Be @('no-op')
        }
        $plan.output_changes.test_identity.after.client_id | Should -Be 'synthetic-client'
        $plan.output_changes.test_group_contract.after.Keys | Should -HaveCount 2
        $null = Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root $unified -PrivateOutput `
            -Arguments @('apply', '-input=false', '-no-color', 'unified.tfplan')
        $applied = (Get-RepositoryMigrationPosition $transfer).Current.destination.State
        $applied.serial | Should -BeGreaterThan $publishedSerial
        @($applied.check_results | Where-Object { $_.config_addr -clike 'module.azure.*' }) | Should -HaveCount 0
        foreach ($kind in @('var', 'resource', 'check', 'output')) {
            $applied.check_results.object_kind | Should -Contain $kind
        }
        @($applied.check_results | Where-Object status -CNE 'pass') | Should -HaveCount 0
        Test-TransferValueEqual $applied.outputs.repository $images['destination-before'].State.outputs.repository | Should -BeTrue
        foreach ($resource in $migrated.Current.destination.State.resources) {
            $retained = @($applied.resources | Where-Object {
                (Get-TransferResourceKey $_) -ceq (Get-TransferResourceKey $resource)
            })
            $retained | Should -HaveCount 1
            $retained[0].instances.attributes.id | Should -Be $resource.instances.attributes.id
        }
        Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false | Should -Be 'Complete'

        [IO.File]::WriteAllText((Join-Path $configuration 'identity' 'main.tf'), $identityDefinition.Replace('["readers", "owners"]', '["readers"]'))
        $null = Invoke-RepositoryMigrationTerraform -Terraform $script:tool.Path -Root $unified -PrivateOutput `
            -Arguments @('apply', '-input=false', '-auto-approve', '-refresh=false', '-no-color')
        Invoke-RepositoryMigrationTransfer -Transfer $transfer -Confirm:$false | Should -Be 'Complete'
        $evolved = (Get-RepositoryMigrationPosition $transfer).Current.destination.State
        @($evolved.resources | Where-Object name -CEQ 'identity')[0].instances[0].attributes.id | Should -Be $identity
        @($evolved.resources | Where-Object name -CEQ 'membership')[0].instances | Should -HaveCount 1
        @($script:events | Where-Object { $_ -like 'push:*' }) | Should -HaveCount 2
        Test-TransferValueEqual (Get-RepositoryMigrationPosition $transfer).Current.source.State.outputs $images['source-before'].State.outputs |
            Should -BeTrue
    }
}
