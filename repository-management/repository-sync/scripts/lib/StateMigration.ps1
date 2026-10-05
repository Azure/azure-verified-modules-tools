. (Join-Path $PSScriptRoot 'StateImages.ps1')

function Invoke-RepositoryMigrationTerraform {
    param([string] $Terraform, [string] $Root, [string[]] $Arguments, [switch] $PrivateOutput)

    $environment = Get-RepositorySyncTerraformEnvironment -Root $Root
    $environment.GH_TOKEN = $null
    $environment.CHECKPOINT_DISABLE = '1'
    $environment.TF_CLI_CONFIG_FILE = Join-Path $Root 'migration.tfrc'
    [IO.File]::WriteAllText($environment.TF_CLI_CONFIG_FILE, '', [Text.UTF8Encoding]::new($false))
    try {
        $result = Invoke-RepositorySyncProcess -Command $Terraform -Arguments $Arguments `
            -WorkingDirectory $Root -EnvVars $environment -TimeoutSec 300
    }
    catch [TimeoutException] {
        $detail = $PrivateOutput ? '' : (Protect-RepositorySyncLogText -Text (@(
            $_.Exception.Data['StdOut'], $_.Exception.Data['StdErr']
        ) -join "`n"))
        throw [TimeoutException]::new("Migration Terraform $($Arguments[0]) timed out; inspect the recorded checkpoints on the next run. No retry or lock repair was attempted.`n$detail")
    }
    if ($result.ExitCode -ne 0) {
        $detail = $PrivateOutput ? '' : (Protect-RepositorySyncLogText -Text (@($result.StdOut, $result.StdErr) -join "`n"))
        $exception = [InvalidOperationException]::new("Migration Terraform $($Arguments[0]) failed (exit $($result.ExitCode)). No state write was retried.`n$detail")
        $exception.Data['ExitCode'] = $result.ExitCode
        throw $exception
    }
    if ($PrivateOutput) { return $result.StdOut }
    foreach ($text in @($result.StdOut, $result.StdErr)) {
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            Write-Information (Protect-RepositorySyncLogText $text) -InformationAction Continue
        }
    }
}

function Assert-RepositoryMigrationContext {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools' -or
        $env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or
        $env:GITHUB_WORKFLOW_REF -cne 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-sync.yml@refs/heads/main' -or
        $env:GITHUB_SHA -cnotmatch '^[0-9a-f]{40}$') {
        throw 'State migration runs only in the trusted Tools main workflow.'
    }
}

function Assert-RepositoryMigrationWriters {
    Assert-RepositoryMigrationContext
    $conflicts = [Collections.Generic.List[string]]::new()
    foreach ($status in @('in_progress', 'queued', 'waiting', 'pending', 'requested')) {
        $page = 1
        do {
            if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { throw 'The workflow read token is required to check competing writers.' }
            $result = Invoke-RepositorySyncProcess -Command gh -Arguments @(
                'api', '--hostname', 'github.com', '--method', 'GET',
                "repos/Azure/azure-verified-modules-tools/actions/workflows/repository-management-sync.yml/runs?status=$status&per_page=100&page=$page"
            ) -EnvVars @{ GH_TOKEN = $env:GITHUB_TOKEN }
            if ($result.ExitCode -ne 0) { throw 'Cannot check competing workflow runs; publication is blocked.' }
            try { $response = ConvertFrom-Json -InputObject $result.StdOut }
            catch { throw 'Invalid workflow run inventory response; publication is blocked.' }
            if ($null -eq $response -or $null -eq $response.workflow_runs) {
                throw 'Could not establish the complete repository-sync writer inventory.'
            }
            foreach ($run in @($response.workflow_runs)) {
                if ([string]$run.id -ceq $env:GITHUB_RUN_ID) { continue }
                if ($run.status -ceq 'in_progress' -or $run.head_sha -cne $env:GITHUB_SHA) {
                    $conflicts.Add([string]$run.id)
                }
            }
            $page++
        } while (@($response.workflow_runs).Count -eq 100)
    }
    if ($conflicts.Count) {
        throw "Other active or old queued repository-sync runs must be handled by the operator: $($conflicts -join ', '). Nothing was cancelled."
    }
}

