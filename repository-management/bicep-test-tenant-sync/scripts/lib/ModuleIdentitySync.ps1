function Resolve-AvmBicepIdentitySyncContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $null = Resolve-AvmBicepSyncRunContext
    $tools = Resolve-AvmRepositorySyncFederationContext
    $repository = Invoke-RepositoryGitHubApi -Endpoint 'repos/Azure/bicep-registry-modules'
    if ($null -eq $repository -or $repository.full_name -cne 'Azure/bicep-registry-modules' -or
        $repository.fork -ne $false -or [string]$repository.id -cnotmatch '^[1-9][0-9]*$' -or
        $repository.owner.login -cne 'Azure' -or [string]$repository.owner.id -cne $tools.OrganizationId) {
        throw [System.InvalidOperationException]::new('GitHub did not confirm the expected Bicep repository and organization.')
    }
    return [pscustomobject]@{
        RepositoryId = [string]$repository.id
        OrganizationId = $tools.OrganizationId
        ToolsRepositoryId = $tools.RepositoryId
    }
}

function Test-AvmBicepDedicatedIdentityStateMove {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Resource,
        [Parameter(Mandatory)] [string] $ModuleAddress,
        [Parameter(Mandatory)] [string] $ModulePath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ExistingIdentities
    )

    $change = $Resource['change']
    if ($ExistingIdentities.Contains($ModulePath) -or
        $Resource['mode'] -cne 'managed' -or
        $Resource['type'] -cne 'azapi_resource' -or
        $Resource['provider_name'] -cne 'registry.terraform.io/azure/azapi' -or
        $Resource['address'] -cne "$ModuleAddress.azapi_resource.identity[0]" -or
        $Resource['previous_address'] -cne "$ModuleAddress.azapi_resource.identity" -or
        $change -isnot [System.Collections.IDictionary] -or
        $change['actions'] -isnot [System.Collections.IList] -or
        $change['actions'].Count -ne 1 -or
        $change['actions'][0] -cne 'no-op' -or
        $null -ne $change['importing'] -or
        $change['before'] -isnot [System.Collections.IDictionary] -or
        $change['after'] -isnot [System.Collections.IDictionary]) {
        return $false
    }

    return (ConvertTo-Json -InputObject $change['before'] -Depth 100 -Compress) -ceq
        (ConvertTo-Json -InputObject $change['after'] -Depth 100 -Compress)
}

function Get-AvmBicepSubscriptionVendingStateRetirementEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $State,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $BootstrapIdentity
    )

    $moduleAddress = 'module.bicep["avm/ptn/lz/sub-vending"]'
    if ($State['lineage'] -isnot [string] -or -not [guid]::TryParse($State['lineage'], [ref]([guid]::Empty)) -or
        $State['serial'] -isnot [long] -or $State['serial'] -lt 0 -or
        $State['resources'] -isnot [System.Collections.IList] -or
        $BootstrapIdentity['resource_id'] -isnot [string] -or
        $BootstrapIdentity['client_id'] -isnot [string] -or
        $BootstrapIdentity['principal_id'] -isnot [string]) {
        throw [System.IO.InvalidDataException]::new('State retirement requires complete, typed state and bootstrap identity evidence.')
    }

    $resources = @($State['resources'] | Where-Object {
            $_ -is [System.Collections.IDictionary] -and
            $_['module'] -ceq $moduleAddress -and
            $_['mode'] -ceq 'managed' -and
            $_['type'] -ceq 'azapi_resource' -and
            $_['name'] -ceq 'identity' -and
            $_['provider'] -ceq 'provider["registry.terraform.io/azure/azapi"]'
        })
    if ($resources.Count -ne 1 -or $resources[0]['instances'] -isnot [System.Collections.IList] -or
        $resources[0]['instances'].Count -ne 1) {
        throw [System.InvalidOperationException]::new('State retirement requires exactly one historical dedicated identity state entry.')
    }

    $instance = $resources[0]['instances'][0]
    if ($instance -isnot [System.Collections.IDictionary] -or
        ($instance.Contains('index_key') -and $null -ne $instance['index_key']) -or
        $instance['attributes'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('State retirement requires the unindexed historical dedicated identity entry.')
    }
    $attributes = $instance['attributes']
    if ($attributes['id'] -isnot [string] -or $attributes['output'] -isnot [System.Collections.IDictionary] -or
        $attributes['output']['properties'] -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new('State retirement requires complete historical dedicated identity attributes.')
    }
    $properties = $attributes['output']['properties']
    if ($properties['clientId'] -isnot [string] -or $properties['principalId'] -isnot [string]) {
        throw [System.IO.InvalidDataException]::new('State retirement requires complete historical dedicated identity bindings.')
    }

    $resourceIdDifferent = $attributes['id'] -ine $BootstrapIdentity['resource_id']
    $clientIdDifferent = $properties['clientId'] -ine $BootstrapIdentity['client_id']
    $principalIdDifferent = $properties['principalId'] -ine $BootstrapIdentity['principal_id']
    if (-not ($resourceIdDifferent -and $clientIdDifferent -and $principalIdDifferent)) {
        throw [System.InvalidOperationException]::new('State retirement requires a historical dedicated identity distinct from the bootstrap shared identity.')
    }

    return [pscustomobject]@{
        Address = "$moduleAddress.azapi_resource.identity"
        Lineage = $State['lineage']
        Serial = $State['serial']
        ResourceIdDifferent = $resourceIdDifferent
        ClientIdDifferent = $clientIdDifferent
        PrincipalIdDifferent = $principalIdDifferent
    }
}

