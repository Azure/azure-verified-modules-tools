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

function Get-AvmBicepModuleRetirements {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $JobWorkflowPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Modules,
        [Parameter(Mandatory)] [string[]] $MainModulePaths
    )

    $currentPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Modules.Keys) { $null = $currentPaths.Add($path) }
    $mainPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $MainModulePaths) {
        Assert-AvmBicepModulePath -Path $path
        if (-not $mainPaths.Add($path)) {
            throw [System.InvalidOperationException]::new('The Bicep main module inventory contains duplicate paths.')
        }
    }
    $removed = [ordered]@{}
    foreach ($change in $Plan['resource_changes']) {
        if ($change -isnot [System.Collections.IDictionary] -or $change['address'] -isnot [string]) {
            throw [System.InvalidOperationException]::new('Bicep plan resources must have explicit addresses.')
        }
        $match = [regex]::Match($change['address'], '^module\.bicep\["(avm/(?:res|ptn|utl)/[a-z0-9-]+/[a-z0-9-]+)"\]\.')
        if ($match.Success -and -not $currentPaths.Contains($match.Groups[1].Value)) {
            if ($mainPaths.Contains($match.Groups[1].Value)) {
                throw [System.InvalidOperationException]::new('A Bicep main module cannot be retired from the identity inventory.')
            }
            if (-not $removed.Contains($match.Groups[1].Value)) {
                $removed[$match.Groups[1].Value] = [System.Collections.Generic.List[object]]::new()
            }
            $removed[$match.Groups[1].Value].Add($change)
        }
    }

    $retirements = [ordered]@{}
    foreach ($path in $removed.Keys) {
        Assert-AvmBicepModulePath -Path $path
        $identityName = Get-AvmBicepModuleIdentityName -ModulePath $path
        $moduleAddress = "module.bicep[`"$path`"]"
        $identityAddress = "$moduleAddress.azapi_resource.identity[0]"
        $identityChanges = @($removed[$path] | Where-Object address -CEQ $identityAddress)
        if ($identityChanges.Count -ne 1) {
            throw [System.InvalidOperationException]::new('Identity retirement requires exactly one dedicated identity deletion; bootstrap-owned identities require manual intervention.')
        }
        $identityChange = $identityChanges[0]
        $identity = $identityChange['change']['before']
        $parentId = "/subscriptions/$($Settings.TEST_BAMI_ADMIN_SUBSCRIPTION_ID)/resourceGroups/$($Settings.TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME)"
        $identityId = "$parentId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$identityName"
        $identityProperties = if ($identity -is [System.Collections.IDictionary] -and
            $identity['output'] -is [System.Collections.IDictionary]) { $identity['output']['properties'] } else { $null }
        $principal = [guid]::Empty
        $client = [guid]::Empty
        if ($identityChange['mode'] -cne 'managed' -or $identityChange['type'] -cne 'azapi_resource' -or
            $identityChange['provider_name'] -cne 'registry.terraform.io/azure/azapi' -or
            (@($identityChange['change']['actions']) -join ',') -cne 'delete' -or
            $null -ne $identityChange['change']['after'] -or
            $identity -isnot [System.Collections.IDictionary] -or
            $identity['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' -or
            $identity['name'] -cne $identityName -or $identity['parent_id'] -cne $parentId -or
            $identity['id'] -ine $identityId -or
            $identityProperties -isnot [System.Collections.IDictionary] -or
            $identityProperties['tenantId'] -ine $Settings.TEST_BAMI_TENANT_ID -or
            $identityProperties['principalId'] -isnot [string] -or
            -not [guid]::TryParseExact($identityProperties['principalId'], 'D', [ref]$principal) -or
            $principal -eq [guid]::Empty -or
            $identityProperties['clientId'] -isnot [string] -or
            -not [guid]::TryParseExact($identityProperties['clientId'], 'D', [ref]$client) -or
            $client -eq [guid]::Empty -or
            $client.ToString() -in @($Settings.TEST_BAMI_CONTROLLER_CLIENT_ID, $Settings.TEST_BAMI_BICEP_CLIENT_ID)) {
            throw [System.InvalidOperationException]::new('Identity retirement requires a verified BAMI-owned identity and dedicated principal.')
        }

        $seenIdentity = $false
        $seenValidation = $false
        $seenRegistry = $false
        $seenMain = $false
        $seenPullRequestNumbers = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($resourceChange in $removed[$path]) {
            $addressMatch = [regex]::Match($resourceChange['address'], '^' + [regex]::Escape($moduleAddress) + '\.(.+)$')
            if (-not $addressMatch.Success) {
                throw [System.InvalidOperationException]::new('Identity retirement cannot include resources outside the exact module instance.')
            }
            $suffix = $addressMatch.Groups[1].Value
            $actions = @($resourceChange['change']['actions'])
            if ($resourceChange['mode'] -ceq 'data') {
                if ($actions.Count -ne 1 -or $actions[0] -cnotin @('read', 'no-op')) {
                    throw [System.InvalidOperationException]::new('Identity retirement cannot mutate Terraform data resources.')
                }
                continue
            }
            $before = $resourceChange['change']['before']
            if ($resourceChange['mode'] -cne 'managed' -or $actions.Count -ne 1 -or $actions[0] -cne 'delete' -or
                $null -ne $resourceChange['change']['after'] -or
                ($resourceChange.Contains('previous_address') -and $resourceChange['previous_address'] -cne $resourceChange['address']) -or
                $null -ne $resourceChange['change']['importing'] -or
                $before -isnot [System.Collections.IDictionary]) {
                throw [System.InvalidOperationException]::new('Identity retirement may only delete verified resources owned by its dedicated identity.')
            }

            if ($suffix -ceq 'azapi_resource.identity[0]') {
                if ($seenIdentity) {
                    throw [System.InvalidOperationException]::new('Identity retirement contains an ambiguous identity resource.')
                }
                $seenIdentity = $true
                continue
            }

            if ($resourceChange['type'] -ceq 'azapi_resource' -and
                $resourceChange['provider_name'] -ceq 'registry.terraform.io/azure/azapi') {
                $credentialName = $null
                $expression = $null
                $workflowRef = $null
                $credentialMatch = [regex]::Match($suffix, '^azapi_resource\.federated_credentials\["module-avm-validation-pr-([1-9][0-9]{0,9})"\]$')
                if ($credentialMatch.Success) {
                    $number = $credentialMatch.Groups[1].Value
                    if (-not $seenPullRequestNumbers.Add($number)) {
                        throw [System.InvalidOperationException]::new('Identity retirement contains duplicate pull-request federation.')
                    }
                    $credentialName = "$identityName-fic-m-avm-validation-pr-$number"
                    $workflowRef = "Azure/bicep-registry-modules/.github/workflows/$($path.Replace('/', '.')).yml@refs/pull/$number/merge"
                    $expression = Get-AvmBamiModuleFederationExpression -RepositoryOwnerId $Context.OrganizationId `
                        -RepositoryId $Context.RepositoryId -Environment 'avm-validation' `
                        -JobWorkflowPath $JobWorkflowPath -WorkflowRef $workflowRef
                }
                elseif ($suffix -ceq 'azapi_resource.federated_credentials["module-avm-validation"]') {
                    if ($seenMain) {
                        throw [System.InvalidOperationException]::new('Identity retirement contains duplicate main federation.')
                    }
                    $seenMain = $true
                    $credentialName = "$identityName-fic-m-avm-validation"
                    $workflowRef = "Azure/bicep-registry-modules/.github/workflows/$($path.Replace('/', '.')).yml@refs/heads/main"
                    $expression = Get-AvmBamiModuleFederationExpression -RepositoryOwnerId $Context.OrganizationId `
                        -RepositoryId $Context.RepositoryId -Environment 'avm-validation' `
                        -JobWorkflowPath $JobWorkflowPath -WorkflowRef $workflowRef
                }
                elseif ($suffix -ceq 'azapi_resource.federated_credentials["validation"]') {
                    $credentialName = "$identityName-fic-v-avm-validation"
                    $seenValidation = $true
                    $expression = Get-AvmBamiFederationExpression `
                        -SubjectPattern "repository_owner_id:$($Context.OrganizationId):repository_id:$($Context.ToolsRepositoryId):environment:avm-validation" `
                        -RepositoryOwnerId $Context.OrganizationId -RepositoryId $Context.ToolsRepositoryId
                }
                elseif ($suffix -ceq 'azapi_resource.federated_credentials["bicep-registry"]') {
                    $credentialName = "$identityName-fic-r-avm-validation"
                    $seenRegistry = $true
                    $expression = Get-AvmBamiFederationExpression `
                        -SubjectPattern "repository_owner_id:$($Context.OrganizationId):repository_id:$($Context.RepositoryId):environment:avm-validation" `
                        -RepositoryOwnerId $Context.OrganizationId -RepositoryId $Context.RepositoryId
                }
                if ($null -eq $credentialName -or $before['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-01-31-preview' -or
                    $before['name'] -cne $credentialName -or $before['parent_id'] -ine $identityId -or
                    $before['id'] -ine "$identityId/federatedIdentityCredentials/$credentialName" -or
                    -not (Test-AvmBamiModuleFederation -Values $before -Expression $expression -WorkflowRef $workflowRef)) {
                    throw [System.InvalidOperationException]::new('Identity retirement contains foreign or widened federation.')
                }
                continue
            }

            if ($resourceChange['type'] -ceq 'azuread_group_member' -and
                $resourceChange['provider_name'] -ceq 'registry.terraform.io/hashicorp/azuread' -and
                $suffix -cmatch '^azuread_group_member\.test_permissions\["(?:[^"\\]|\\.)+"\]$') {
                $groupId = [guid]::Empty
                if ($before['member_object_id'] -isnot [string] -or $before['member_object_id'] -ine $principal.ToString() -or
                    $before['group_object_id'] -isnot [string] -or
                    -not [guid]::TryParseExact($before['group_object_id'], 'D', [ref]$groupId) -or $groupId -eq [guid]::Empty) {
                    throw [System.InvalidOperationException]::new('Identity retirement may remove only valid group edges for its dedicated principal.')
                }
                continue
            }
            throw [System.InvalidOperationException]::new('Identity retirement contains an unsupported managed resource.')
        }
        if (-not $seenIdentity -or -not $seenValidation -or -not $seenRegistry -or
            (-not $seenMain -and $seenPullRequestNumbers.Count -eq 0)) {
            throw [System.InvalidOperationException]::new('Identity retirement requires its full identity and module federation resource set.')
        }
        $retirements[$path] = $client.ToString()
    }
    return $retirements
}

function Assert-AvmBicepIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Modules,
        [AllowEmptyCollection()] [System.Collections.IDictionary] $ExistingIdentities = @{},
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $JobWorkflowPath,
        [AllowEmptyCollection()] [string[]] $MainModulePaths = @(),
        [AllowEmptyCollection()] [System.Collections.IDictionary] $PullRequestNumbers = @{},
        [switch] $PassThru
    )

    if ($Modules.Count -eq 0 -or ($Plan.Contains('errored') -and $Plan['errored'] -ne $false) -or
        ($Plan.Contains('complete') -and $Plan['complete'] -ne $true) -or
        $Plan['resource_changes'] -isnot [System.Collections.IList] -or
        $Plan['planned_values'] -isnot [System.Collections.IDictionary] -or
        $Plan['planned_values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Bicep provisioning requires a complete, nonempty Terraform plan and module inventory.')
    }
    if ($MainModulePaths.Count -eq 0 -and $PullRequestNumbers.Count -eq 0) {
        $MainModulePaths = @($Modules.Keys)
    }
    $identityNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Modules.Keys) {
        Assert-AvmBicepModulePath -Path $path
        $identityName = if ($ExistingIdentities.Contains($path)) {
            $ExistingIdentities[$path]['name']
        }
        else {
            Get-AvmBicepModuleIdentityName -ModulePath $path
        }
        if (-not $identityNames.Add($identityName)) {
            throw [System.InvalidOperationException]::new('Bicep module paths must produce unique identity names before provisioning.')
        }
    }
    $retiredModules = Get-AvmBicepModuleRetirements -Plan $Plan -Settings $Settings -Context $Context `
        -JobWorkflowPath $JobWorkflowPath -Modules $Modules -MainModulePaths $MainModulePaths
    $mainPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $MainModulePaths) {
        Assert-AvmBicepModulePath -Path $path
        if (-not $mainPaths.Add($path) -or -not $Modules.Contains($path)) {
            throw [System.InvalidOperationException]::new('Every main Bicep module must remain in the identity inventory.')
        }
    }
    foreach ($path in $PullRequestNumbers.Keys) {
        if (-not $Modules.Contains($path) -or $mainPaths.Contains($path) -or
            @($PullRequestNumbers[$path] | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[1-9][0-9]{0,9}$' } | Select-Object -Unique).Count -gt 0) {
            throw [System.InvalidOperationException]::new('Preview identity metadata must be limited to valid non-main modules and open pull requests.')
        }
    }
    foreach ($path in $Modules.Keys) {
        if (-not $mainPaths.Contains($path) -and -not $PullRequestNumbers.Contains($path)) {
            throw [System.InvalidOperationException]::new('Every non-main identity must be owned by at least one open same-repository pull request.')
        }
    }
    $retiredPrefixes = @($retiredModules.Keys | ForEach-Object { "module.bicep[`"$_`"]." })
    $activePlan = [ordered]@{}
    foreach ($key in $Plan.Keys) { $activePlan[$key] = $Plan[$key] }
    $activePlan['resource_changes'] = @($Plan['resource_changes'] | Where-Object {
            $address = $_['address']
            -not ($address -is [string] -and @($retiredPrefixes | Where-Object { $address.StartsWith($_, [StringComparison]::Ordinal) }).Count -gt 0)
        })
    $resources = @(Get-AvmTerraformPlannedResource -Module $Plan['planned_values']['root_module'])
    $moduleAddresses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rejectedPlanResources = [System.Collections.Generic.List[object]]::new()
    $rejectionSignatures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Modules.Keys) {
        Assert-AvmBicepModulePath -Path $path
        $null = $moduleAddresses.Add("module.bicep[`"$path`"]")
    }
    foreach ($resource in @($activePlan['resource_changes']) + $resources) {
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
        $pullRequestCredential = [regex]::Match(
            $suffix,
            '^azapi_resource\.federated_credentials\["module-avm-validation-pr-([1-9][0-9]{0,9})"\]$'
        )
        if ($resource['mode'] -ceq 'managed' -and $resource['type'] -ceq 'azapi_resource' -and
            $suffix -cin @(
                'azapi_resource.identity[0]', 'azapi_resource.federated_credentials["module-avm-validation"]',
                'azapi_resource.federated_credentials["validation"]', 'azapi_resource.federated_credentials["bicep-registry"]',
                'azapi_resource.identity_federated_credentials["avm-validation"]',
                'azapi_resource.validation_federated_credential[0]', 'azapi_resource.validation_federated_credential',
                'azapi_resource.bicep_registry_federated_credential[0]'
            ) -or ($resource['mode'] -ceq 'managed' -and $resource['type'] -ceq 'azapi_resource' -and $pullRequestCredential.Success)) {
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
        $isIdentityStateMove = $resource['address'] -is [string] -and
            $resource['address'].EndsWith('.azapi_resource.identity[0]', [StringComparison]::Ordinal) -and
            $resource.Contains('previous_address') -and
            $resource['previous_address'] -ceq $resource['address'].Substring(0, $resource['address'].Length - 3) -and
            (@($resource['change']['actions']) -join ',') -ceq 'no-op'
        if (-not $expectedProvider -or $resource['provider_name'] -cne $expectedProvider -or
            ($resource.Contains('previous_address') -and $resource['previous_address'] -cne $resource['address'] -and -not $isIdentityStateMove) -or
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
        $resourceChanges = @($activePlan['resource_changes'] | Where-Object {
                $_['address'].StartsWith($prefix, [StringComparison]::Ordinal)
            })
        $slice = @{
            errored = $false
            resource_changes = @($resourceChanges)
            planned_values = @{ root_module = @{ resources = @($resources | Where-Object { $_['address'].StartsWith($prefix, [StringComparison]::Ordinal) }) } }
            prior_state = $Plan['prior_state']
        }
        $existingIdentity = if ($ExistingIdentities.Contains($path)) { $ExistingIdentities[$path] } else { $null }
        $name = if ($null -ne $existingIdentity) { $existingIdentity['name'] } else { Get-AvmBicepModuleIdentityName -ModulePath $path }
        $isPreview = $PullRequestNumbers.Contains($path)
        if ($isPreview -and $null -ne $existingIdentity) {
            throw [System.InvalidOperationException]::new('Preview modules cannot reuse bootstrap-owned identities.')
        }
        $modulePullRequestNumbers = if ($isPreview) { @($PullRequestNumbers[$path] | Sort-Object { [long]$_ }) } else { @() }
        if ($null -eq $existingIdentity) {
            $plannedIdentityResources = @($slice.planned_values.root_module.resources |
                Where-Object { $_['address'] -ceq "${prefix}azapi_resource.identity[0]" })
            if ($plannedIdentityResources.Count -ne 1 -or $plannedIdentityResources[0]['values'] -isnot [System.Collections.IDictionary]) {
                throw [System.InvalidOperationException]::new('Every dedicated Bicep module identity must appear exactly once in planned values.')
            }
            $plannedIdentity = $plannedIdentityResources[0]['values']
            $actualTags = if ($plannedIdentity['body'] -is [System.Collections.IDictionary]) { $plannedIdentity['body']['tags'] } else { $null }
            if ($null -ne $actualTags -and
                ($actualTags -isnot [System.Collections.IDictionary] -or $actualTags.Count -gt 0)) {
                throw [System.InvalidOperationException]::new('Bicep identity plans must not introduce identity tags.')
            }
            $identityChange = @($slice.resource_changes | Where-Object { $_['address'] -ceq "${prefix}azapi_resource.identity[0]" })[0]
            $beforeTags = if ($null -ne $identityChange -and $identityChange['change']['before'] -is [System.Collections.IDictionary] -and
                $identityChange['change']['before']['body'] -is [System.Collections.IDictionary]) {
                $identityChange['change']['before']['body']['tags']
            }
            else { $null }
            if ($null -ne $identityChange -and $null -ne $identityChange['change']['before']) {
                $hasPreviewTag = $beforeTags -is [System.Collections.IDictionary] -and
                    $beforeTags.Count -eq 1 -and $beforeTags['avm-bicep-identity-scope'] -ceq 'pull-request'
                $hasNoTags = $null -eq $beforeTags -or
                    ($beforeTags -is [System.Collections.IDictionary] -and $beforeTags.Count -eq 0)
                if (-not $hasPreviewTag -and -not $hasNoTags) {
                    throw [System.InvalidOperationException]::new('Existing Bicep identity tags are not owned by the module identity synchronizer.')
                }
            }
        }
        $previous = Assert-AvmBamiIdentityPlan -Plan $slice -Settings $Settings -Repository 'Azure/bicep-registry-modules' `
            -RepositoryId $Context.RepositoryId -RepositoryOwnerId $Context.OrganizationId `
            -RepositorySyncRepositoryId $Context.ToolsRepositoryId -EntraGroupNames $Modules[$path] `
            -ModuleAddress $address -IdentityName $name -Environments @('avm-validation') `
            -JobWorkflowPath $JobWorkflowPath `
            -WorkflowRef "Azure/bicep-registry-modules/.github/workflows/$($path.Replace('/', '.')).yml@refs/heads/main" `
            -PullRequestNumbers $modulePullRequestNumbers -IncludeMainWorkflow:(-not $isPreview) -ExistingIdentity $existingIdentity `
            -BicepRegistryFederation -PassThru
        if ($null -ne $previous) {
            $renames[$path] = $previous
            $identity = @($slice.resource_changes | Where-Object { $_['address'] -ceq "${prefix}azapi_resource.identity[0]" })[0]
            if (-not $clients.Add($previous.client_id) -or
                -not $principals.Add($identity['change']['before']['output']['properties']['principalId'])) {
                throw [System.InvalidOperationException]::new('Renamed Bicep identities must have unique previous clients and principals.')
            }
        }
        if ($null -ne $existingIdentity) {
            if (-not $clients.Add($existingIdentity['client_id']) -or -not $principals.Add($existingIdentity['principal_id'])) {
                throw [System.InvalidOperationException]::new('Bicep modules must not share client IDs or principals.')
            }
            continue
        }
        $plannedIdentity = @($slice.planned_values.root_module.resources | Where-Object { $_['address'] -ceq "${prefix}azapi_resource.identity[0]" })[0]['values']
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
    $mainPaths = Get-AvmBicepModulePath -BicepRoot $BicepRoot
    $modules = Resolve-AvmBicepModuleSettings -ModulePaths $mainPaths -Configuration $Configuration
    $jobWorkflowPath = Resolve-AvmBicepModuleJobWorkflowPath -Configuration $Configuration
    $configuredExistingIdentities = Resolve-AvmBicepModuleExistingIdentities -ModulePaths $mainPaths -Configuration $Configuration
    foreach ($path in $configuredExistingIdentities.Keys) {
        $null = Resolve-AvmSubscriptionVendingIdentity -ExistingIdentity $configuredExistingIdentities[$path] -Values $Values
    }
    $sizeProjection = [ordered]@{}
    foreach ($path in $mainPaths) { $sizeProjection[$path] = [guid]::Empty.ToString() }
    if ([System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $sizeProjection -Compress)) -gt 48KB) {
        throw [System.InvalidOperationException]::new('The discovered module mapping would exceed the 48 KB Actions variable limit.')
    }
    $applying = $PSCmdlet.ParameterSetName -ceq 'Apply' -and $Apply.IsPresent
    $result = [ordered]@{ Status = 'Planned'; PlanOnly = -not $applying; ModuleCount = $mainPaths.Count }
    if (-not $PSCmdlet.ShouldProcess('BAMI Bicep module identities', 'Prepare a verified saved Terraform plan')) {
        $result.Status = 'Preview'
        $result.PlanOnly = $true
        return [pscustomobject]$result
    }
    $publicationContext = $null
    if ($applying -and $IdentityMigrationPath) {
        $publicationContext = Get-AvmBicepIdentityPublicationContext
        if ([IO.Path]::GetFullPath($IdentityMigrationPath) -ieq [IO.Path]::GetFullPath($MappingPath)) {
            throw [System.ArgumentException]::new('Identity migration evidence and the client-ID mapping require different output paths.')
        }
    }
    $context = Resolve-AvmBicepIdentitySyncContext
    $pullRequestNumbers = Get-AvmBicepOpenPullRequestModuleNumbers -MainModulePaths $mainPaths -RepositoryId $context.RepositoryId
    $paths = @(@($mainPaths) + @($pullRequestNumbers.Keys) | Sort-Object -CaseSensitive -Unique)
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
    $result.ModuleCount = $paths.Count
    foreach ($path in @($MappingPath, $IdentityMigrationPath)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            throw [System.IO.IOException]::new('An identity publication output path already exists; preserve it and choose an unused path.')
        }
    }
    $environment = Get-RepositorySyncTerraformEnvironment -Root $TerraformRoot -Settings $settings
    $lockRecovery = @{
        storageAccountName = $state.StorageAccountName
        containerName = $state.ContainerName
        subscriptionId = $state.SubscriptionId
        tenantId = $state.TenantId
        clientId = $state.ClientId
        blobName = 'bicep-module-identities.tfstate'
        repository = 'Azure/bicep-registry-modules'
    }
    $runId = [guid]::NewGuid().ToString('N')
    $inputPath = Join-Path $TerraformRoot "$runId.tfvars.json"
    $planPath = Join-Path $TerraformRoot "$runId.tfplan"
    $parameters = @{
        modules = $modules
        pull_request_numbers = $pullRequestNumbers
        existing_identities = $existingIdentities
        bami_test_settings = ConvertTo-AvmRepositoryTerraformSettings -Settings $settings
        github_repository_id = $context.RepositoryId
        github_organization_id = $context.OrganizationId
        repository_sync_repository_id = $context.ToolsRepositoryId
        github_job_workflow_path = $jobWorkflowPath
    }
    try {
        [IO.File]::WriteAllText($inputPath, (ConvertTo-Json -InputObject $parameters -Depth 10), [Text.UTF8Encoding]::new($false))
        $null = Invoke-TerraformInit -terraformModulePath $TerraformRoot -repositoryCreationModeEnabled $false `
            -repoId 'bicep-module-identities' -stateStorageAccountName $state.StorageAccountName `
            -stateContainerName $state.ContainerName -stateTenantId $state.TenantId `
            -stateSubscriptionId $state.SubscriptionId -stateClientId $state.ClientId -environment $environment
        Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment -LockRecovery $lockRecovery -Quiet -Arguments @(
            'plan', '-input=false', '-no-color', '-lock-timeout=5m', "-var-file=$inputPath", "-out=$planPath"
        )
        $plan = Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment `
            -Arguments @('show', '-json', $planPath) -Json
        $previousIdentities = Assert-AvmBicepIdentityPlan -Plan $plan -Settings $settings -Modules $modules `
            -ExistingIdentities $existingIdentities -Context $context -JobWorkflowPath $jobWorkflowPath `
            -MainModulePaths $mainPaths -PullRequestNumbers $pullRequestNumbers -PassThru
        $retiredIdentities = Get-AvmBicepModuleRetirements -Plan $plan -Settings $settings -Context $context `
            -JobWorkflowPath $jobWorkflowPath -Modules $modules -MainModulePaths $mainPaths
        if ($retiredIdentities.Count -gt 0) {
            Assert-AvmBicepSourceInventory -BicepRoot $BicepRoot -MainModulePaths $mainPaths
        }
        $changes = @($plan['resource_changes'] | Where-Object { $_['mode'] -ceq 'managed' })
        $creates = @($changes | Where-Object { $_['change']['actions'] -contains 'create' }).Count
        $updates = @($changes | Where-Object { $_['change']['actions'] -contains 'update' }).Count
        $removals = @($changes | Where-Object { $_['change']['actions'] -contains 'delete' }).Count
        Write-Information "Verified Bicep identity plan: $($paths.Count) modules, $creates creates, $updates updates, $removals removals, $($previousIdentities.Count) identity renames." -InformationAction Continue
        Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment -StreamOutput `
            -Arguments @('show', '-no-color', $planPath)
        if (-not $applying) { return [pscustomobject]$result }
        if (($previousIdentities.Count -gt 0 -or $retiredIdentities.Count -gt 0) -and -not $IdentityMigrationPath) {
            throw [System.InvalidOperationException]::new('Identity changes require an IdentityMigrationPath for verified mapping publication before applying.')
        }
        if (-not $PSCmdlet.ShouldProcess('BAMI Bicep module identities', 'Apply the verified saved plan and write its client-ID mapping')) {
            $result.Status = 'Preview'
            $result.PlanOnly = $true
            return [pscustomobject]$result
        }
        if ($retiredIdentities.Count -gt 0) {
            Assert-AvmBicepSourceInventory -BicepRoot $BicepRoot -MainModulePaths $mainPaths
            $currentPullRequests = Get-AvmBicepOpenPullRequestModuleNumbers -MainModulePaths $mainPaths -RepositoryId $context.RepositoryId
            foreach ($path in $retiredIdentities.Keys) {
                if ($currentPullRequests.Contains($path)) {
                    throw [System.InvalidOperationException]::new('A retired Bicep module is now present in an open pull request; replan before applying.')
                }
            }
        }
        Invoke-RepositorySyncTerraform -Root $TerraformRoot -Environment $environment -LockRecovery $lockRecovery -StreamOutput `
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
                retired = $retiredIdentities
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