function Get-RepositoryMigrationScope {
    param(
        [hashtable] $Backend, [System.Collections.IDictionary] $Settings, [string] $RepoId, [object] $Repository,
        [string] $RepositorySyncRepositoryId = $env:GITHUB_REPOSITORY_ID
    )

    $null = Resolve-RepositorySyncStateConfiguration -Backend $Backend
    if ($RepoId -cnotmatch '^avm-(res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*$' -or
        $Repository.full_name -cnotmatch ('^Azure/terraform-(azure|azurerm|azapi)-' + [regex]::Escape($RepoId) + '$') -or
        [string]$Repository.id -cnotmatch '^[1-9][0-9]*$' -or [string]$Repository.owner.id -cnotmatch '^[1-9][0-9]*$' -or
        $Repository.owner.login -cne 'Azure' -or $Repository.fork -ne $false -or
        $RepositorySyncRepositoryId -cnotmatch '^[1-9][0-9]*$') {
        throw 'Migration requires a canonical repository and independently resolved GitHub IDs.'
    }
    return [ordered]@{
        Backend = $Backend
        RepoId = $RepoId
        Repository = $Repository.full_name
        RepositoryId = [string]$Repository.id
        RepositoryOwnerId = [string]$Repository.owner.id
        ToolsRepositoryId = $RepositorySyncRepositoryId
        TenantId = $Settings['TEST_BAMI_TENANT_ID']
        SubscriptionId = $Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID']
        ResourceGroupName = $Settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME']
        ControllerClientId = $Settings['TEST_BAMI_CONTROLLER_CLIENT_ID']
        BicepClientId = $Settings['TEST_BAMI_BICEP_CLIENT_ID']
        SourceKey = Get-AvmBamiIdentityStateKey -TenantId $Settings['TEST_BAMI_TENANT_ID'] -RepoId $RepoId
        DestinationKey = "$RepoId.tfstate"
    }
}

function Get-RepositoryMigrationIdentity {
    param([System.Collections.IDictionary] $Scope, [System.Collections.IDictionary] $State, [string] $Module)

    $identity = @($State['resources'] | Where-Object {
        $_['module'] -ceq $Module -and $_['mode'] -ceq 'managed' -and $_['type'] -ceq 'azapi_resource' -and $_['name'] -ceq 'identity'
    })
    if ($identity.Count -ne 1 -or $identity[0]['instances'].Count -ne 1) {
        throw 'Migration requires exactly one complete repository identity, not partial ownership.'
    }
    $attributes = $identity[0]['instances'][0]['attributes']
    $output = $attributes['output']
    if ($output -is [System.Collections.IDictionary] -and $output.Contains('value')) { $output = $output['value'] }
    $expectedId = "/subscriptions/$($Scope.SubscriptionId)/resourceGroups/$($Scope.ResourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/" +
        $Scope.Repository.Replace('/', '-').Replace('windows', 'w5s')
    if ($output -isnot [System.Collections.IDictionary] -or $output['properties'] -isnot [System.Collections.IDictionary] -or
        $attributes['id'] -ine $expectedId -or $output['properties']['tenantId'] -ine $Scope.TenantId) {
        throw 'State identity does not match the exact selected BAMI tenant, subscription, group, and repository.'
    }
    foreach ($field in @('clientId', 'principalId', 'tenantId')) {
        $id = [guid]::Empty
        if (-not [guid]::TryParseExact([string]$output['properties'][$field], 'D', [ref]$id) -or $id -eq [guid]::Empty) {
            throw 'State identity contains an invalid identity GUID.'
        }
    }
    if ($output['properties']['clientId'] -iin @($Scope.ControllerClientId, $Scope.BicepClientId)) {
        throw 'A shared controller or Bicep identity is not a repository migration target.'
    }
    return @{
        identity_resource_id = $expectedId
        tenant_id = $Scope.TenantId
        client_id = [string]$output['properties']['clientId']
        principal_id = [string]$output['properties']['principalId']
        repository_id = $Scope.RepositoryId
        repository_owner_id = $Scope.RepositoryOwnerId
    }
}