function Get-AvmBicepStateRecoveryPolicy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Backend,
        [Parameter(Mandatory)] [hashtable] $Environment
    )

    $result = Invoke-RepositorySyncProcess -Command az -Arguments @(
        'storage', 'blob', 'service-properties', 'show',
        '--account-name', $Backend.StorageAccountName,
        '--auth-mode', 'login',
        '--subscription', $Backend.SubscriptionId,
        '--only-show-errors', '--output', 'json',
        '--query', '{versioningEnabled:isVersioningEnabled,deleteRetentionEnabled:deleteRetentionPolicy.enabled,deleteRetentionDays:deleteRetentionPolicy.days,allowPermanentDelete:deleteRetentionPolicy.allowPermanentDelete}'
    ) -EnvVars $Environment -TimeoutSec 60
    if ($result.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new('State retirement could not verify the backend recovery policy.')
    }
    try {
        $policy = ConvertFrom-Json -InputObject $result.StdOut -AsHashtable -Depth 10 -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new('State retirement received invalid backend recovery policy evidence.')
    }
    if ($policy -isnot [System.Collections.IDictionary] -or
        $policy['versioningEnabled'] -ne $true -or
        $policy['deleteRetentionEnabled'] -ne $true -or
        $policy['deleteRetentionDays'] -isnot [long] -or
        $policy['deleteRetentionDays'] -lt 7 -or
        $policy['allowPermanentDelete'] -ne $false) {
        throw [System.InvalidOperationException]::new('State retirement requires enabled blob versioning and protected deletion retention of at least seven days.')
    }
    $version = Invoke-RepositorySyncProcess -Command az -Arguments @(
        'storage', 'blob', 'show',
        '--account-name', $Backend.StorageAccountName,
        '--container-name', $Backend.ContainerName,
        '--name', 'bicep-module-identities.tfstate',
        '--auth-mode', 'login',
        '--subscription', $Backend.SubscriptionId,
        '--only-show-errors', '--output', 'json',
        '--query', '{versionId:versionId}'
    ) -EnvVars $Environment -TimeoutSec 60
    if ($version.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new('State retirement could not identify the pre-retirement recoverable state version.')
    }
    $versionDocument = $null
    try {
        $versionDocument = [System.Text.Json.JsonDocument]::Parse($version.StdOut)
        $versionProperty = $versionDocument.RootElement.GetProperty('versionId')
        $versionId = $versionProperty.GetString()
    }
    catch {
        throw [System.IO.InvalidDataException]::new('State retirement received invalid pre-retirement version evidence.')
    }
    finally {
        if ($null -ne $versionDocument) {
            $versionDocument.Dispose()
        }
    }
    if ([string]::IsNullOrWhiteSpace($versionId)) {
        throw [System.InvalidOperationException]::new('State retirement requires an explicit pre-retirement recoverable state version.')
    }
    return [pscustomobject]@{
        VersioningEnabled = $true
        DeleteRetentionDays = $policy['deleteRetentionDays']
        PreRetirementVersionId = $versionId
    }
}

