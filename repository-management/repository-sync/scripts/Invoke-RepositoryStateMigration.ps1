#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [hashtable] $Backend,
    [Parameter(Mandatory)] [hashtable] $BamiSettings,
    [switch] $PlanOnly = $true
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'Logging.ps1')
. (Join-Path $PSScriptRoot 'lib' 'TestTenant.ps1')
. (Join-Path $PSScriptRoot 'lib' 'StateMigration.ps1')
. (Join-Path $PSScriptRoot 'lib' 'StateMigrationStorage.ps1')

$null = Resolve-RepositorySyncStateConfiguration -Backend $Backend
$settings = Get-AvmBamiSettings -Values $BamiSettings
if ($Backend.ClientId -iin @($settings['TEST_BAMI_CONTROLLER_CLIENT_ID'], $settings['TEST_BAMI_BICEP_CLIENT_ID'])) {
    throw 'Migration must use the separate state-only identity, not a BAMI controller or execution client.'
}
if (-not $PSCmdlet.ShouldProcess("$($Backend.StorageAccountName)/$($Backend.ContainerName)", 'Inspect and consolidate repository state ownership')) {
    return
}
Assert-RepositoryMigrationWriters
$toolsContext = Resolve-AvmRepositorySyncFederationContext
Assert-RepositoryMigrationStorage -Backend $Backend
$module = Get-Module Avm.Authoring | Select-Object -First 1
if (-not $module) { throw 'Import Avm.Authoring before migration.' }
$terraform = & $module { Resolve-AvmTool -Name terraform }
$work = Join-Path ([IO.Path]::GetTempPath()) ("avm-state-migration-" + [guid]::NewGuid().ToString('N'))
if ($IsWindows) {
    $null = [IO.Directory]::CreateDirectory($work)
} else {
    $null = [IO.Directory]::CreateDirectory($work, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
}
$sourcePrefix = "bami-identities/$($settings['TEST_BAMI_TENANT_ID'])/"
$backupPrefix = "bami-consolidation/$($settings['TEST_BAMI_TENANT_ID'])/"
$historicalRepositories = @{
    'avm-template' = 'Azure/terraform-azurerm-avm-template'
    'avm-gh-app' = 'Azure/avm-gh-app'
    'avm-container-images-cicd-agents-and-runners' = 'Azure/avm-container-images-cicd-agents-and-runners'
}
$legacyAliasKey = 'avm-res-redhatopenShift-openshiftcluster.tfstate'
$legacyCanonicalId = 'avm-res-redhatopenshift-openshiftcluster'

Write-Information 'Temporary state migration inventories all configured-tenant state keys, including repositories excluded from ordinary sync.' -InformationAction Continue
try {
    $prepared = Invoke-RepositorySyncLogGroup -Name 'State migration inventory and native local staging' -Action {
        $sources = @(Get-RepositoryMigrationBlobList -Backend $Backend -Prefix $sourcePrefix)
        $backups = @(Get-RepositoryMigrationBlobList -Backend $Backend -Prefix $backupPrefix)
        $destinations = @(Get-RepositoryMigrationBlobList -Backend $Backend -Prefix 'avm-')
        $sourceIds = @{}
        $backupIds = @{}
        $backupKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $destinationIds = @{}
        $ordinaryKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($item in $destinations) {
            $key = [string]$item['name']
            if (-not $ordinaryKeys.Add($key)) {
                throw "Duplicate ordinary repository state key $(Format-RepositoryMigrationKey -Backend $Backend -Prefix 'avm-' -Name $key). Expected unique physical keys; no publication will start."
            }
        }
        foreach ($item in $sources) {
            $match = [regex]::Match($item['name'], ('\A' + [regex]::Escape($sourcePrefix) + '(avm-(?:res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*)\.tfstate\z'))
            if (-not $match.Success -or $sourceIds.ContainsKey($match.Groups[1].Value)) {
                throw "Unexpected or duplicate/aliased source key $(Format-RepositoryMigrationKey -Backend $Backend -Prefix $sourcePrefix -Name $item['name']). Expected one canonical AVM module state per repository in the configured BAMI prefix; no publication will start."
            }
            $sourceIds[$match.Groups[1].Value] = $item['name']
        }
        foreach ($item in $backups) {
            $match = [regex]::Match($item['name'], ('\A' + [regex]::Escape($backupPrefix) + '(avm-(?:res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*)/(backup\.zip|complete\.json)\z'))
            if (-not $match.Success -or -not $backupKeys.Add($item['name'])) {
                throw "Unexpected or duplicate recovery key $(Format-RepositoryMigrationKey -Backend $Backend -Prefix $backupPrefix -Name $item['name']). Expected unique canonical AVM module backup.zip or complete.json objects; no publication will start."
            }
            $backupIds[$match.Groups[1].Value] = $true
        }
        foreach ($item in $destinations) {
            if ($item['name'] -ceq $legacyAliasKey) { continue }
            $match = [regex]::Match($item['name'], '\A(avm-[a-z0-9]+(?:-[a-z0-9]+)*)\.tfstate\z')
            if (-not $match.Success -or ($match.Groups[1].Value -cnotmatch '\Aavm-(res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*\z' -and
                $match.Groups[1].Value -cnotin $historicalRepositories.Keys)) {
                throw "Unexpected or aliased ordinary repository state key $(Format-RepositoryMigrationKey -Backend $Backend -Prefix 'avm-' -Name $item['name']). Expected a canonical avm-(res|ptn|utl)-*.tfstate or an explicitly recognized historical repository key; no key is normalized or ignored and no publication will start."
            }
            $destinationIds[$match.Groups[1].Value] = $item['name']
        }
        $transfers = [Collections.Generic.List[hashtable]]::new()
        $owned = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
        $canonicalOwner = $null
        $withoutSource = 0
        foreach ($repoId in @(@($sourceIds.Keys) + @($backupIds.Keys) + @($destinationIds.Keys) | Sort-Object -Unique)) {
            if (-not $destinationIds.ContainsKey($repoId) -or ($backupIds.ContainsKey($repoId) -and -not $sourceIds.ContainsKey($repoId))) {
                throw "$repoId has a missing original state or incomplete recovery inventory; no publication will start."
            }
            $directory = Join-Path $work $repoId
            $null = [IO.Directory]::CreateDirectory($directory)
            $destinationPath = Join-Path $directory 'inventory-destination.tfstate'
            if (-not (Get-RepositoryMigrationBlob -Backend $Backend -Name "$repoId.tfstate" -Path $destinationPath)) {
                throw "$repoId disappeared during inventory."
            }
            if ($historicalRepositories.ContainsKey($repoId)) {
                $keyDescription = Format-RepositoryMigrationKey -Backend $Backend -Prefix 'avm-' -Name $destinationIds[$repoId]
                try {
                    $destination = Read-TransferImage $destinationPath
                    Assert-RepositoryMigrationHistoricalState -State $destination.State -Settings $settings `
                        -Repository $historicalRepositories[$repoId] -OriginalRepository $historicalRepositories[$repoId]
                }
                catch { throw "Historical state audit failed for $keyDescription. $($_.Exception.Message)" }
                Add-RepositoryMigrationOwners -State $destination.State -Owners $owned -Key $keyDescription
                $withoutSource++
                Write-Information "$repoId`: excluded historical flat repository state audited; no transfer." -InformationAction Continue
                continue
            }
            $destination = Read-TransferImage $destinationPath
            Assert-RepositoryMigrationBindings -State $destination.State -Destination
            $repositories = @($destination.State.resources | Where-Object {
                $_['module'] -ceq 'module.github' -and $_['type'] -ceq 'github_repository' -and $_['name'] -ceq 'this'
            })
            if ($repositories.Count -ne 1 -or $repositories[0]['instances'].Count -ne 1) {
                throw "$repoId lacks unambiguous GitHub ownership."
            }
            $repositoryState = $repositories[0]['instances'][0]['attributes']
            $name = $repositoryState['full_name']
            if ($name -cnotmatch ('\AAzure/terraform-(azure|azurerm|azapi)-' + [regex]::Escape($repoId) + '\z')) {
                throw "$repoId has a renamed or foreign repository alias."
            }
            if ([string]$repositoryState['repo_id'] -cnotmatch '\A[1-9][0-9]*\z') {
                throw "$repoId lacks a valid immutable GitHub repository ID."
            }
            $repository = Invoke-RepositoryGitHubApi -Endpoint "repos/$name"
            if ($repository.full_name -cne $name -or $repository.owner.login -cne 'Azure' -or $repository.fork -ne $false -or
                [string]$repository.id -cnotmatch '\A[1-9][0-9]*\z' -or
                [string]$repository.owner.id -cne $toolsContext.OrganizationId -or
                [string]$repository.id -cne [string]$repositoryState['repo_id']) {
                throw "$repoId GitHub identity differs from its state."
            }
            if ($repoId -ceq $legacyCanonicalId) {
                $canonicalOwner = @{ Repository = $repositories[0]['instances'][0]['attributes']; Lineage = $destination.State.lineage }
            }
            $states = @(@{ State = $destination.State; Key = $destinationIds[$repoId]; Prefix = 'avm-' })
            if ($sourceIds.ContainsKey($repoId)) {
                $scope = Get-RepositoryMigrationScope -Backend $Backend -Settings $settings -RepoId $repoId -Repository $repository
                $transfer = New-RepositoryMigrationTransfer -Scope $scope -Directory (Join-Path $directory 'transfer') `
                    -Terraform $terraform.Path -TerraformVersion $terraform.Version -OriginalDestinationPath $destinationPath
                $transfer['BackendDirectory'] = Join-Path $work 'backends'
                if ($transfer.Inventory.destination.Hash -cne $destination.Hash) { throw "$repoId changed during inventory." }
                $states += @{ State = $transfer.Inventory.source.State; Key = $sourceIds[$repoId]; Prefix = $sourcePrefix }
                $transfers.Add($transfer)
                Write-Information "$repoId`: $($transfer.Position)." -InformationAction Continue
            } else {
                $bami = @($destination.State.resources | Where-Object { $_['module'] -ceq 'module.bami[0]' })
                foreach ($legacy in $destination.State.resources | Where-Object { $_['module'] -ceq 'module.azure[0]' }) {
                    if (@($legacy.instances | Where-Object {
                        [string]$_['attributes']['id'] -ilike "/subscriptions/$($settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/*"
                    }).Count) {
                        throw "$repoId has live BAMI ownership at a retired address; review it instead of creating another owner."
                    }
                }
                if ($bami.Count) {
                    $scope = Get-RepositoryMigrationScope -Backend $Backend -Settings $settings -RepoId $repoId -Repository $repository
                    $identity = Get-RepositoryMigrationIdentity -Scope $scope -State $destination.State -Module 'module.bami[0]'
                    Assert-RepositoryMigrationOwnership -Scope $scope -State $destination.State -Identity $identity -Module 'module.bami[0]' -Destination
                }
                $withoutSource++
                Write-Information "$repoId`: no former split-state owner; no transfer." -InformationAction Continue
            }
            foreach ($snapshot in $states) {
                Add-RepositoryMigrationOwners -State $snapshot.State -Owners $owned `
                    -Key (Format-RepositoryMigrationKey -Backend $Backend -Prefix $snapshot.Prefix -Name $snapshot.Key)
            }
        }
        if ($ordinaryKeys.Contains($legacyAliasKey)) {
            $legacyPath = Join-Path $work 'inventory-legacy-alias.tfstate'
            $keyDescription = Format-RepositoryMigrationKey -Backend $Backend -Prefix 'avm-' -Name $legacyAliasKey
            if (-not (Get-RepositoryMigrationBlob -Backend $Backend -Name $legacyAliasKey -Path $legacyPath)) {
                throw "Historical state $keyDescription disappeared during inventory."
            }
            try {
                $legacy = Read-TransferImage $legacyPath
                Assert-RepositoryMigrationHistoricalState -State $legacy.State -Settings $settings -CaseAlias `
                    -Repository "Azure/terraform-azurerm-$legacyCanonicalId" `
                    -OriginalRepository 'Azure/terraform-azurerm-avm-res-redhatopenShift-openshiftcluster' -CanonicalOwner $canonicalOwner
            }
            catch { throw "Historical state audit failed for $keyDescription. $($_.Exception.Message)" }
            Add-RepositoryMigrationOwners -State $legacy.State -Owners $owned -Key $keyDescription
            $withoutSource++
            Write-Information "$legacyAliasKey`: distinct retired-tenant flat ownership audited; preserved at its exact key with no transfer." -InformationAction Continue
        }
        @{ Transfers = $transfers; Sources = @($sourceIds.Values | Sort-Object); WithoutSource = $withoutSource }
    }
    Write-Information "State inventory complete: $($prepared.Transfers.Count) former split repositories, $($prepared.WithoutSource) without a former source owner." -InformationAction Continue
    $pending = @($prepared.Transfers | Where-Object { $_.Position -cne 'Complete' }).Count
    Assert-RepositoryMigrationWriters
    $results = @(Invoke-RepositorySyncLogGroup -Name 'State migration publication and recovery' -Action {
        foreach ($transfer in $prepared.Transfers) {
            Invoke-RepositoryMigrationTransfer -Transfer $transfer -PlanOnly:$PlanOnly -Confirm:$false
        }
    })
    $finalSources = @(Get-RepositoryMigrationBlobList -Backend $Backend -Prefix $sourcePrefix | ForEach-Object { $_['name'] } | Sort-Object)
    Assert-TransferValueEqual $finalSources $prepared.Sources 'Full source-key inventory'
    Assert-RepositoryMigrationWriters
    $ready = @($results | Where-Object { $_ -cne 'Complete' }).Count -eq 0
    if ($ready) {
        Write-Information "State migration ready: $pending cutover(s) completed or recovered; ordinary repository sync can proceed." -InformationAction Continue
    } else {
        Write-Information "Plan-only staged $pending migration(s) without remote writes. Ordinary sync workers are skipped to avoid planning duplicate BAMI identities." -InformationAction Continue
    }
    if ($env:GITHUB_OUTPUT) { "ready=$($ready.ToString().ToLowerInvariant())" >> $env:GITHUB_OUTPUT }
    [pscustomobject]@{ Ready = $ready; MigrationRequired = $pending; PlanOnly = $PlanOnly.IsPresent }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
$global:LASTEXITCODE = 0