function Assert-RepositoryMigrationBindings {
    param([System.Collections.IDictionary] $State, [switch] $Destination)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($resource in $State['resources']) {
        $namespace = [string]$resource['module']
        $allowed = $Destination ? @('module.github', 'module.azure[0]', 'module.bami[0]') : @('module.azure')
        if ($namespace -cnotin $allowed) { throw 'Unexpected or partially migrated state namespace.' }
        $provider = if ($resource['type'] -cmatch '^azapi_') { 'provider["registry.terraform.io/azure/azapi"]' }
        elseif ($resource['type'] -cmatch '^azuread_') { 'provider["registry.terraform.io/hashicorp/azuread"]' }
        elseif ($namespace -ceq 'module.github' -and $resource['type'] -cmatch '^github_') { 'provider["registry.terraform.io/integrations/github"]' }
        else { throw 'Unexpected migration resource type.' }
        if ($resource['provider'] -cne $provider) { throw 'Aliased or unexpected migration provider binding.' }
        foreach ($instance in $resource['instances']) {
            $attributes = $instance['attributes']
            if ($resource['mode'] -ceq 'managed' -and
                -not $seen.Add("$provider|$($resource['type'])|$(([string]$attributes['id']).ToLowerInvariant())")) {
                throw 'Multiple addresses own the same managed object.'
            }
        }
    }
}

function Assert-RepositoryMigrationOwnership {
    param(
        [System.Collections.IDictionary] $Scope, [System.Collections.IDictionary] $State,
        [System.Collections.IDictionary] $Identity, [string] $Module, [switch] $Destination
    )

    Assert-RepositoryMigrationBindings -State $State -Destination:$Destination
    Assert-TransferValueEqual (Get-RepositoryMigrationIdentity -Scope $Scope -State $State -Module $Module) $Identity 'Repository identity'
    $credentials = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($resource in $State['resources']) {
        $namespace = [string]$resource['module']
        foreach ($instance in $resource['instances']) {
            $attributes = $instance['attributes']
            if ($namespace -cne $Module -or $resource['mode'] -cne 'managed') { continue }
            if ($resource['type'] -ceq 'azuread_group_member') {
                if ($resource['name'] -cnotin @('example', 'test_permissions') -or
                    $attributes['member_object_id'] -ine $Identity.principal_id -or
                    $attributes['id'] -ine "$($attributes['group_object_id'])/member/$($Identity.principal_id)") {
                    throw 'Foreign or unrecognized membership ownership.'
                }
            } elseif ($resource['type'] -ceq 'azapi_resource') {
                if ($resource['name'] -ceq 'identity') { continue }
                if ($resource['name'] -ceq 'identity_role_assignment') {
                    $body = $attributes['body']
                    if ($body -is [System.Collections.IDictionary] -and $body.Contains('value')) { $body = $body['value'] }
                    if ($body -isnot [System.Collections.IDictionary] -or
                        $body['properties']['principalId'] -ine $Identity.principal_id -or
                        $attributes['id'] -inotmatch '^/providers/Microsoft\.Management/managementGroups/[^/]+/providers/Microsoft\.Authorization/roleAssignments/[0-9a-f-]{36}$') {
                        throw 'Foreign or incomplete legacy role ownership.'
                    }
                    continue
                }
                $name = if ($resource['name'] -ceq 'validation_federated_credential') { 'avm-validation' }
                elseif ($resource['name'] -ceq 'identity_federated_credentials') { [string]$instance['index_key'] }
                else { throw 'Unexpected identity resource requires review.' }
                if ($name -cnotin @('pr-check', 'integration-test', 'examples-test', 'avm-validation') -or
                    -not $credentials.Add($name) -or
                    $attributes['id'] -ine "$($Identity.identity_resource_id)/federatedIdentityCredentials/$($Scope.Repository.Replace('/', '-').Replace('windows', 'w5s'))-$name") {
                    throw 'Federation ownership is partial, duplicated, or outside the repository identity.'
                }
                $body = $attributes['body']
                if ($body -is [System.Collections.IDictionary] -and $body.Contains('value')) { $body = $body['value'] }
                if ($body -isnot [System.Collections.IDictionary] -or $body['properties'] -isnot [System.Collections.IDictionary] -or
                    $body['properties']['issuer'] -cne 'https://token.actions.githubusercontent.com' -or
                    -not (Test-TransferValueEqual $body['properties']['audiences'] @('api://AzureADTokenExchange'))) {
                    throw 'Incomplete or unexpected federation trust.'
                }
                $expectedRepo = $name -ceq 'avm-validation' ? $Scope.ToolsRepositoryId : $Scope.RepositoryId
                $subject = "repository_owner_id:$($Scope.RepositoryOwnerId):repository_id:${expectedRepo}:environment:$name"
                $pattern = '^' + [regex]::Escape($subject) + ($name -ceq 'avm-validation' ? '$' : ':job_workflow_ref:\S+$')
                if ([string]$body['properties']['subject'] -cnotmatch $pattern) { throw 'Federation trusts a different repository or environment.' }
            } else { throw 'Unexpected managed BAMI resource requires review.' }
        }
    }
    if ($credentials.Count -ne 4) { throw 'All four repository federated credentials must be owned before migration.' }
    if ($Destination) {
        $repo = @($State['resources'] | Where-Object {
            $_['module'] -ceq 'module.github' -and $_['type'] -ceq 'github_repository' -and $_['name'] -ceq 'this'
        })
        if ($repo.Count -ne 1 -or $repo[0]['instances'].Count -ne 1 -or
            $repo[0]['instances'][0]['attributes']['full_name'] -cne $Scope.Repository -or
            [string]$repo[0]['instances'][0]['attributes']['repo_id'] -cne $Scope.RepositoryId) {
            throw 'Destination GitHub ownership changed or is incomplete.'
        }
    }
}