function Invoke-AvmBicepSubscriptionVendingStateRetirementPreparation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $TerraformRoot,
        [Parameter(Mandatory)] [hashtable] $Backend,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Configuration
    )

    $settings = Get-AvmBamiSettings -Values $Values
    $state = Resolve-RepositorySyncStateConfiguration -Backend $Backend
    $existingIdentities = Resolve-AvmBicepModuleExistingIdentities `
        -ModulePaths @('avm/ptn/lz/sub-vending') -Configuration $Configuration
    if ($existingIdentities.Count -ne 1 -or -not $existingIdentities.Contains('avm/ptn/lz/sub-vending')) {
        throw [System.InvalidOperationException]::new('State retirement requires the canonical subscription-vending bootstrap selector.')
    }
    $bootstrap = Resolve-AvmSubscriptionVendingIdentity -ExistingIdentity $existingIdentities['avm/ptn/lz/sub-vending'] `
        -Values $settings
    $environment = Get-RepositorySyncTerraformEnvironment -Root $TerraformRoot -Settings $settings
    $recoveryPolicy = Get-AvmBicepStateRecoveryPolicy -Backend $state -Environment $environment
    Invoke-TerraformInit -terraformModulePath $TerraformRoot -repositoryCreationModeEnabled $false `
        -repoId 'bicep-module-identities' -stateStorageAccountName $state.StorageAccountName `
        -stateContainerName $state.ContainerName -stateTenantId $state.TenantId `
        -stateSubscriptionId $state.SubscriptionId -stateClientId $state.ClientId -environment $environment | Out-Null

    $pulled = Invoke-RepositorySyncProcess -Command terraform -Arguments @('state', 'pull') `
        -WorkingDirectory $TerraformRoot -EnvVars $environment -TimeoutSec 300
    if ($pulled.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new('State retirement could not read the selected Terraform state; raw state is private.')
    }
    try {
        $rawState = ConvertFrom-Json -InputObject $pulled.StdOut -AsHashtable -Depth 100 -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new('State retirement received invalid Terraform state; raw state is private.')
    }
    $entry = Get-AvmBicepSubscriptionVendingStateRetirementEntry -State $rawState -BootstrapIdentity $bootstrap

    Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment -Quiet -Arguments @(
        'state', 'rm', '-dry-run', '-lock=true', '-lock-timeout=5m', $entry.Address
    )
    return [pscustomobject]@{
        Status = 'Prepared'
        Address = $entry.Address
        Lineage = $entry.Lineage
        Serial = $entry.Serial
        ResourceIdDifferent = $entry.ResourceIdDifferent
        ClientIdDifferent = $entry.ClientIdDifferent
        PrincipalIdDifferent = $entry.PrincipalIdDifferent
        StateVersioningEnabled = $recoveryPolicy.VersioningEnabled
        StateDeleteRetentionDays = $recoveryPolicy.DeleteRetentionDays
        PreRetirementVersionId = $recoveryPolicy.PreRetirementVersionId
    }
}

