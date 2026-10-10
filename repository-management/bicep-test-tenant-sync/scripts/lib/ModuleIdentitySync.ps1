function Resolve-AvmBicepIdentitySyncContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if ($env:GITHUB_REF -cne 'refs/heads/main') {
        throw [System.InvalidOperationException]::new('Bicep identity sync requires trusted Tools main in GitHub Actions.')
    }
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

function Assert-AvmBicepIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Modules,
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
    $identityNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Modules.Keys) {
        Assert-AvmBicepModulePath -Path $path
        if (-not $identityNames.Add((Get-AvmBicepModuleIdentityName -ModulePath $path))) {
            throw [System.InvalidOperationException]::new('Bicep module paths must produce unique identity names before provisioning.')
        }
        $null = $moduleAddresses.Add("module.bicep[`"$path`"]")
    }
    foreach ($resource in @($Plan['resource_changes']) + $resources) {
        if ($resource -isnot [System.Collections.IDictionary] -or $resource['address'] -isnot [string]) {
            throw [System.InvalidOperationException]::new('Bicep plan resources must have explicit addresses.')
        }
        $match = [regex]::Match($resource['address'], '^(module\.bicep\["[^"]+"\])\.(.+)$')
        if (-not $match.Success -or -not $moduleAddresses.Contains($match.Groups[1].Value)) {
            throw [System.InvalidOperationException]::new('Bicep plan contains a foreign or removed module; identity retirement requires a separate change.')
        }
        $suffix = $match.Groups[2].Value
        $expectedProvider = $null
        if ($resource['mode'] -ceq 'managed' -and $resource['type'] -ceq 'azapi_resource' -and
            $suffix -cin @('azapi_resource.identity', 'azapi_resource.identity_federated_credentials["avm-validation"]', 'azapi_resource.validation_federated_credential')) {
            $expectedProvider = 'registry.terraform.io/azure/azapi'
        }
        elseif ($resource['mode'] -ceq 'managed' -and $resource['type'] -ceq 'azuread_group_member' -and
            $suffix -cmatch '^azuread_group_member\.test_permissions\["(?:[^"\\]|\\.)+"\]$') {
            $expectedProvider = 'registry.terraform.io/hashicorp/azuread'
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
        if (-not $expectedProvider -or $resource['provider_name'] -cne $expectedProvider -or
            ($resource.Contains('previous_address') -and $resource['previous_address'] -cne $resource['address']) -or
            ($resource.Contains('change') -and $null -ne $resource['change']['importing'])) {
            throw [System.InvalidOperationException]::new('Bicep plans may only manage dedicated identities, exact federation and individual group edges with their expected providers.')
        }
    }
    $clients = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $principals = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $renames = [ordered]@{}
    foreach ($path in $Modules.Keys) {
        $address = "module.bicep[`"$path`"]"
        $prefix = "$address."
        $slice = @{
            errored = $false
            resource_changes = @($Plan['resource_changes'] | Where-Object { $_['address'].StartsWith($prefix, [StringComparison]::Ordinal) })
            planned_values = @{ root_module = @{ resources = @($resources | Where-Object { $_['address'].StartsWith($prefix, [StringComparison]::Ordinal) }) } }
            prior_state = $Plan['prior_state']
        }
        $name = Get-AvmBicepModuleIdentityName -ModulePath $path
        $previous = Assert-AvmBamiIdentityPlan -Plan $slice -Settings $Settings -Repository 'Azure/bicep-registry-modules' `
            -RepositoryId $Context.RepositoryId -RepositoryOwnerId $Context.OrganizationId `
            -RepositorySyncRepositoryId $Context.ToolsRepositoryId -EntraGroupNames $Modules[$path] `
            -ModuleAddress $address -IdentityName $name -Environments @('avm-validation') `
            -JobWorkflowRef 'Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main' `
            -WorkflowRef "Azure/bicep-registry-modules/.github/workflows/$($path.Replace('/', '.')).yml@refs/heads/main" -PassThru
        if ($null -ne $previous) {
            $renames[$path] = $previous
            $identity = @($slice.resource_changes | Where-Object { $_['address'] -ceq "${prefix}azapi_resource.identity" })[0]
            if (-not $clients.Add($previous.client_id) -or
                -not $principals.Add($identity['change']['before']['output']['properties']['principalId'])) {
                throw [System.InvalidOperationException]::new('Renamed Bicep identities must have unique previous clients and principals.')
            }
        }
        $plannedIdentity = @($slice.planned_values.root_module.resources | Where-Object { $_['address'] -ceq "${prefix}azapi_resource.identity" })[0]['values']
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
        $previousIdentities = Assert-AvmBicepIdentityPlan -Plan $plan -Settings $settings -Modules $modules -Context $context -PassThru
        $changes = @($plan['resource_changes'] | Where-Object { $_['mode'] -ceq 'managed' })
        $creates = @($changes | Where-Object { $_['change']['actions'] -contains 'create' }).Count
        $updates = @($changes | Where-Object { $_['change']['actions'] -contains 'update' }).Count
        $removals = @($changes | Where-Object { $_['change']['actions'] -contains 'delete' }).Count
        Write-Information "Verified Bicep identity plan: $($paths.Count) modules, $creates creates, $updates updates, $removals removals, $($previousIdentities.Count) identity renames." -InformationAction Continue
        if (-not $applying) { return [pscustomobject]$result }
        if ($previousIdentities.Count -gt 0 -and -not $IdentityMigrationPath) {
            throw [System.InvalidOperationException]::new('Identity renames require an IdentityMigrationPath for verified mapping publication before applying.')
        }
        if (-not $PSCmdlet.ShouldProcess('BAMI Bicep module identities', 'Apply the verified saved plan and write its client-ID mapping')) {
            $result.Status = 'Preview'
            $result.PlanOnly = $true
            return [pscustomobject]$result
        }
        Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment -Quiet `
            -Arguments @('apply', '-input=false', '-no-color', '-lock-timeout=5m', $planPath)
        $identities = Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment `
            -Arguments @('output', '-json', 'test_identities') -Json
        $mapping = ConvertTo-AvmBicepIdentityMapping -Identities $identities -ModulePaths $paths -Settings $settings
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