function Read-RepositoryMigrationRecord {
    param([string] $Path)
    try { return ConvertFrom-TransferJson (Get-Content -LiteralPath $Path -Raw) }
    catch { throw 'Invalid private migration record; its contents are not logged.' }
}

function Test-RepositoryMigrationPublishedImage {
    param([System.Collections.IDictionary] $Actual, [System.Collections.IDictionary] $Staged)

    if ($Actual['serial'] -ne ($Staged['serial'] + 1)) { return $false }
    $expected = ConvertFrom-Json (ConvertTo-Json -InputObject $Staged -Depth 100 -Compress) -AsHashtable
    $expected['serial']++
    return Test-TransferValueEqual $Actual $expected
}

function Assert-RepositoryMigrationAnchors {
    param([System.Collections.IDictionary] $Current, [System.Collections.IDictionary] $Staged)

    foreach ($anchor in $Staged['resources'] | Where-Object {
        $_['mode'] -ceq 'managed' -and (
            ($_['module'] -ceq 'module.bami[0]' -and $_['name'] -cin @('identity', 'identity_federated_credentials', 'validation_federated_credential')) -or
            ($_['module'] -ceq 'module.github' -and ($_['type'] -ceq 'github_repository' -or $_['name'] -ceq 'repository'))
        )
    }) {
        $key = Get-TransferResourceKey $anchor
        $found = @($Current['resources'] | Where-Object { (Get-TransferResourceKey $_) -ceq $key })
        if ($found.Count -ne 1 -or $found[0]['provider'] -cne $anchor['provider'] -or
            $found[0]['instances'].Count -ne $anchor['instances'].Count) {
            throw 'An established repository, identity, or federation owner changed after migration.'
        }
        foreach ($instance in $anchor['instances']) {
            $currentInstances = @($found[0]['instances'] | Where-Object {
                (Test-TransferValueEqual $_['index_key'] $instance['index_key']) -and
                $_['attributes']['id'] -ceq $instance['attributes']['id']
            })
            if ($currentInstances.Count -ne 1) { throw 'An established managed resource ID changed after migration.' }
        }
    }
}