function Assert-AvmBicepIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Modules,
        [AllowEmptyCollection()] [System.Collections.IDictionary] $ExistingIdentities = @{},
        [Parameter(Mandatory)] [object] $Context,
        [switch] $PassThru
    )

    if ($Modules.Count -eq 0 -or ($Plan.Contains('errored') -and $Plan['errored'] -ne $false) -or
        ($Plan.Contains('complete') -and $Plan['complete'] -ne $true) -or
        $Plan['resource_changes'] -isnot [System.Collections.IList] -or
        $Plan['planned_values'] -isnot [System.Collections.IDictionary] -or
        $Plan['planned_values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Bicep provisioning requires a complete, nonempty Terraform plan and module inventory.')
    }
    $resources = @(Get-AvmTerraformPlannedResource -Module $Plan['planned_values']['root_module'])
    $moduleAddresses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $approvedStateMoveAddresses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rejectedPlanResources = [System.Collections.Generic.List[object]]::new()
    $rejectionSignatures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $identityNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Modules.Keys) {
        Assert-AvmBicepModulePath -Path $path
        $identityName = if ($ExistingIdentities.Contains($path)) { $ExistingIdentities[$path]['name'] } else { Get-AvmBicepModuleIdentityName -ModulePath $path }
        if (-not $identityNames.Add($identityName)) {
            throw [System.InvalidOperationException]::new('Bicep module paths must produce unique identity names before provisioning.')
        }
        $null = $moduleAddresses.Add("module.bicep[`"$path`"]")
    }
    foreach ($resource in @($Plan['resource_changes']) + $resources) {
        if ($resource -isnot [System.Collections.IDictionary] -or $resource['address'] -isnot [string]) {
            throw [System.InvalidOperationException]::new('Bicep plan resources must have explicit addresses.')
        }
        $match = [regex]::Match($resource['address'], '^(module\.bicep\["([^"]+)"\])\.(.+)$')
        if (-not $match.Success -or -not $moduleAddresses.Contains($match.Groups[1].Value)) {
            throw [System.InvalidOperationException]::new('Bicep plan contains a foreign or removed module; identity retirement requires a separate change.')
        }
        $moduleAddress = $match.Groups[1].Value
        $modulePath = $match.Groups[2].Value
        $suffix = $match.Groups[3].Value
        $expectedProvider = $null
        if ($resource['mode'] -ceq 'managed' -and $resource['type'] -ceq 'azapi_resource' -and
            $suffix -cin @(
                'azapi_resource.identity[0]', 'azapi_resource.identity_federated_credentials["avm-validation"]',
                'azapi_resource.validation_federated_credential', 'azapi_resource.bicep_registry_federated_credential[0]'
            )) {
            $expectedProvider = 'registry.terraform.io/azure/azapi'
        }
        elseif ($resource['mode'] -ceq 'managed' -and $resource['type'] -ceq 'azuread_group_member' -and
            $suffix -cmatch '^azuread_group_member\.test_permissions\["(?:[^"\\]|\\.)+"\]$') {
            $expectedProvider = 'registry.terraform.io/hashicorp/azuread'
        }
        elseif ($resource['mode'] -ceq 'data' -and $resource['type'] -ceq 'azapi_resource' -and
            $suffix -ceq 'data.azapi_resource.existing_identity[0]') {
            $expectedProvider = 'registry.terraform.io/azure/azapi'
        }
        elseif ($resource['mode'] -ceq 'data' -and $resource['type'] -ceq 'azapi_client_config' -and
            $suffix -ceq 'data.azapi_client_config.current') {
            $expectedProvider = 'registry.terraform.io/azure/azapi'
        }
        elseif ($resource['mode'] -ceq 'data' -and
            (($resource['type'] -ceq 'azuread_client_config' -and $suffix -ceq 'data.azuread_client_config.current') -or
                ($resource['type'] -ceq 'azuread_group' -and $suffix -cmatch '^data\.azuread_group\.test_permissions\["(?:[^"\\]|\\.)+"\]$'))) {
            $expectedProvider = 'registry.terraform.io/hashicorp/azuread'
        }
        $approvedStateMove = Test-AvmBicepDedicatedIdentityStateMove -Resource $resource `
            -ModuleAddress $moduleAddress -ModulePath $modulePath -ExistingIdentities $ExistingIdentities
        if ($approvedStateMove) {
            $null = $approvedStateMoveAddresses.Add($resource['address'])
        }
        if (-not $expectedProvider -or $resource['provider_name'] -cne $expectedProvider -or
            (($resource.Contains('previous_address') -and $resource['previous_address'] -cne $resource['address']) -and -not $approvedStateMove) -or
            ($resource.Contains('change') -and $null -ne $resource['change']['importing'])) {
            $address = if ($resource['address'] -is [string]) { $resource['address'] } else { '<invalid>' }
            $mode = if ($resource['mode'] -is [string]) { $resource['mode'] } else { '<invalid>' }
            $type = if ($resource['type'] -is [string]) { $resource['type'] } else { '<invalid>' }
            $providerName = if ($resource['provider_name'] -is [string]) { $resource['provider_name'] } else { '<invalid>' }
            $actions = if ($resource['change']['actions'] -is [System.Collections.IList] -and
                @($resource['change']['actions'] | Where-Object { $_ -isnot [string] }).Count -eq 0) {
                [string]::Join(',', @($resource['change']['actions']))
            }
            else {
                '<invalid>'
            }
            $rejectionCategory = if (-not $expectedProvider) {
                'unexpected-resource'
            }
            elseif ($resource['provider_name'] -cne $expectedProvider) {
                'unexpected-provider'
            }
            elseif ($resource.Contains('previous_address') -and $resource['previous_address'] -cne $resource['address']) {
                'state-address-move'
            }
            else {
                'import-operation'
            }
            $rejection = [pscustomobject]@{
                Category = $rejectionCategory
                Address = $address
                Mode = $mode
                Type = $type
                ProviderName = $providerName
                Actions = $actions
            }
            $signature = [string]::Join("`0", @(
                    $rejection.Category, $rejection.Address, $rejection.Mode, $rejection.Type,
                    $rejection.ProviderName, $rejection.Actions
                ))
            if ($rejectionSignatures.Add($signature)) {
                $rejectedPlanResources.Add($rejection)
            }
        }
    }
    foreach ($rejection in $rejectedPlanResources) {
        Write-Information (
            "Bicep plan rejection [$($rejection.Category)]: address=$($rejection.Address); mode=$($rejection.Mode); " +
            "type=$($rejection.Type); provider_name=$($rejection.ProviderName); actions=$($rejection.Actions)."
        ) -InformationAction Continue
    }
    if ($rejectedPlanResources.Count -gt 0) {
        throw [System.InvalidOperationException]::new('Bicep plans may only manage dedicated identities, exact federation and individual group edges with their expected providers.')
    }
    $clients = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $principals = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $renames = [ordered]@{}
    foreach ($path in $Modules.Keys) {
        $address = "module.bicep[`"$path`"]"
        $prefix = "$address."
        $resourceChanges = foreach ($change in @($Plan['resource_changes'] | Where-Object { $_['address'].StartsWith($prefix, [StringComparison]::Ordinal) })) {
            if (-not $approvedStateMoveAddresses.Contains($change['address'])) {
                $change
                continue
            }
            $normalizedChange = [ordered]@{}
            foreach ($key in $change.Keys) {
                if ($key -cne 'previous_address') {
                    $normalizedChange[$key] = $change[$key]
                }
            }
            $normalizedChange
        }
        $slice = @{
            errored = $false
            resource_changes = @($resourceChanges)
            planned_values = @{ root_module = @{ resources = @($resources | Where-Object { $_['address'].StartsWith($prefix, [StringComparison]::Ordinal) }) } }
            prior_state = $Plan['prior_state']
        }
        $existingIdentity = if ($ExistingIdentities.Contains($path)) { $ExistingIdentities[$path] } else { $null }
        $name = if ($null -ne $existingIdentity) { $existingIdentity['name'] } else { Get-AvmBicepModuleIdentityName -ModulePath $path }
        $previous = Assert-AvmBamiIdentityPlan -Plan $slice -Settings $Settings -Repository 'Azure/bicep-registry-modules' `
            -RepositoryId $Context.RepositoryId -RepositoryOwnerId $Context.OrganizationId `
            -RepositorySyncRepositoryId $Context.ToolsRepositoryId -EntraGroupNames $Modules[$path] `
            -ModuleAddress $address -IdentityName $name -Environments @('avm-validation') `
            -JobWorkflowRef 'Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main' `
            -WorkflowRef "Azure/bicep-registry-modules/.github/workflows/$($path.Replace('/', '.')).yml@refs/heads/main" -ExistingIdentity $existingIdentity `
            -BicepRegistryFederation -PassThru
        if ($null -ne $previous) {
            $renames[$path] = $previous
            $identity = @($slice.resource_changes | Where-Object { $_['address'] -ceq "${prefix}azapi_resource.identity[0]" })[0]
            if (-not $clients.Add($previous.client_id) -or
                -not $principals.Add($identity['change']['before']['output']['properties']['principalId'])) {
                throw [System.InvalidOperationException]::new('Renamed Bicep identities must have unique previous clients and principals.')
            }
        }
        $plannedIdentity = @($slice.planned_values.root_module.resources | Where-Object { $_['address'] -ceq "${prefix}azapi_resource.identity[0]" })[0]['values']
        if ($null -ne $existingIdentity) {
            if (-not $clients.Add($existingIdentity['client_id']) -or -not $principals.Add($existingIdentity['principal_id'])) {
                throw [System.InvalidOperationException]::new('Bicep modules must not share client IDs or principals.')
            }
            continue
        }
        if ($plannedIdentity['output'] -is [System.Collections.IDictionary]) {
            $properties = $plannedIdentity['output']['properties']
            if (-not $clients.Add($properties['clientId']) -or -not $principals.Add($properties['principalId'])) {
                throw [System.InvalidOperationException]::new('Bicep modules must not share client IDs or principals.')
            }
        }
    }
    if ($PassThru) { return $renames }
}

function Invoke-AvmBicepModuleIdentitySync {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Plan')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $BicepRoot,
        [Parameter(Mandatory)] [string] $TerraformRoot,
        [Parameter(Mandatory)] [string] $MappingPath,
        [string] $IdentityMigrationPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values,
        [Parameter(Mandatory)] [hashtable] $Backend,
        [Parameter(ParameterSetName = 'Plan')] [switch] $PlanOnly = $true,
        [Parameter(Mandatory, ParameterSetName = 'Apply')] [switch] $Apply
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($PSCmdlet.ParameterSetName -ceq 'Plan' -and -not $PlanOnly) {
        throw [System.ArgumentException]::new('Use -Apply explicitly; -PlanOnly:$false is not an apply flag.')
    }
    if ($env:AVM_OFFLINE -ceq '1') {
        throw [System.InvalidOperationException]::new('AVM_OFFLINE=1: refusing Bicep identity provisioning.')
    }
    $settings = Get-AvmBamiSettings -Values $Values
    $state = Resolve-RepositorySyncStateConfiguration -Backend $Backend
    if ($state.ClientId -in @($settings.TEST_BAMI_CONTROLLER_CLIENT_ID, $settings.TEST_BAMI_BICEP_CLIENT_ID)) {
        throw [System.ArgumentException]::new('The state backend identity must be separate from BAMI controller and execution identities.')
    }
    $paths = Get-AvmBicepModulePath -BicepRoot $BicepRoot
    $modules = Resolve-AvmBicepModuleSettings -ModulePaths $paths -Configuration $Configuration
    $configuredExistingIdentities = Resolve-AvmBicepModuleExistingIdentities -ModulePaths $paths -Configuration $Configuration
    $existingIdentities = [ordered]@{}
    foreach ($path in $configuredExistingIdentities.Keys) {
        $existingIdentities[$path] = Resolve-AvmSubscriptionVendingIdentity -ExistingIdentity $configuredExistingIdentities[$path] -Values $Values
        $existingIdentities[$path]['federation_name_key'] = 'bicep-sub-vending'
    }
    $sizeProjection = [ordered]@{}
    foreach ($path in $paths) { $sizeProjection[$path] = [guid]::Empty.ToString() }
    if ([System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $sizeProjection -Compress)) -gt 48KB) {
        throw [System.InvalidOperationException]::new('The discovered module mapping would exceed the 48 KB Actions variable limit.')
    }
    $applying = $PSCmdlet.ParameterSetName -ceq 'Apply' -and $Apply.IsPresent
    $result = [ordered]@{ Status = 'Planned'; PlanOnly = -not $applying; ModuleCount = $paths.Count }
    if (-not $PSCmdlet.ShouldProcess('BAMI Bicep module identities', 'Prepare a verified saved Terraform plan')) {
        $result.Status = 'Preview'
        $result.PlanOnly = $true
        return [pscustomobject]$result
    }
    $publicationContext = $null
    if ($IdentityMigrationPath) {
        $publicationContext = Get-AvmBicepIdentityPublicationContext
        if ([IO.Path]::GetFullPath($IdentityMigrationPath) -ieq [IO.Path]::GetFullPath($MappingPath)) {
            throw [System.ArgumentException]::new('Identity migration evidence and the client-ID mapping require different output paths.')
        }
    }
    foreach ($path in @($MappingPath, $IdentityMigrationPath)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            throw [System.IO.IOException]::new('An identity publication output path already exists; preserve it and choose an unused path.')
        }
    }
    $context = Resolve-AvmBicepIdentitySyncContext
    $environment = Get-RepositorySyncTerraformEnvironment -Root $TerraformRoot -Settings $settings
    $runId = [guid]::NewGuid().ToString('N')
    $inputPath = Join-Path $TerraformRoot "$runId.tfvars.json"
    $planPath = Join-Path $TerraformRoot "$runId.tfplan"
    $parameters = @{
        modules = $modules
        existing_identities = $existingIdentities
        bami_test_settings = ConvertTo-AvmRepositoryTerraformSettings -Settings $settings
        github_repository_id = $context.RepositoryId
        github_organization_id = $context.OrganizationId
        repository_sync_repository_id = $context.ToolsRepositoryId
    }
    try {
        [IO.File]::WriteAllText($inputPath, (ConvertTo-Json -InputObject $parameters -Depth 10), [Text.UTF8Encoding]::new($false))
        $null = Invoke-TerraformInit -terraformModulePath $TerraformRoot -repositoryCreationModeEnabled $false `
            -repoId 'bicep-module-identities' -stateStorageAccountName $state.StorageAccountName `
            -stateContainerName $state.ContainerName -stateTenantId $state.TenantId `
            -stateSubscriptionId $state.SubscriptionId -stateClientId $state.ClientId -environment $environment
        Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment -Quiet -Arguments @(
            'plan', '-input=false', '-no-color', '-lock-timeout=5m', "-var-file=$inputPath", "-out=$planPath"
        )
        $plan = Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment `
            -Arguments @('show', '-json', $planPath) -Json
        $previousIdentities = Assert-AvmBicepIdentityPlan -Plan $plan -Settings $settings -Modules $modules -ExistingIdentities $existingIdentities -Context $context -PassThru
        $changes = @($plan['resource_changes'] | Where-Object { $_['mode'] -ceq 'managed' })
        $creates = @($changes | Where-Object { $_['change']['actions'] -contains 'create' }).Count
        $updates = @($changes | Where-Object { $_['change']['actions'] -contains 'update' }).Count
        $removals = @($changes | Where-Object { $_['change']['actions'] -contains 'delete' }).Count
        Write-Information "Verified Bicep identity plan: $($paths.Count) modules, $creates creates, $updates updates, $removals removals, $($previousIdentities.Count) identity renames." -InformationAction Continue
        Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment -StreamOutput `
            -Arguments @('show', '-no-color', $planPath)
        if (-not $applying) { return [pscustomobject]$result }
        if ($previousIdentities.Count -gt 0 -and -not $IdentityMigrationPath) {
            throw [System.InvalidOperationException]::new('Identity renames require an IdentityMigrationPath for verified mapping publication before applying.')
        }
        if (-not $PSCmdlet.ShouldProcess('BAMI Bicep module identities', 'Apply the verified saved plan and write its client-ID mapping')) {
            $result.Status = 'Preview'
            $result.PlanOnly = $true
            return [pscustomobject]$result
        }
        Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment -StreamOutput `
            -Arguments @('apply', '-input=false', '-no-color', '-lock-timeout=5m', $planPath)
        $identities = Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment `
            -Arguments @('output', '-json', 'test_identities') -Json
        $mapping = ConvertTo-AvmBicepIdentityMapping -Identities $identities -ModulePaths $paths -Settings $settings -ExistingIdentities $existingIdentities
        $json = ConvertTo-AvmBicepModuleClientIdJson -ClientIds $mapping `
            -ForbiddenClientIds @($settings.TEST_BAMI_CONTROLLER_CLIENT_ID, $settings.TEST_BAMI_BICEP_CLIENT_ID)
        if ($IdentityMigrationPath) {
            $replacements = [ordered]@{}
            foreach ($path in $previousIdentities.Keys) { $replacements[$path] = $identities[$path] }
            $migration = [ordered]@{
                schemaVersion = 1
                context = $publicationContext
                before = $previousIdentities
                after = $replacements
            }
            $null = ConvertFrom-AvmBicepIdentityMigration -Migration $migration -ClientIds $mapping -Settings $settings
            [IO.File]::WriteAllText($IdentityMigrationPath, (ConvertTo-Json -InputObject $migration -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
        }
        [IO.File]::WriteAllText($MappingPath, $json, [Text.UTF8Encoding]::new($false))
        $result.Status = 'Applied'
        return [pscustomobject]$result
    }
    finally {
        foreach ($file in @($inputPath, $planPath)) {
            if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
        }
    }
}