function Get-RepositoryMigrationPosition {
    param([hashtable] $Transfer)

    $current = @{}
    foreach ($side in @('source', 'destination')) {
        $path = Join-Path $Transfer.Directory "$side-current.tfstate"
        $key = $side -ceq 'source' ? $Transfer.Scope.SourceKey : $Transfer.Scope.DestinationKey
        if (-not (Get-RepositoryMigrationBlob -Backend $Transfer.Scope.Backend -Name $key -Path $path)) {
            throw "Migration $side state disappeared; stop without publication."
        }
        $current[$side] = Read-TransferImage $path
    }
    $sourceOriginal = $current.source.Hash -ceq $Transfer.Images['source-before'].Hash
    $destinationOriginal = $current.destination.Hash -ceq $Transfer.Images['destination-before'].Hash
    $sourcePublished = Test-RepositoryMigrationPublishedImage $current.source.State $Transfer.Images['source-after'].State
    $destinationPublished = Test-RepositoryMigrationPublishedImage $current.destination.State $Transfer.Images['destination-after'].State
    $completionPath = Join-Path $Transfer.Directory 'complete.json'
    if (Get-RepositoryMigrationBlob -Backend $Transfer.Scope.Backend -Name "$($Transfer.Prefix)/complete.json" -Path $completionPath) {
        $completion = Read-RepositoryMigrationRecord $completionPath
        if ($completion['version'] -ne 1 -or $completion['backupSha256'] -cne $Transfer.BackupHash -or
            -not (Test-TransferValueEqual $completion['scope'] $Transfer.Scope) -or -not $sourcePublished -or
            $completion['sourceSha256'] -cne $current.source.Hash -or
            $completion['destinationSerial'] -ne ($Transfer.Images['destination-after'].State.serial + 1) -or
            $current.destination.State['lineage'] -cne $Transfer.Images['destination-before'].State.lineage -or
            $current.destination.State['serial'] -lt $completion['destinationSerial']) {
            throw 'Completion record or current state disagrees with the verified migration.'
        }
        if ($current.destination.State['serial'] -eq $completion['destinationSerial'] -and
            ($current.destination.Hash -cne $completion['destinationSha256'] -or -not $destinationPublished)) {
            throw 'Destination changed without a legitimate serial advance.'
        }
        Assert-RepositoryMigrationAnchors -Current $current.destination.State -Staged $Transfer.Images['destination-after'].State
        return @{ Status = 'Complete'; Current = $current }
    }
    $status = if ($sourceOriginal -and $destinationOriginal) { 'Prepared' }
    elseif ($sourcePublished -and $destinationOriginal) { 'SourcePublished' }
    elseif ($sourcePublished -and $destinationPublished) { 'DestinationPublished' }
    else { throw 'State images are not an exact supported migration checkpoint; no state write will be retried.' }
    return @{ Status = $status; Current = $current }
}

function New-RepositoryMigrationTransfer {
    param(
        [System.Collections.IDictionary] $Scope, [string] $Directory, [string] $Terraform, [string] $TerraformVersion,
        [string] $OriginalDestinationPath
    )

    $null = [IO.Directory]::CreateDirectory($Directory)
    $imagesDirectory = Join-Path $Directory 'images'
    $null = [IO.Directory]::CreateDirectory($imagesDirectory)
    $prefix = "bami-consolidation/$($Scope.TenantId)/$($Scope.RepoId)"
    $archivePath = Join-Path $Directory 'backup.zip'
    $paths = @{}
    foreach ($name in @('source-before', 'destination-before', 'source-after', 'destination-after')) {
        $paths[$name] = Join-Path $imagesDirectory "$name.tfstate"
    }
    $metadataPath = Join-Path $imagesDirectory 'metadata.json'
    $stored = Get-RepositoryMigrationBlob -Backend $Scope.Backend -Name "$prefix/backup.zip" -Path $archivePath
    if ($stored) {
        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $names = @($paths.Keys | ForEach-Object { "$_.tfstate" }) + @('metadata.json')
            if ($archive.Entries.Count -ne 5 -or @($archive.Entries | Where-Object { $_.FullName -cnotin $names }).Count -gt 0 -or
                @($archive.Entries.FullName | Select-Object -Unique).Count -ne 5) {
                throw 'The migration backup must contain exactly four state images and its metadata.'
            }
            foreach ($entry in $archive.Entries) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $imagesDirectory $entry.FullName), $false)
            }
        }
        finally { $archive.Dispose() }
        $metadata = Read-RepositoryMigrationRecord $metadataPath
        if ($metadata['version'] -ne 1 -or $metadata['terraformVersion'] -cne $TerraformVersion -or
            -not (Test-TransferValueEqual $metadata['scope'] $Scope)) {
            throw 'Recovery backup has a different backend, repository, BAMI scope, or Terraform version.'
        }
        $identity = $metadata['identity']
        foreach ($name in $paths.Keys) {
            if ((Get-FileHash -LiteralPath $paths[$name]).Hash -cne $metadata['hashes'][$name]) {
                throw 'Recovery backup hash verification failed.'
            }
        }
    }
    else {
        foreach ($side in @('source', 'destination')) {
            if ($side -ceq 'destination' -and $OriginalDestinationPath) {
                Copy-Item -LiteralPath $OriginalDestinationPath -Destination $paths['destination-before']
                continue
            }
            $key = $side -ceq 'source' ? $Scope.SourceKey : $Scope.DestinationKey
            if (-not (Get-RepositoryMigrationBlob -Backend $Scope.Backend -Name $key -Path $paths["$side-before"])) {
                throw "An existing split migration requires both original states; $side is missing."
            }
        }
        $source = Read-TransferImage $paths['source-before']
        $identity = Get-RepositoryMigrationIdentity -Scope $Scope -State $source.State -Module 'module.azure'
        Assert-RepositoryMigrationOwnership -Scope $Scope -State $source.State -Identity $identity -Module 'module.azure'
        Copy-Item -LiteralPath $paths['source-before'] -Destination $paths['source-after']
        Copy-Item -LiteralPath $paths['destination-before'] -Destination $paths['destination-after']
        Invoke-RepositoryMigrationTerraform -Terraform $Terraform -Root $Directory -Arguments @(
            'state', 'mv', '-lock-timeout=30s', "-state=$($paths['source-after'])", "-state-out=$($paths['destination-after'])",
            "-backup=$(Join-Path $Directory 'source.native-backup')", "-backup-out=$(Join-Path $Directory 'destination.native-backup')",
            'module.azure', 'module.bami[0]'
        )
    }
    $images = @{}
    foreach ($name in $paths.Keys) { $images[$name] = Read-TransferImage $paths[$name] }
    Assert-RepositoryMigrationOwnership -Scope $Scope -State $images['source-before'].State -Identity $identity -Module 'module.azure'
    $null = & (Join-Path $PSScriptRoot '..' 'Test-RepositoryStateTransfer.ps1') `
        -SourceBefore $paths['source-before'] -DestinationBefore $paths['destination-before'] `
        -SourceAfter $paths['source-after'] -DestinationAfter $paths['destination-after'] `
        -SourceSha256 $images['source-before'].Hash -DestinationSha256 $images['destination-before'].Hash `
        -Repository $Scope.Repository -Identity $identity
    Assert-RepositoryMigrationOwnership -Scope $Scope -State $images['destination-after'].State `
        -Identity $identity -Module 'module.bami[0]' -Destination
    if (-not $stored) {
        $hashes = @{}
        foreach ($name in $images.Keys) { $hashes[$name] = $images[$name].Hash }
        $metadata = @{ version = 1; scope = $Scope; identity = $identity; terraformVersion = $TerraformVersion; hashes = $hashes }
        [IO.File]::WriteAllText($metadataPath, (ConvertTo-Json -InputObject $metadata -Depth 100), [Text.UTF8Encoding]::new($false))
        [IO.Compression.ZipFile]::CreateFromDirectory($imagesDirectory, $archivePath)
    }
    $transfer = @{
        Scope = $Scope; Identity = $identity; Directory = $Directory; Prefix = $prefix; Paths = $paths; Images = $images
        BackupPath = $archivePath; BackupHash = (Get-FileHash -LiteralPath $archivePath).Hash
        Terraform = $Terraform
    }
    $position = Get-RepositoryMigrationPosition -Transfer $transfer
    if ($position.Status -ceq 'Complete') {
        Assert-RepositoryMigrationOwnership -Scope $Scope -State $position.Current.destination.State `
            -Identity $identity -Module 'module.bami[0]' -Destination
    }
    $transfer['Position'] = $position.Status
    $transfer['Inventory'] = $position.Current
    return $transfer
}

function Invoke-RepositoryMigrationTransfer {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable] $Transfer, [switch] $PlanOnly)

    $position = Get-RepositoryMigrationPosition -Transfer $Transfer
    if ($position.Status -ceq 'Complete') {
        Write-Information "$($Transfer.Scope.RepoId): migration already complete; ordinary destination evolution is preserved." -InformationAction Continue
        return 'Complete'
    }
    if ($PlanOnly -or -not $PSCmdlet.ShouldProcess($Transfer.Scope.Repository, 'Transfer BAMI state ownership with native source-first pushes')) {
        Write-Information "$($Transfer.Scope.RepoId): migration required ($($position.Status)); local preview only, no remote files or states written." -InformationAction Continue
        return 'Preview'
    }
    Assert-RepositoryMigrationContext
    Save-RepositoryMigrationBlob -Backend $Transfer.Scope.Backend -Name "$($Transfer.Prefix)/backup.zip" `
        -Path $Transfer.BackupPath -Confirm:$false
    $roots = @{}
    foreach ($side in @('source', 'destination')) {
        $workingDirectory = $Transfer['BackendDirectory'] ? $Transfer['BackendDirectory'] : $Transfer.Directory
        $roots[$side] = Join-Path $workingDirectory "$side-backend"
        $key = $side -ceq 'source' ? $Transfer.Scope.SourceKey : $Transfer.Scope.DestinationKey
        Initialize-RepositoryMigrationBackend -Backend $Transfer.Scope.Backend -Key $key `
            -Root $roots[$side] -Terraform $Transfer.Terraform
    }
    foreach ($step in @(
        @{ Position = 'Prepared'; Side = 'source'; Next = 'SourcePublished' },
        @{ Position = 'SourcePublished'; Side = 'destination'; Next = 'DestinationPublished' }
    )) {
        $position = Get-RepositoryMigrationPosition -Transfer $Transfer
        if ($position.Status -cne $step.Position) { continue }
        Write-Information "$($Transfer.Scope.RepoId): publishing $($step.Side) ownership checkpoint." -InformationAction Continue
        Invoke-RepositoryMigrationTerraform -Terraform $Transfer.Terraform -Root $roots[$step.Side] -Arguments @(
            'state', 'push', '-lock-timeout=30s', $Transfer.Paths["$($step.Side)-after"]
        )
        $position = Get-RepositoryMigrationPosition -Transfer $Transfer
        if ($position.Status -cne $step.Next) {
            throw "The $($step.Side) publication did not produce the exact expected checkpoint."
        }
    }
    $position = Get-RepositoryMigrationPosition -Transfer $Transfer
    if ($position.Status -cne 'DestinationPublished') { throw 'Migration did not reach verified single ownership.' }
    $completion = @{
        version = 1; scope = $Transfer.Scope; backupSha256 = $Transfer.BackupHash
        sourceSha256 = $position.Current.source.Hash
        destinationSha256 = $position.Current.destination.Hash
        destinationSerial = $position.Current.destination.State.serial
    }
    $completionPath = Join-Path $Transfer.Directory 'complete-new.json'
    [IO.File]::WriteAllText($completionPath, (ConvertTo-Json -InputObject $completion -Depth 100), [Text.UTF8Encoding]::new($false))
    Save-RepositoryMigrationBlob -Backend $Transfer.Scope.Backend -Name "$($Transfer.Prefix)/complete.json" -Path $completionPath -Confirm:$false
    if ((Get-RepositoryMigrationPosition -Transfer $Transfer).Status -cne 'Complete') { throw 'Completion readback failed.' }
    Write-Information "$($Transfer.Scope.RepoId): state migration complete; all BAMI ownership is in the ordinary state." -InformationAction Continue
    return 'Complete'
}
