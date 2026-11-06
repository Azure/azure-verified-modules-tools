#Requires -Version 7.4

. (Join-Path $PSScriptRoot '..' '..' '..' 'shared' 'TestTenant.ps1')
. (Join-Path $PSScriptRoot 'RetryHelpers.ps1')
. (Join-Path $PSScriptRoot 'TerraformOperations.ps1')
. (Join-Path $PSScriptRoot 'RepositoryDiscovery.ps1')

function Assert-AvmBamiRepositorySyncRunContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool] $PlanOnly,
        [bool] $AllowExampleRepositoryBranchApply = $false,
        [string] $RepoId,
        [object] $ResolvedRepository
    )

    $manualBranchPreview = $PlanOnly -and
        $env:GITHUB_EVENT_NAME -ceq 'workflow_dispatch' -and
        $env:GITHUB_REF -cmatch '^refs/heads/[^\r\n]+$'
    $exampleRepositoryBranchApply = -not $PlanOnly -and $AllowExampleRepositoryBranchApply
    if ($env:GITHUB_ACTIONS -cne 'true' -or
        $env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools') {
        throw [System.InvalidOperationException]::new(
            'BAMI repository sync requires trusted Azure/azure-verified-modules-tools main in GitHub Actions, except for explicitly permitted manual branch runs.')
    }
    if ($exampleRepositoryBranchApply) {
        if ($env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or
            $env:GITHUB_REF -cnotmatch '^refs/heads/[^/\r\n][^\r\n]*$' -or
            $env:GITHUB_REF -ceq 'refs/heads/main' -or
            $RepoId -cne 'avm-ptn-example-repo' -or
            $null -eq $ResolvedRepository -or
            $ResolvedRepository.full_name -cne 'Azure/terraform-azurerm-avm-ptn-example-repo' -or
            $ResolvedRepository.fork -ne $false -or
            $ResolvedRepository.owner.login -cne 'Azure' -or
            [string]$ResolvedRepository.owner.id -cnotmatch '^[1-9][0-9]*$') {
            throw [System.InvalidOperationException]::new(
                'The branch-apply opt-in requires one resolved Azure avm-ptn-example-repo target from a non-main manual tools workflow.')
        }
        return
    }
    if ($AllowExampleRepositoryBranchApply -or
        ($env:GITHUB_REF -cne 'refs/heads/main' -and -not $manualBranchPreview)) {
        throw [System.InvalidOperationException]::new(
            'BAMI repository sync requires trusted Azure/azure-verified-modules-tools main in GitHub Actions, except for manual plan-only branch previews.')
    }
}

function Resolve-AvmRepositorySyncFederationContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()] [string] $RepositoryId = $env:GITHUB_REPOSITORY_ID)

    if ($env:GITHUB_ACTIONS -cne 'true' -or
        $env:GITHUB_REPOSITORY -cne 'Azure/azure-verified-modules-tools' -or
        $env:GITHUB_REPOSITORY_ID -cnotmatch '^[1-9][0-9]*$' -or
        $RepositoryId -cne $env:GITHUB_REPOSITORY_ID) {
        throw [System.InvalidOperationException]::new('Validation federation requires the trusted tools repository and its positive GitHub Actions repository ID.')
    }
    $toolsRepository = Invoke-RepositoryGitHubApi -Endpoint 'repos/Azure/azure-verified-modules-tools'
    if ($null -eq $toolsRepository -or
        $toolsRepository.full_name -cne 'Azure/azure-verified-modules-tools' -or
        $toolsRepository.fork -ne $false -or
        $toolsRepository.owner.login -cne 'Azure' -or
        [string]$toolsRepository.id -cne $RepositoryId -or
        [string]$toolsRepository.owner.id -cnotmatch '^[1-9][0-9]*$') {
        throw [System.InvalidOperationException]::new('GitHub did not confirm the trusted tools repository and its immutable ID.')
    }
    return [pscustomobject]@{
        RepositoryId = $RepositoryId
        OrganizationId = [string]$toolsRepository.owner.id
    }
}

function Resolve-RepositoryTestTenantSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $TestTenant,
        [System.Collections.IDictionary] $BamiValues = @{}
    )

    if ($TestTenant -isnot [string] -or $TestTenant -cnotin @('legacy', 'bami')) {
        throw [System.ArgumentException]::new('testTenant must be exactly legacy or bami.')
    }
    if ($TestTenant -ceq 'legacy') {
        throw [System.InvalidOperationException]::new('The legacy test tenant is retired. Normal repository sync requires testTenant bami.')
    }
    $settings = Get-AvmBamiSettings -Values $BamiValues
    $null = Get-AvmGeneralTestSubscription -Settings $settings
    return [pscustomobject]@{ SelectedTestTenant = $TestTenant; TestTenant = $TestTenant; Status = 'Ready'; Settings = $settings }
}

function Get-AvmTerraformPlannedResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Module)

    if ($Module.Contains('resources')) {
        foreach ($resource in $Module['resources']) {
            $resource
        }
    }
    if ($Module.Contains('child_modules')) {
        foreach ($child in $Module['child_modules']) {
            Get-AvmTerraformPlannedResource -Module $child
        }
    }
}

function Get-AvmTerraformPlanDataResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Plan)

    # Completed reads are in the refreshed prior state; planned values contain deferred reads.
    $priorState = $Plan['prior_state']
    if ($priorState -isnot [System.Collections.IDictionary] -or
        $priorState['values'] -isnot [System.Collections.IDictionary] -or
        $priorState['values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Candidate membership requires refreshed Terraform data-source evidence.')
    }
    foreach ($resource in @(Get-AvmTerraformPlannedResource -Module $priorState['values']['root_module'])) {
        if ($resource['mode'] -cne 'data') { continue }
        $changes = @($Plan['resource_changes'] | Where-Object { $_['address'] -ceq $resource['address'] })
        if ($changes.Count -gt 1 -or ($changes.Count -eq 1 -and
            ($changes[0]['mode'] -cne 'data' -or $changes[0]['type'] -cne $resource['type'] -or
                (@($changes[0]['change']['actions']) -join ',') -cne 'no-op'))) {
            throw [System.InvalidOperationException]::new("Candidate membership requires completed plan-time data reads; '$($resource['address'])' has a pending or ambiguous change.")
        }
        $resource
    }
}

function Test-AvmTerraformPlanUnknownField {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Change,
        [Parameter(Mandatory)] [string] $Path
    )

    $unknown = $Change['after_unknown']
    foreach ($segment in $Path.Split('.')) {
        if ($unknown -eq $true) { return $true }
        if ($unknown -isnot [System.Collections.IDictionary]) { return $false }
        $unknown = $unknown[$segment]
    }
    return $unknown -eq $true
}

function Get-AvmBamiOwnerAssignmentName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings
    )

    # Match Terraform's uuidv5("url", ...) assignment identifier.
    $namespace = [byte[]]@(0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8)
    $name = $Repository.Replace('/', '') + $Settings['TEST_BAMI_MANAGEMENT_GROUP_ID'] + $Settings['TEST_BAMI_TENANT_ID']
    $hash = [System.Security.Cryptography.SHA1]::HashData([byte[]]($namespace + [System.Text.Encoding]::UTF8.GetBytes($name)))
    $hash[6] = ($hash[6] -band 0x0f) -bor 0x50
    $hash[8] = ($hash[8] -band 0x3f) -bor 0x80
    $hex = [System.Convert]::ToHexString([byte[]]$hash[0..15]).ToLowerInvariant()
    return '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}

function Get-AvmBamiModuleFederationExpression {
    param(
        [Parameter(Mandatory)] [string] $RepositoryOwnerId,
        [Parameter(Mandatory)] [string] $RepositoryId,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $JobWorkflowPath,
        [string] $WorkflowRef
    )

    $subject = "repository_owner_id:$RepositoryOwnerId`:repository_id:$RepositoryId`:environment:$Environment`:*"
    $clauses = @(
        "claims['sub'] matches '$subject'",
        "claims['job_workflow_ref'] matches '$JobWorkflowPath@*'"
    )
    if ($WorkflowRef) {
        $caller = [regex]::Match($WorkflowRef,
            '\A([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+)/\.github/workflows/([A-Za-z0-9][A-Za-z0-9_.-]*\.ya?ml@refs/heads/main)\z')
        if (-not $caller.Success) {
            throw [System.ArgumentException]::new('Caller federation requires an exact fully qualified trusted-main workflow.')
        }
        $patterns = @(
            "*:workflow_ref:$($caller.Groups[1].Value)/.github/workflows/*"
            "*:workflow_ref:*/.github/workflows/$($caller.Groups[2].Value)"
        )
        foreach ($pattern in $patterns) {
            if ($pattern.Length -gt 128) {
                throw [System.ArgumentException]::new('Caller federation subject comparands must be at most 128 characters.')
            }
            $clauses += "claims['sub'] matches '$pattern'"
        }
    }
    $clauses += @(
        "claims['repository_id'] eq '$RepositoryId'",
        "claims['repository_owner_id'] eq '$RepositoryOwnerId'"
    )
    return $clauses -join ' and '
}

function Get-AvmBamiFederationExpression {
    param(
        [Parameter(Mandatory)] [string] $SubjectPattern,
        [Parameter(Mandatory)] [string] $RepositoryOwnerId,
        [Parameter(Mandatory)] [string] $RepositoryId
    )

    return @(
        "claims['sub'] matches '$SubjectPattern'",
        "claims['repository_id'] eq '$RepositoryId'",
        "claims['repository_owner_id'] eq '$RepositoryOwnerId'"
    ) -join ' and '
}

function Get-AvmBamiLegacyModuleSubjectPattern {
    param(
        [Parameter(Mandatory)] [string] $RepositoryOwnerId,
        [Parameter(Mandatory)] [string] $RepositoryId,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $JobWorkflowPath,
        [string] $WorkflowRef
    )

    $prefix = "repository_owner_id:$RepositoryOwnerId`:repository_id:$RepositoryId`:environment:$Environment`:job_workflow_ref:"
    $suffix = if ($WorkflowRef) { ":workflow_ref:$WorkflowRef" } else { '' }
    return '\A' + [regex]::Escape($prefix) +
        [regex]::Escape($JobWorkflowPath) + '@(?:refs/[^\s:]+|[0-9a-fA-F]{40})' +
        [regex]::Escape($suffix) + '\z'
}

function Test-AvmBamiModuleFederation {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Values,
        [Parameter(Mandatory)] [string] $Expression,
        [string] $LegacySubjectPattern,
        [string] $WorkflowRef,
        [switch] $AllowLegacy
    )

    if ($Values['body'] -isnot [System.Collections.IDictionary] -or
        $Values['body']['properties'] -isnot [System.Collections.IDictionary]) {
        return $false
    }
    $properties = $Values['body']['properties']
    $audiences = @($properties['audiences'])
    $claimExpression = $properties['claimsMatchingExpression']
    $previousExpression = $null
    if ($AllowLegacy -and $WorkflowRef) {
        $clauses = @($Expression -split ' and ')
        if ($clauses.Count -eq 6) {
            $previousExpression = (@($clauses[0..1]) +
                "claims['sub'] matches '*:workflow_ref:$WorkflowRef'" + @($clauses[4..5])) -join ' and '
        }
    }
    if ($Values['type'] -ceq 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-01-31-preview' -and
        $properties.Count -eq 3 -and $properties['issuer'] -ceq 'https://token.actions.githubusercontent.com' -and
        $audiences.Count -eq 1 -and $audiences[0] -ceq 'api://AzureADTokenExchange' -and
        $claimExpression -is [System.Collections.IDictionary] -and $claimExpression.Count -eq 2 -and
        $claimExpression['languageVersion'] -eq 1 -and
        ($claimExpression['value'] -ceq $Expression -or
            ($null -ne $previousExpression -and $claimExpression['value'] -ceq $previousExpression))) {
        return $true
    }
    return $AllowLegacy -and
        $Values['type'] -ceq 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview' -and
        $properties.Count -eq 3 -and $properties['issuer'] -ceq 'https://token.actions.githubusercontent.com' -and
        $audiences.Count -eq 1 -and $audiences[0] -ceq 'api://AzureADTokenExchange' -and
        $properties['subject'] -is [string] -and $properties['subject'] -cmatch $LegacySubjectPattern
}

function Test-AvmRetiredExamplesTestFederationChange {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Change,
        [Parameter(Mandatory)] [string] $ModuleAddress,
        [Parameter(Mandatory)] [string] $IdentityName,
        [AllowNull()] [string] $IdentityId
    )

    $before = $Change['change']['before']
    $address = "$ModuleAddress.azapi_resource.federated_credentials[`"module-examples-test`"]"
    $name = "$IdentityName-fic-m-examples-test"
    return $ModuleAddress -cmatch '^module\.(azure|bami\[0\])$' -and
        -not [string]::IsNullOrEmpty($IdentityId) -and
        $Change['address'] -ceq $address -and
        $Change['mode'] -ceq 'managed' -and $Change['type'] -ceq 'azapi_resource' -and
        $Change['provider_name'] -ceq 'registry.terraform.io/azure/azapi' -and
        (@($Change['change']['actions']) -join ',') -ceq 'delete' -and
        $null -eq $Change['change']['after'] -and $null -eq $Change['change']['importing'] -and
        (-not $Change.Contains('previous_address') -or $Change['previous_address'] -ceq $address) -and
        $before -is [System.Collections.IDictionary] -and
        $before['type'] -ceq 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-01-31-preview' -and
        $before['name'] -ceq $name -and $before['parent_id'] -ieq $IdentityId -and
        ($null -eq $before['id'] -or $before['id'] -ieq "$IdentityId/federatedIdentityCredentials/$name")
}

function Assert-AvmExternalBamiIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $RepositoryId,
        [Parameter(Mandatory)] [string] $RepositoryOwnerId,
        [Parameter(Mandatory)] [string] $RepositorySyncRepositoryId,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $EntraGroupNames,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Identity,
        [Parameter(Mandatory)] [string] $JobWorkflowPath,
        [string] $ModuleAddress = 'module.azure',
        [string] $WorkflowRef,
        [switch] $BicepRegistryFederation,
        [string[]] $Environments = @('pr-check', 'integration-test', 'examples-test-execution')
    )

    if (($Plan.Contains('errored') -and $Plan['errored'] -ne $false) -or
        ($Plan.Contains('complete') -and $Plan['complete'] -ne $true) -or
        $Plan['resource_changes'] -isnot [System.Collections.IList] -or
        $Plan['planned_values'] -isnot [System.Collections.IDictionary] -or
        $Plan['planned_values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('External identity plans must be complete and non-errored.')
    }
    foreach ($field in @('name', 'resource_id', 'client_id', 'principal_id', 'manage_entra_groups')) {
        if (-not $Identity.Contains($field)) {
            throw [System.ArgumentException]::new('External identity validation requires complete bootstrap evidence.')
        }
    }
    if ($Identity['name'] -cne 'id-avm-subscription-vending' -or
        $Identity['resource_id'] -ine "/subscriptions/$($Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/resourceGroups/rg-avm-managed-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-avm-subscription-vending" -or
        $Identity['manage_entra_groups'] -isnot [bool]) {
        throw [System.InvalidOperationException]::new('External identity plans may use only the pinned bootstrap subscription-vending identity.')
    }
    foreach ($field in @('client_id', 'principal_id')) {
        $id = [guid]::Empty
        if ($Identity[$field] -isnot [string] -or -not [guid]::TryParseExact($Identity[$field], 'D', [ref]$id) -or
            $id -eq [guid]::Empty -or $id.ToString() -in @($Settings['TEST_BAMI_CONTROLLER_CLIENT_ID'], $Settings['TEST_BAMI_BICEP_CLIENT_ID'])) {
            throw [System.InvalidOperationException]::new('External identity evidence must not bind a controller or Bicep execution identity.')
        }
    }

    $moduleMatch = [regex]::Match($ModuleAddress, '^module\.bicep\["([^"]+)"\]$')
    $federationName = "$($Identity['name'])-$(if ($moduleMatch.Success) { 'bicep-sub-vending' } else { 'terraform-sub-vending' })"
    $resources = @(Get-AvmTerraformPlannedResource -Module $Plan['planned_values']['root_module'])
    $managed = @($resources | Where-Object { $_['mode'] -ceq 'managed' })
    $allowed = @()
    if ($Identity['manage_entra_groups']) {
        $allowed += "$ModuleAddress.azapi_resource.federated_credentials[`"validation`"]"
    }
    foreach ($environment in $Environments) {
        $allowed += "$ModuleAddress.azapi_resource.federated_credentials[`"module-$environment`"]"
    }
    if ($BicepRegistryFederation) {
        $allowed += "$ModuleAddress.azapi_resource.federated_credentials[`"bicep-registry`"]"
    }
    if ($Identity['manage_entra_groups']) {
        foreach ($group in $EntraGroupNames) {
            $allowed += "$ModuleAddress.azuread_group_member.test_permissions[$(ConvertTo-Json -InputObject $group -Compress)]"
        }
    }
    $addresses = @($managed | ForEach-Object { $_['address'] } | Select-Object -Unique)
    if ($managed.Count -ne $allowed.Count -or $addresses.Count -ne $allowed.Count -or
        @($addresses | Where-Object { $_ -cnotin $allowed }).Count -gt 0) {
        throw [System.InvalidOperationException]::new('External identity plans may manage only their exact federation and selected individual membership edges.')
    }
    $changes = @{}
    foreach ($change in $Plan['resource_changes']) {
        if ($change -isnot [System.Collections.IDictionary] -or $change['address'] -isnot [string] -or
            $change['change'] -isnot [System.Collections.IDictionary] -or $changes.Contains($change['address'])) {
            throw [System.InvalidOperationException]::new('External identity plans require complete unambiguous changes.')
        }
        $changes[$change['address']] = $change
    }
    foreach ($resource in $managed) {
        $change = $changes[$resource['address']]
        $type = $resource['address'] -match '\.azuread_group_member\.' ? 'azuread_group_member' : 'azapi_resource'
        $provider = $type -ceq 'azuread_group_member' ? 'registry.terraform.io/hashicorp/azuread' : 'registry.terraform.io/azure/azapi'
        if ($null -eq $change -or $resource['type'] -cne $type -or $change['mode'] -cne 'managed' -or
            $change['type'] -cne $type -or $change['provider_name'] -cne $provider -or
            (@($change['change']['actions']) -join ',') -cnotin @('no-op', 'create', 'update', 'delete,create', 'create,delete')) {
            throw [System.InvalidOperationException]::new('External identity plans contain an invalid provider or action.')
        }
    }

    $data = @(Get-AvmTerraformPlanDataResource -Plan $Plan)
    $identityEvidence = @($data | Where-Object { $_['address'] -ceq "$ModuleAddress.data.azapi_resource.existing_identity[0]" })
    if ($identityEvidence.Count -ne 1 -or $identityEvidence[0]['values'] -isnot [System.Collections.IDictionary] -or
        $identityEvidence[0]['values']['id'] -ine $Identity['resource_id'] -or
        $identityEvidence[0]['values']['output'] -isnot [System.Collections.IDictionary] -or
        $identityEvidence[0]['values']['output']['properties'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('External identity plans require exact bootstrap UAMI read evidence.')
    }
    $properties = $identityEvidence[0]['values']['output']['properties']
    if ($properties['tenantId'] -ine $Settings['TEST_BAMI_TENANT_ID'] -or
        $properties['clientId'] -ine $Identity['client_id'] -or $properties['principalId'] -ine $Identity['principal_id']) {
        throw [System.InvalidOperationException]::new('External identity read evidence does not match the pinned bootstrap tuple.')
    }

    foreach ($environment in $Environments) {
        $address = "$ModuleAddress.azapi_resource.federated_credentials[`"module-$environment`"]"
        $expectedName = "$federationName-fic-m-$environment"
        $credential = @($managed | Where-Object { $_['address'] -ceq $address })[0]
        if ($credential['values']['name'] -cne $expectedName -or $expectedName.Length -gt 120 -or
            $credential['values']['parent_id'] -ine $Identity['resource_id'] -or
            -not (Test-AvmBamiModuleFederation -Values $credential['values'] -Expression (
                Get-AvmBamiModuleFederationExpression -RepositoryOwnerId $RepositoryOwnerId `
                    -RepositoryId $RepositoryId -Environment $environment -JobWorkflowPath $JobWorkflowPath -WorkflowRef $WorkflowRef))) {
            throw [System.InvalidOperationException]::new('External identity federation must retain the configured reusable workflow boundary.')
        }
    }
    if ($Identity['manage_entra_groups']) {
        $validationExpression = Get-AvmBamiFederationExpression `
            -SubjectPattern "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositorySyncRepositoryId}:environment:avm-validation" `
            -RepositoryOwnerId $RepositoryOwnerId -RepositoryId $RepositorySyncRepositoryId
        Assert-AvmExternalFederatedCredential -Resource @($managed | Where-Object {
                $_['address'] -ceq "$ModuleAddress.azapi_resource.federated_credentials[`"validation`"]"
            })[0] -Name "$federationName-fic-v-avm-validation" -ParentId $Identity['resource_id'] -Expression $validationExpression
    }
    if ($BicepRegistryFederation) {
        $registryExpression = Get-AvmBamiFederationExpression `
            -SubjectPattern "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositoryId}:environment:avm-validation" `
            -RepositoryOwnerId $RepositoryOwnerId -RepositoryId $RepositoryId
        Assert-AvmExternalFederatedCredential -Resource @($managed | Where-Object {
                $_['address'] -ceq "$ModuleAddress.azapi_resource.federated_credentials[`"bicep-registry`"]"
            })[0] -Name "$federationName-fic-r-avm-validation" -ParentId $Identity['resource_id'] -Expression $registryExpression
    }

    $legacyFederation = @{}
    foreach ($environment in $Environments) {
        $legacyFederation["$ModuleAddress.azapi_resource.identity_federated_credentials[`"$environment`"]"] = @{
            CurrentAddress = "$ModuleAddress.azapi_resource.federated_credentials[`"module-$environment`"]"
            Name           = "$federationName-fic-m-$environment"
            LegacyName     = $WorkflowRef ? "$federationName-module-$environment" : "$federationName-$environment"
            Expression     = Get-AvmBamiModuleFederationExpression -RepositoryOwnerId $RepositoryOwnerId `
                -RepositoryId $RepositoryId -Environment $environment -JobWorkflowPath $JobWorkflowPath -WorkflowRef $WorkflowRef
            LegacySubjectPattern = Get-AvmBamiLegacyModuleSubjectPattern -RepositoryOwnerId $RepositoryOwnerId `
                -RepositoryId $RepositoryId -Environment $environment -JobWorkflowPath $JobWorkflowPath -WorkflowRef $WorkflowRef
        }
    }
    if ($Identity['manage_entra_groups']) {
        $legacyFederation["$ModuleAddress.azapi_resource.validation_federated_credential[0]"] = @{
            CurrentAddress       = "$ModuleAddress.azapi_resource.federated_credentials[`"validation`"]"
            Name                 = "$federationName-fic-v-avm-validation"
            LegacyName           = "$federationName-avm-validation"
            Expression           = $validationExpression
            LegacySubjectPattern = '\A' + [regex]::Escape(
                "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositorySyncRepositoryId}:environment:avm-validation"
            ) + '\z'
        }
    }
    if ($BicepRegistryFederation) {
        $legacyFederation["$ModuleAddress.azapi_resource.bicep_registry_federated_credential[0]"] = @{
            CurrentAddress       = "$ModuleAddress.azapi_resource.federated_credentials[`"bicep-registry`"]"
            Name                 = "$federationName-fic-r-avm-validation"
            LegacyName           = "$federationName-registry-avm-validation"
            Expression           = $registryExpression
            LegacySubjectPattern = '\A' + [regex]::Escape(
                "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositoryId}:environment:avm-validation"
            ) + '\z'
        }
    }
    foreach ($change in $changes.Values) {
        if ($change['address'] -cin $allowed) { continue }
        if ($Environments -cnotcontains 'examples-test' -and
            (Test-AvmRetiredExamplesTestFederationChange -Change $change -ModuleAddress $ModuleAddress `
                -IdentityName $federationName -IdentityId $Identity['resource_id'])) { continue }
        $expected = $legacyFederation[$change['address']]
        $currentChange = if ($null -ne $expected) { $changes[$expected.CurrentAddress] } else { $null }
        $before = $change['change']['before']
        if ($null -eq $expected -or (@($change['change']['actions']) -join ',') -cne 'delete' -or
            $null -ne $change['change']['after'] -or $before -isnot [System.Collections.IDictionary] -or
            $change['mode'] -cne 'managed' -or $change['type'] -cne 'azapi_resource' -or
            $change['provider_name'] -cne 'registry.terraform.io/azure/azapi' -or
            $before['name'] -cne $expected.LegacyName -or $before['parent_id'] -ine $Identity['resource_id'] -or
            -not (Test-AvmBamiModuleFederation -Values $before -Expression $expected.Expression `
                -LegacySubjectPattern $expected.LegacySubjectPattern -AllowLegacy) -or
            $null -eq $currentChange -or (@($currentChange['change']['actions']) -join ',') -cne 'create' -or
            $null -ne $currentChange['change']['before'] -or $currentChange.Contains('previous_address')) {
            throw [System.InvalidOperationException]::new('External identity plans may recreate only verified legacy federated credentials with their canonical trust boundary.')
        }
    }
}

function Assert-AvmExternalFederatedCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Resource,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $ParentId,
        [Parameter(Mandatory)] [string] $Expression
    )

    $properties = $Resource['values']['body']['properties']
    if ($Resource['type'] -cne 'azapi_resource' -or $Resource['values']['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-01-31-preview' -or
        $Resource['values']['name'] -cne $Name -or $Name.Length -gt 120 -or $Resource['values']['parent_id'] -ine $ParentId -or
        $properties['issuer'] -cne 'https://token.actions.githubusercontent.com' -or
        @($properties['audiences']).Count -ne 1 -or @($properties['audiences'])[0] -cne 'api://AzureADTokenExchange' -or
        $properties['claimsMatchingExpression']['languageVersion'] -ne 1 -or
        $properties['claimsMatchingExpression']['value'] -cne $Expression) {
        throw [System.InvalidOperationException]::new('External identity federation must retain an exact disjoint child name and OIDC claim expression.')
    }
}

function Assert-AvmBamiIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $RepositoryId,
        [Parameter(Mandatory)] [string] $RepositoryOwnerId,
        [Parameter(Mandatory)] [string] $RepositorySyncRepositoryId,
        [Parameter(Mandatory)] [string] $JobWorkflowPath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $EntraGroupNames,
        [ValidatePattern('^module\.(azure|bami\[0\]|bicep\["avm/(res|ptn|utl)/[a-z0-9-]+/[a-z0-9-]+"\])$')]
        [string] $ModuleAddress = 'module.azure',
        [string] $IdentityName,
        [string] $WorkflowRef,
        [switch] $BicepRegistryFederation,
        [AllowNull()] [System.Collections.IDictionary] $ExistingIdentity,
        [ValidatePattern('^[a-z][a-z0-9-]*$')]
        [string[]] $Environments = @('pr-check', 'integration-test', 'examples-test-execution'),
        [switch] $PassThru
    )

    $Settings = Get-AvmBamiSettings -Values $Settings
    $EntraGroupNames = ConvertTo-AvmEntraGroupNames -Names $EntraGroupNames
    if ($WorkflowRef -and -not $WorkflowRef.StartsWith("$Repository/.github/workflows/", [System.StringComparison]::Ordinal)) {
        throw [System.ArgumentException]::new('Caller federation must bind the configured repository.')
    }
    if ($null -ne $ExistingIdentity) {
        Assert-AvmExternalBamiIdentityPlan -Plan $Plan -Settings $Settings -Repository $Repository `
            -RepositoryId $RepositoryId -RepositoryOwnerId $RepositoryOwnerId `
            -RepositorySyncRepositoryId $RepositorySyncRepositoryId -JobWorkflowPath $JobWorkflowPath `
            -EntraGroupNames $EntraGroupNames -ModuleAddress $ModuleAddress -Identity $ExistingIdentity `
            -WorkflowRef $WorkflowRef -BicepRegistryFederation:$BicepRegistryFederation -Environments $Environments
        return
    }
    $moduleMatch = [regex]::Match($ModuleAddress, '^module\.bicep\["([^"]+)"\]$')
    if ($BicepRegistryFederation -and (-not $moduleMatch.Success -or $Repository -cne 'Azure/bicep-registry-modules' -or
        $Environments.Count -ne 1 -or $Environments[0] -cne 'avm-validation')) {
        throw [System.ArgumentException]::new('Registry environment federation is restricted to dedicated Bicep module identities in avm-validation.')
    }
    if ($RepositoryId -cnotmatch '^[1-9][0-9]*$' -or $RepositoryOwnerId -cnotmatch '^[1-9][0-9]*$' -or
        $RepositorySyncRepositoryId -cnotmatch '^[1-9][0-9]*$') {
        throw [System.ArgumentException]::new('Candidate federation requires positive GitHub repository, organization, and tools repository IDs.')
    }
    if (($Plan.Contains('errored') -and $Plan['errored'] -ne $false) -or
        ($Plan.Contains('complete') -and $Plan['complete'] -ne $true) -or $Plan['planned_values'] -isnot [System.Collections.IDictionary] -or
        $Plan['planned_values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Candidate Terraform plan is incomplete or errored.')
    }
    if ($Plan['resource_changes'] -isnot [System.Collections.IList]) {
        throw [System.InvalidOperationException]::new('Candidate Terraform plan must include complete resource changes.')
    }
    $resources = @(Get-AvmTerraformPlannedResource -Module $Plan['planned_values']['root_module'])
    $identityAddress = "$ModuleAddress.azapi_resource.identity[0]"
    $validationCredentialAddress = "$ModuleAddress.azapi_resource.federated_credentials[`"validation`"]"
    $registryCredentialAddress = "$ModuleAddress.azapi_resource.federated_credentials[`"bicep-registry`"]"
    $membershipNames = @{}
    foreach ($groupName in $EntraGroupNames) {
        $key = ConvertTo-Json -InputObject $groupName -Compress
        $membershipNames["$ModuleAddress.azuread_group_member.test_permissions[$key]"] = $groupName
    }
    $allowed = @($identityAddress, $validationCredentialAddress)
    if ($BicepRegistryFederation) { $allowed += $registryCredentialAddress }
    foreach ($environment in $Environments) {
        $allowed += "$ModuleAddress.azapi_resource.federated_credentials[`"module-$environment`"]"
    }
    $allowed += @($membershipNames.Keys)
    $managed = @($resources | Where-Object { $_['mode'] -ceq 'managed' })
    $addresses = @($managed | ForEach-Object { $_['address'] } | Select-Object -Unique)
    if ($managed.Count -ne $allowed.Count -or $addresses.Count -ne $allowed.Count -or
        @($addresses | Where-Object { $_ -cnotin $allowed }).Count -gt 0) {
        throw [System.InvalidOperationException]::new('Candidate plan must contain only the complete dedicated repository identity, federation, and membership scope.')
    }
    $changes = @{}
    foreach ($change in $Plan['resource_changes']) {
        if ($change -isnot [System.Collections.IDictionary] -or $change['address'] -isnot [string] -or
            $change['change'] -isnot [System.Collections.IDictionary] -or $changes.ContainsKey($change['address'])) {
            throw [System.InvalidOperationException]::new('Candidate plan contains missing or ambiguous resource changes.')
        }
        $changes[$change['address']] = $change
    }
    $nameArguments = @{ Repository = $Repository }
    if ($moduleMatch.Success) {
        if ($Repository -cne 'Azure/bicep-registry-modules') {
            throw [System.ArgumentException]::new('Bicep module identities must belong to the registry repository.')
        }
        $nameArguments = @{ ModulePath = $moduleMatch.Groups[1].Value }
    }
    $name = Get-AvmTestIdentityName @nameArguments
    $previousName = Get-AvmTestIdentityName @nameArguments -Legacy
    if ($IdentityName -and $IdentityName -cne $name) {
        throw [System.ArgumentException]::new('The identity override must match the computed dedicated test identity name.')
    }
    $identityChange = $changes[$identityAddress]
    $renaming = $null -ne $identityChange -and
        (@($identityChange['change']['actions']) -join ',') -cin @('delete,create', 'create,delete')
    $beforeIdentity = if ($null -ne $identityChange) { $identityChange['change']['before'] } else { $null }
    if ($renaming -and ($beforeIdentity -isnot [System.Collections.IDictionary] -or $beforeIdentity['name'] -cne $previousName)) {
        throw [System.InvalidOperationException]::new('Candidate identity plans must not delete or replace identities except for their exact legacy-to-current naming transition.')
    }
    foreach ($resource in $managed) {
        $address = $resource['address']
        $type = if ($membershipNames.ContainsKey($address)) { 'azuread_group_member' } else { 'azapi_resource' }
        $change = $changes[$address]
        $actions = if ($null -ne $change) { @($change['change']['actions']) } else { @() }
        $permittedActions = if ($type -ceq 'azuread_group_member' -or $renaming) { @('no-op', 'create', 'update', 'delete,create', 'create,delete') } else { @('no-op', 'create', 'update') }
        $provider = if ($type -ceq 'azuread_group_member') { 'registry.terraform.io/hashicorp/azuread' } else { 'registry.terraform.io/azure/azapi' }
        if ($resource['type'] -cne $type -or $resource['values'] -isnot [System.Collections.IDictionary] -or
            $null -eq $change -or $change['mode'] -cne 'managed' -or $change['type'] -cne $type -or
            $change['provider_name'] -cne $provider -or $change['change']['after'] -isnot [System.Collections.IDictionary] -or
            ($change.Contains('previous_address') -and $change['previous_address'] -cne $address -and
                -not ($address -ceq $identityAddress -and
                    $change['previous_address'] -ceq $address.Substring(0, $address.Length - 3) -and
                    ($actions -join ',') -ceq 'no-op')) -or
            $null -ne $change['change']['importing'] -or ($actions -join ',') -cnotin $permittedActions) {
            throw [System.InvalidOperationException]::new('Candidate identity plans must not delete or replace required resources, or omit their changes.')
        }
    }
    $identity = @($managed | Where-Object { $_['address'] -ceq $identityAddress })[0]['values']
    $parentId = "/subscriptions/$($Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/resourceGroups/$($Settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'])"
    $identityId = "$parentId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
    foreach ($values in @($identity, $identityChange['change']['after'])) {
        if ($values['parent_id'] -cne $parentId -or $values['name'] -cne $name -or
            ($null -ne $values['id'] -and $values['id'] -ine $identityId) -or
            $values['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview') {
            throw [System.InvalidOperationException]::new('Candidate identity is not scoped to the expected repository and BAMI resource group.')
        }
    }
    $dataResources = @(Get-AvmTerraformPlanDataResource -Plan $Plan)
    $azureContexts = @($dataResources | Where-Object { $_['address'] -ceq "$ModuleAddress.data.azapi_client_config.current" })
    $graphContexts = @($dataResources | Where-Object { $_['address'] -ceq "$ModuleAddress.data.azuread_client_config.current" })
    if ($azureContexts.Count -ne 1 -or $graphContexts.Count -ne 1 -or
        $azureContexts[0]['mode'] -cne 'data' -or $graphContexts[0]['mode'] -cne 'data' -or
        $azureContexts[0]['type'] -cne 'azapi_client_config' -or $graphContexts[0]['type'] -cne 'azuread_client_config' -or
        $azureContexts[0]['values'] -isnot [System.Collections.IDictionary] -or
        $graphContexts[0]['values'] -isnot [System.Collections.IDictionary] -or
        $azureContexts[0]['values']['tenant_id'] -isnot [string] -or
        $azureContexts[0]['values']['subscription_id'] -isnot [string] -or
        $graphContexts[0]['values']['tenant_id'] -isnot [string] -or
        $graphContexts[0]['values']['client_id'] -isnot [string] -or
        $azureContexts[0]['values']['tenant_id'] -ine $Settings['TEST_BAMI_TENANT_ID'] -or
        $azureContexts[0]['values']['subscription_id'] -ine $Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'] -or
        $graphContexts[0]['values']['tenant_id'] -ine $Settings['TEST_BAMI_TENANT_ID'] -or
        $graphContexts[0]['values']['client_id'] -ine $Settings['TEST_BAMI_CONTROLLER_CLIENT_ID']) {
        throw [System.InvalidOperationException]::new('Candidate membership requires verified Azure and Graph tenant/controller evidence.')
    }
    $controllerPrincipal = [guid]::Empty
    if ($graphContexts[0]['values']['object_id'] -isnot [string] -or
        -not [guid]::TryParseExact($graphContexts[0]['values']['object_id'], 'D', [ref] $controllerPrincipal) -or
        $controllerPrincipal -eq [guid]::Empty) {
        throw [System.InvalidOperationException]::new('Candidate membership requires a verified controller principal object ID.')
    }
    $previousPrincipal = $null
    $previousClient = $null
    $previousIdentityId = $null
    if ($null -ne $beforeIdentity) {
        $ownedName = if ($renaming) { $previousName } else { $name }
        $previousIdentityId = "$parentId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$ownedName"
        if ($beforeIdentity -isnot [System.Collections.IDictionary] -or
            $beforeIdentity['name'] -cne $ownedName -or $beforeIdentity['parent_id'] -cne $parentId -or
            $beforeIdentity['id'] -ine $previousIdentityId -or
            $beforeIdentity['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' -or
            $beforeIdentity['output'] -isnot [System.Collections.IDictionary] -or
            $beforeIdentity['output']['properties'] -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new('Existing state must belong to the expected dedicated identity, never a foreign or shared identity.')
        }
        $properties = $beforeIdentity['output']['properties']
        $oldPrincipal = [guid]::Empty
        $oldClient = [guid]::Empty
        if ($properties['tenantId'] -ine $Settings['TEST_BAMI_TENANT_ID'] -or
            $properties['principalId'] -isnot [string] -or
            -not [guid]::TryParseExact($properties['principalId'], 'D', [ref]$oldPrincipal) -or
            $oldPrincipal -eq [guid]::Empty -or $oldPrincipal -eq $controllerPrincipal -or
            $properties['clientId'] -isnot [string] -or
            -not [guid]::TryParseExact($properties['clientId'], 'D', [ref]$oldClient) -or
            $oldClient -eq [guid]::Empty -or
            $oldClient.ToString() -in @($Settings['TEST_BAMI_CONTROLLER_CLIENT_ID'], $Settings['TEST_BAMI_BICEP_CLIENT_ID'])) {
            throw [System.InvalidOperationException]::new('Existing identity ownership requires a dedicated client and principal in the pinned BAMI tenant.')
        }
        $previousPrincipal = $oldPrincipal.ToString()
        $previousClient = $oldClient.ToString()
    }
    if ((@($identityChange['change']['actions']) -join ',') -ceq 'create') {
        if ($null -ne $beforeIdentity) {
            throw [System.InvalidOperationException]::new('A new identity cannot adopt existing ownership evidence.')
        }
    }
    elseif ($null -eq $beforeIdentity) {
        throw [System.InvalidOperationException]::new('Existing identity changes require complete previous ownership evidence.')
    }
    $principal = $null
    $afterOutput = $identityChange['change']['after']['output']
    if (($null -eq $identity['output']) -ne ($null -eq $afterOutput)) {
        throw [System.InvalidOperationException]::new('Planned identity outputs and resource-change outputs must agree.')
    }
    if ($identity['output'] -is [System.Collections.IDictionary] -and
        $identity['output']['properties'] -is [System.Collections.IDictionary]) {
        if ($afterOutput -isnot [System.Collections.IDictionary] -or $afterOutput['properties'] -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new('Planned identity outputs and resource-change outputs must agree.')
        }
        foreach ($field in @('tenantId', 'clientId', 'principalId')) {
            if ($identity['output']['properties'][$field] -ine $afterOutput['properties'][$field]) {
                throw [System.InvalidOperationException]::new('Planned identity outputs and resource-change outputs must agree.')
            }
        }
        $principal = $identity['output']['properties']['principalId']
        if ($identity['output']['properties']['tenantId'] -ine $Settings['TEST_BAMI_TENANT_ID']) {
            throw [System.InvalidOperationException]::new('Candidate identity output must belong to the pinned BAMI tenant.')
        }
        $clientId = [guid]::Empty
        $client = $identity['output']['properties']['clientId']
        if ($client -isnot [string] -or -not [guid]::TryParseExact($client, 'D', [ref] $clientId) -or
            $clientId -eq [guid]::Empty -or
            $clientId.ToString() -in @($Settings['TEST_BAMI_CONTROLLER_CLIENT_ID'], $Settings['TEST_BAMI_BICEP_CLIENT_ID'])) {
            throw [System.InvalidOperationException]::new('Candidate execution requires a dedicated repository client ID, never the controller or shared Bicep identity.')
        }
        if ($previousClient -and (($renaming -and $client -ieq $previousClient) -or
            (-not $renaming -and $client -ine $previousClient))) {
            throw [System.InvalidOperationException]::new('Identity client IDs may change only for a verified naming replacement, and must then be new.')
        }
    }
    $principalId = [guid]::Empty
    $unknownPrincipal = Test-AvmTerraformPlanUnknownField -Change $changes[$identityAddress]['change'] -Path 'output.properties.principalId'
    if (($null -eq $principal -and -not $unknownPrincipal) -or
        ($null -ne $principal -and ($principal -isnot [string] -or
            -not [guid]::TryParseExact($principal, 'D', [ref] $principalId) -or $principalId -eq [guid]::Empty -or
            $principalId -eq $controllerPrincipal))) {
        throw [System.InvalidOperationException]::new('Candidate group membership must use the dedicated repository principal, never the controller.')
    }
    if ($null -ne $principal -and $previousPrincipal -and
        (($renaming -and $principal -ieq $previousPrincipal) -or (-not $renaming -and $principal -ine $previousPrincipal))) {
        throw [System.InvalidOperationException]::new('Identity principals may change only for a verified naming replacement, and must then be new.')
    }
    foreach ($address in $membershipNames.Keys) {
        $groupName = $membershipNames[$address]
        $dataAddress = $address.Replace('azuread_group_member.', 'data.azuread_group.')
        $evidence = @($dataResources | Where-Object { $_['address'] -ceq $dataAddress })
        if ($evidence.Count -ne 1 -or $evidence[0]['mode'] -cne 'data' -or
            $evidence[0]['type'] -cne 'azuread_group' -or $evidence[0]['values'] -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new("Candidate membership requires exactly one target-tenant lookup for configured group '$groupName'.")
        }
        $values = $evidence[0]['values']
        $groupId = [guid]::Empty
        if ($values['object_id'] -isnot [string] -or -not [guid]::TryParseExact($values['object_id'], 'D', [ref] $groupId) -or
            $groupId -eq [guid]::Empty -or $values['display_name'] -cne $groupName -or
            $values['security_enabled'] -isnot [bool] -or $values['security_enabled'] -ne $true) {
            throw [System.InvalidOperationException]::new('Candidate group evidence must identify the configured security group in the selected tenant.')
        }
        $plannedMembership = @($managed | Where-Object { $_['address'] -ceq $address })[0]['values']
        foreach ($membership in @($plannedMembership, $changes[$address]['change']['after'])) {
            $member = $membership['member_object_id']
            if ($membership['group_object_id'] -isnot [string] -or $membership['group_object_id'] -ine $groupId.ToString() -or
                ($null -ne $principal -and ($member -isnot [string] -or $member -ine $principal)) -or
                ($null -eq $principal -and ($null -ne $member -or
                    -not (Test-AvmTerraformPlanUnknownField -Change $changes[$address]['change'] -Path 'member_object_id')))) {
                throw [System.InvalidOperationException]::new('Candidate membership must bind only the resolved configured group and dedicated repository principal.')
            }
        }
        if ($renaming -and $null -ne $changes[$address]['change']['before'] -and
            (@($changes[$address]['change']['actions']) -join ',') -cnotin @('delete,create', 'create,delete')) {
            throw [System.InvalidOperationException]::new('A naming replacement must replace each retained membership edge for the old principal.')
        }
    }
    $federation = [ordered]@{}
    foreach ($environment in $Environments) {
        $address = "$ModuleAddress.azapi_resource.federated_credentials[`"module-$environment`"]"
        $federation[$address] = @{
            Kind = 'module'
            Name = "$name-fic-m-$environment"
            LegacyName = if ($WorkflowRef) { "$name-module-$environment" } else { "$name-$environment" }
            Expression = Get-AvmBamiModuleFederationExpression -RepositoryOwnerId $RepositoryOwnerId `
                -RepositoryId $RepositoryId -Environment $environment -JobWorkflowPath $JobWorkflowPath -WorkflowRef $WorkflowRef
            LegacySubjectPattern = Get-AvmBamiLegacyModuleSubjectPattern -RepositoryOwnerId $RepositoryOwnerId `
                -RepositoryId $RepositoryId -Environment $environment -JobWorkflowPath $JobWorkflowPath -WorkflowRef $WorkflowRef
        }
    }
    $federation[$validationCredentialAddress] = @{
        Kind = 'validation'
        Name = "$name-fic-v-avm-validation"
        LegacyName = "$name-avm-validation"
        Expression = Get-AvmBamiFederationExpression `
            -SubjectPattern "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositorySyncRepositoryId}:environment:avm-validation" `
            -RepositoryOwnerId $RepositoryOwnerId -RepositoryId $RepositorySyncRepositoryId
        LegacySubjectPattern = '\A' + [regex]::Escape(
            "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositorySyncRepositoryId}:environment:avm-validation"
        ) + '\z'
    }
    if ($BicepRegistryFederation) {
        $federation[$registryCredentialAddress] = @{
            Kind = 'registry'
            Name = "$name-fic-r-avm-validation"
            LegacyName = "$name-registry-avm-validation"
            Expression = Get-AvmBamiFederationExpression `
                -SubjectPattern "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositoryId}:environment:avm-validation" `
                -RepositoryOwnerId $RepositoryOwnerId -RepositoryId $RepositoryId
            LegacySubjectPattern = '\A' + [regex]::Escape(
                "repository_owner_id:${RepositoryOwnerId}:repository_id:${RepositoryId}:environment:avm-validation"
            ) + '\z'
        }
    }
    $legacyFederation = @{}
    foreach ($environment in $Environments) {
        $legacyFederation["$ModuleAddress.azapi_resource.identity_federated_credentials[`"$environment`"]"] =
            "$ModuleAddress.azapi_resource.federated_credentials[`"module-$environment`"]"
    }
    $legacyFederation["$ModuleAddress.azapi_resource.validation_federated_credential[0]"] = $validationCredentialAddress
    $legacyFederation["$ModuleAddress.azapi_resource.validation_federated_credential"] = $validationCredentialAddress
    if ($BicepRegistryFederation) {
        $legacyFederation["$ModuleAddress.azapi_resource.bicep_registry_federated_credential[0]"] = $registryCredentialAddress
    }
    $previousModuleCredentials = 0
    foreach ($address in $federation.Keys) {
        $credential = @($managed | Where-Object { $_['address'] -ceq $address })[0]['values']
        $credentialChange = $changes[$address]['change']
        $beforeCredential = $credentialChange['before']
        if ($null -ne $beforeCredential -and ($null -eq $beforeIdentity -or
            ($renaming -and (@($credentialChange['actions']) -join ',') -cnotin @('delete,create', 'create,delete')))) {
            throw [System.InvalidOperationException]::new('Existing federation requires its verified identity and must be replaced with that identity during a naming transition.')
        }
        if ((@($credentialChange['actions']) -join ',') -ceq 'create') {
            if ($null -ne $beforeCredential) { throw [System.InvalidOperationException]::new('New federation must not adopt an existing credential.') }
        }
        elseif ($beforeCredential -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new('Existing federation changes require previous credential ownership evidence.')
        }
        $sides = @(
            @{ Values = $credential; Names = @($federation[$address].Name); Parent = $identityId; Previous = $false }
            @{ Values = $credentialChange['after']; Names = @($federation[$address].Name); Parent = $identityId; Previous = $false }
        )
        if ($null -ne $beforeCredential) {
            if ($federation[$address].Kind -ceq 'module') { $previousModuleCredentials++ }
            $oldNames = if ($renaming) {
                @(
                    $previousName + $federation[$address].Name.Substring($name.Length)
                    $previousName + $federation[$address].LegacyName.Substring($name.Length)
                ) | Select-Object -Unique
            }
            else {
                @($federation[$address].Name)
            }
            $sides += @{ Values = $beforeCredential; Names = $oldNames; Parent = $previousIdentityId; Previous = $true }
        }
        foreach ($side in $sides) {
            $values = $side.Values
            $isValidModuleFederation = Test-AvmBamiModuleFederation -Values $values `
                -Expression $federation[$address].Expression `
                -LegacySubjectPattern $federation[$address].LegacySubjectPattern -WorkflowRef $WorkflowRef -AllowLegacy:$side.Previous
            $validName = $values -is [System.Collections.IDictionary] -and $values['name'] -cin $side.Names
            if ($values -isnot [System.Collections.IDictionary] -or
                -not $validName -or $values['name'].Length -gt 120 -or
                ($null -ne $values['id'] -and $values['id'] -ine "$($side.Parent)/federatedIdentityCredentials/$($values['name'])") -or
                ($null -ne $values['parent_id'] -and $values['parent_id'] -ine $side.Parent) -or
                ($null -eq $values['parent_id'] -and ($side.Previous -or
                    -not (Test-AvmTerraformPlanUnknownField -Change $credentialChange -Path 'parent_id'))) -or
                -not $isValidModuleFederation) {
                throw [System.InvalidOperationException]::new('Candidate federation, including validation federation, must retain the exact repository, environment, workflow, and identity binding.')
            }
        }
    }
    if ($renaming -and $previousModuleCredentials -eq 0) {
        throw [System.InvalidOperationException]::new('A naming replacement requires existing module federation proving the same immutable repository and workflow binding.')
    }
    $ownerDeletions = 0
    foreach ($change in $changes.Values) {
        $actions = @($change['change']['actions'])
        if ($change['address'] -cin $allowed -and $change['type'] -cne 'azuread_group_member') { continue }
        if ($change['address'] -cin $allowed -and $actions -notcontains 'delete' -and
            $null -eq $change['change']['before']) { continue }
        if ($change['mode'] -ceq 'data' -and $actions.Count -eq 1 -and $actions[0] -cin @('no-op', 'read')) { continue }
        if ($Environments -cnotcontains 'examples-test' -and
            (Test-AvmRetiredExamplesTestFederationChange -Change $change -ModuleAddress $ModuleAddress `
                -IdentityName ($renaming ? $previousName : $name) -IdentityId $previousIdentityId)) { continue }
        $before = $change['change']['before']
        if ($legacyFederation.ContainsKey($change['address'])) {
            $currentAddress = $legacyFederation[$change['address']]
            $currentChange = $changes[$currentAddress]
            $expected = $federation[$currentAddress]
            $legacyValid = $before -is [System.Collections.IDictionary] -and
                (Test-AvmBamiModuleFederation -Values $before -Expression $expected.Expression `
                    -LegacySubjectPattern $expected.LegacySubjectPattern -AllowLegacy) -and
                $before['name'] -ceq $expected.LegacyName -and
                $before['parent_id'] -ieq $identityId
            if (($actions -join ',') -ceq 'delete' -and $null -eq $change['change']['after'] -and
                $change['mode'] -ceq 'managed' -and $change['type'] -ceq 'azapi_resource' -and
                $change['provider_name'] -ceq 'registry.terraform.io/azure/azapi' -and
                $legacyValid -and $null -ne $currentChange -and
                (@($currentChange['change']['actions']) -join ',') -ceq 'create' -and
                $null -eq $currentChange['change']['before'] -and
                -not $currentChange.Contains('previous_address')) {
                continue
            }
        }
        if ($change['mode'] -cne 'managed' -or $before -isnot [System.Collections.IDictionary] -or $null -eq $previousPrincipal) {
            throw [System.InvalidOperationException]::new('Candidate plans must not delete or replace resources outside verified permission migration or revocation.')
        }
        $membershipAddress = $change['address'] -ceq "$ModuleAddress.azuread_group_member.example" -or
            $change['address'] -cmatch ('^' + [regex]::Escape($ModuleAddress) + '\.azuread_group_member\.test_permissions\["(?:[^"\\]|\\.)+"\]$')
        if ($change['type'] -ceq 'azuread_group_member' -and $membershipAddress) {
            $previousGroupId = [guid]::Empty
            $removed = ($actions -join ',') -ceq 'delete' -and $null -eq $change['change']['after']
            $retained = $change['address'] -cin $allowed -and
                ($actions -join ',') -cin @('no-op', 'update', 'delete,create', 'create,delete')
            if (($removed -or $retained) -and $before['member_object_id'] -is [string] -and
                $before['member_object_id'] -ieq $previousPrincipal -and $before['group_object_id'] -is [string] -and
                [guid]::TryParseExact($before['group_object_id'], 'D', [ref] $previousGroupId) -and $previousGroupId -ne [guid]::Empty) {
                continue
            }
        }
        $ownerAddresses = @("$ModuleAddress.azapi_resource.identity_role_assignment", "$ModuleAddress.azapi_resource.identity_role_assignment[0]")
        if (($actions -join ',') -ceq 'delete' -and $null -eq $change['change']['after'] -and
            $change['address'] -cin $ownerAddresses -and $change['type'] -ceq 'azapi_resource' -and
            $before['body'] -is [System.Collections.IDictionary] -and $before['body']['properties'] -is [System.Collections.IDictionary]) {
            $assignmentName = Get-AvmBamiOwnerAssignmentName -Repository $Repository -Settings $Settings
            $scope = "/providers/Microsoft.Management/managementGroups/$($Settings['TEST_BAMI_MANAGEMENT_GROUP_ID'])"
            $properties = $before['body']['properties']
            if ($before['type'] -ceq 'Microsoft.Authorization/roleAssignments@2022-04-01' -and
                $before['parent_id'] -ceq $scope -and $before['name'] -ceq $assignmentName -and
                $before['id'] -ieq "$scope/providers/Microsoft.Authorization/roleAssignments/$assignmentName" -and
                $properties['roleDefinitionId'] -ceq '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635' -and
                $properties['principalType'] -ceq 'ServicePrincipal' -and $properties['principalId'] -ieq $previousPrincipal -and
                (-not $change.Contains('previous_address') -or $change['previous_address'] -ceq $ownerAddresses[0])) {
                $ownerDeletions++
                if ($ownerDeletions -eq 1) { continue }
            }
        }
        throw [System.InvalidOperationException]::new('Candidate change is not the exact obsolete Owner assignment or an individual membership edge for this repository principal.')
    }
    if ($PassThru -and $renaming) {
        return @{
            identity_resource_id = $previousIdentityId
            client_id = $previousClient
            tenant_id = $Settings['TEST_BAMI_TENANT_ID']
        }
    }
}

function ConvertTo-AvmBamiConsumerSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Identity,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [object] $Repository,
        [AllowNull()] [System.Collections.IDictionary] $ExistingIdentity
    )

    $Settings = Get-AvmBamiSettings -Values $Settings
    $clientId = [guid]::Empty
    $expectedIdentity = if ($null -eq $ExistingIdentity) {
        $name = Get-AvmTestIdentityName -Repository $Repository.full_name
        "/subscriptions/$($Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/resourceGroups/$($Settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME'])/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
    }
    else {
        $ExistingIdentity['resource_id']
    }
    if ($Identity['client_id'] -isnot [string] -or -not [guid]::TryParseExact($Identity['client_id'], 'D', [ref] $clientId) -or
        $clientId -eq [guid]::Empty -or $clientId.ToString() -in @($Settings['TEST_BAMI_CONTROLLER_CLIENT_ID'], $Settings['TEST_BAMI_BICEP_CLIENT_ID']) -or
        ($null -ne $ExistingIdentity -and $clientId.ToString() -ine $ExistingIdentity['client_id']) -or
        $Identity['tenant_id'] -ine $Settings['TEST_BAMI_TENANT_ID'] -or
        $Identity['identity_resource_id'] -ine $expectedIdentity -or
        $Identity['repository_id'] -cne [string]$Repository.id -or $Identity['repository_owner_id'] -cne [string]$Repository.owner.id) {
        throw [System.InvalidOperationException]::new('Candidate output is not a complete expected test identity for the tenant and repository; controller/Bicep identities cannot be used.')
    }
    return @{
        tenant_id = $Settings['TEST_BAMI_TENANT_ID']
        client_id = $clientId.ToString()
        controller_client_id = $Settings['TEST_BAMI_CONTROLLER_CLIENT_ID']
        bicep_client_id = $Settings['TEST_BAMI_BICEP_CLIENT_ID']
        admin_subscription_id = $Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID']
        persistent_subscription_id = $Settings['TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID']
        test_subscription_ids = @(Get-AvmGeneralTestSubscription -Settings $Settings)
    }
}

function Resolve-AvmRepositorySyncContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $RepoId,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $RepositorySyncRepositoryId,
        [bool] $PlanOnly = $false,
        [bool] $AllowExampleRepositoryBranchApply = $false
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($RepoId -cnotmatch '^avm-(res|ptn|utl)-[a-z0-9]+(?:-[a-z0-9]+)*$' -or
        $Repository -cnotmatch ('^Azure/terraform-(azurerm|azure|azapi)-' + [regex]::Escape($RepoId) + '$')) {
        throw [System.ArgumentException]::new('Repository sync requires the selected canonical Azure AVM repository.')
    }
    $null = Get-AvmTestIdentityName -Repository $Repository
    if (-not $AllowExampleRepositoryBranchApply) {
        Assert-AvmBamiRepositorySyncRunContext -PlanOnly $PlanOnly
    }
    $toolsContext = Resolve-AvmRepositorySyncFederationContext -RepositoryId $RepositorySyncRepositoryId
    $repo = Invoke-RepositoryGitHubApi -Endpoint "repos/$Repository"
    if ($repo.full_name -cne $Repository -or $repo.fork -or $repo.id -le 0 -or
        [string]$repo.owner.id -cne $toolsContext.OrganizationId -or $repo.owner.login -cne 'Azure') {
        throw [System.InvalidOperationException]::new('GitHub returned an unexpected repository identity.')
    }
    Assert-AvmBamiRepositorySyncRunContext -PlanOnly $PlanOnly `
        -AllowExampleRepositoryBranchApply $AllowExampleRepositoryBranchApply -RepoId $RepoId -ResolvedRepository $repo
    if ($Repository -imatch 'windows|w5s') {
        $installed = @(Get-RepositoryInstalledRepositories)
        if (@($installed | Where-Object { $_.full_name -ceq $Repository }).Count -ne 1) {
            throw [System.InvalidOperationException]::new('Reserved-name identity validation requires the selected repository in the complete App installation inventory.')
        }
    }
    return [pscustomobject]@{
        Repository = $repo
        RepositoryId = $toolsContext.RepositoryId
        OrganizationId = $toolsContext.OrganizationId
    }
}

function ConvertTo-AvmRepositoryTerraformSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Settings)

    $settings = Get-AvmBamiSettings -Values $Settings
    return @{
        tenant_id = $settings['TEST_BAMI_TENANT_ID']
        controller_client_id = $settings['TEST_BAMI_CONTROLLER_CLIENT_ID']
        bicep_client_id = $settings['TEST_BAMI_BICEP_CLIENT_ID']
        admin_subscription_id = $settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID']
        persistent_subscription_id = $settings['TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID']
        management_group_id = $settings['TEST_BAMI_MANAGEMENT_GROUP_ID']
        identity_resource_group_name = $settings['TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME']
        test_subscription_ids = ConvertFrom-AvmTestTenantJson -Json $settings['TEST_BAMI_SUBSCRIPTION_IDS']
    }
}

function Assert-AvmRetiredRepositoryIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Changes,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings,
        [Parameter(Mandatory)] [string] $Repository
    )

    $identityAddress = 'module.azure[0].azapi_resource.identity'
    $identities = @($Changes | Where-Object { $_['address'] -ceq $identityAddress })
    if ($identities.Count -ne 1) {
        throw [System.InvalidOperationException]::new('Partial retired-tenant state requires operator inventory; no objects may be silently forgotten.')
    }
    $identity = $identities[0]['change']['before']
    $tenant = [guid]::Empty
    $principal = [guid]::Empty
    if ($identity -isnot [System.Collections.IDictionary] -or
        $identity['output'] -isnot [System.Collections.IDictionary] -or
        $identity['output']['properties'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Retired state requires the original identity ownership evidence.')
    }
    $properties = $identity['output']['properties']
    $parentPattern = '^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/[^/]+$'
    if (-not [guid]::TryParseExact([string]$properties['tenantId'], 'D', [ref]$tenant) -or
        $tenant -eq [guid]::Empty -or $tenant.ToString() -ieq $Settings['TEST_BAMI_TENANT_ID'] -or
        -not [guid]::TryParseExact([string]$properties['principalId'], 'D', [ref]$principal) -or
        $principal -eq [guid]::Empty -or
        $identity['parent_id'] -cnotmatch $parentPattern -or
        $identity['parent_id'].StartsWith("/subscriptions/$($Settings['TEST_BAMI_ADMIN_SUBSCRIPTION_ID'])/", [StringComparison]::OrdinalIgnoreCase) -or
        $identity['type'] -cne 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' -or
        $identity['name'] -cne (Get-AvmTestIdentityName -Repository $Repository -Legacy) -or
        $identity['id'] -ine "$($identity['parent_id'])/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($identity['name'])") {
        throw [System.InvalidOperationException]::new('Only the original repository identity in a different, retired tenant may be forgotten; live BAMI ownership must be transferred.')
    }
    foreach ($change in $Changes) {
        $before = $change['change']['before']
        if ($change['mode'] -cne 'managed' -or (@($change['change']['actions']) -join ',') -cne 'forget' -or
            $null -ne $change['change']['after'] -or $before -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new('Retired-tenant entries may only be forgotten without refresh or destruction.')
        }
        if ($change['address'] -ceq $identityAddress -and $change['type'] -ceq 'azapi_resource') { continue }
        if ($change['address'] -ceq 'module.azure[0].azuread_group_member.example' -and
            $change['type'] -ceq 'azuread_group_member' -and $before['member_object_id'] -ieq $principal.ToString()) {
            $group = [guid]::Empty
            if ([guid]::TryParseExact([string]$before['group_object_id'], 'D', [ref]$group) -and $group -ne [guid]::Empty) { continue }
        }
        if ($change['type'] -ceq 'azapi_resource' -and
            $change['address'] -cmatch '^module\.azure\[0\]\.azapi_resource\.(identity_federated_credentials\["(pr-check|integration-test|examples-test|avm-validation)"\]|validation_federated_credential(\[0\])?|federated_credentials\["(module-(pr-check|integration-test|examples-test|avm-validation)|validation)"\])$' -and
            $before['type'] -cin @(
                'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-07-31-preview',
                'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-01-31-preview'
            ) -and
            $before['parent_id'] -ieq $identity['id']) { continue }
        if ($change['address'] -cin @('module.azure[0].azapi_resource.identity_role_assignment', 'module.azure[0].azapi_resource.identity_role_assignment[0]') -and
            $change['type'] -ceq 'azapi_resource' -and
            $before['type'] -ceq 'Microsoft.Authorization/roleAssignments@2022-04-01' -and
            $before['body'] -is [System.Collections.IDictionary] -and $before['body']['properties'] -is [System.Collections.IDictionary] -and
            $before['body']['properties']['principalId'] -ieq $principal.ToString() -and
            $before['body']['properties']['roleDefinitionId'] -ceq '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635' -and
            $before['body']['properties']['principalType'] -ceq 'ServicePrincipal') { continue }
        throw [System.InvalidOperationException]::new('Retired state contains an unexpected address or ownership binding; operator review is required.')
    }
}

function Assert-AvmRepositorySyncPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Plan,
        [AllowNull()] [System.Collections.IDictionary] $Settings,
        [AllowNull()] [object] $Repository,
        [string] $RepositorySyncRepositoryId,
        [string[]] $EntraGroupNames = @(),
        [AllowNull()] [System.Collections.IDictionary] $ExistingIdentity,
        [Parameter(Mandatory)] [string] $JobWorkflowPath,
        [string[]] $ResourceTypesThatCannotBeDestroyed = @('github_repository')
    )

    if ($Plan['errored'] -eq $true -or ($Plan.Contains('complete') -and $Plan['complete'] -ne $true) -or
        $Plan['resource_changes'] -isnot [System.Collections.IList] -or
        $Plan['planned_values'] -isnot [System.Collections.IDictionary] -or
        $Plan['planned_values']['root_module'] -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new('Repository Terraform plan is incomplete or errored.')
    }
    $resources = @(Get-AvmTerraformPlannedResource -Module $Plan['planned_values']['root_module'])
    $addresses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $retired = [System.Collections.Generic.List[object]]::new()
    foreach ($change in $Plan['resource_changes']) {
        if ($change -isnot [System.Collections.IDictionary] -or $change['address'] -isnot [string] -or
            $change['change'] -isnot [System.Collections.IDictionary] -or -not $addresses.Add($change['address'])) {
            throw [System.InvalidOperationException]::new('Repository plan contains missing or ambiguous resource changes.')
        }
        if ($change['change']['actions'] -contains 'delete' -and $change['type'] -in $ResourceTypesThatCannotBeDestroyed) {
            throw [System.InvalidOperationException]::new("Repository plan would destroy protected resource '$($change['address'])'.")
        }
        if ($change['address'].StartsWith('module.azure[0].', [StringComparison]::Ordinal)) {
            $provider = if ($change['type'] -ceq 'azapi_resource') { 'registry.terraform.io/azure/azapi' } else { 'registry.terraform.io/hashicorp/azuread' }
            if ($change['provider_name'] -cne $provider) {
                throw [System.InvalidOperationException]::new('Retired state has an unexpected provider binding.')
            }
            $retired.Add($change)
            continue
        }
        if ($change['address'].StartsWith('module.github.', [StringComparison]::Ordinal) -and
            $change['type'] -cmatch '^github_' -and $change['provider_name'] -ceq 'registry.terraform.io/integrations/github') { continue }
        if ($null -ne $Settings -and $change['address'].StartsWith('module.bami[0].', [StringComparison]::Ordinal) -and
            (($change['type'] -cmatch '^azapi_' -and $change['provider_name'] -ceq 'registry.terraform.io/azure/azapi') -or
                ($change['type'] -cmatch '^azuread_' -and $change['provider_name'] -ceq 'registry.terraform.io/hashicorp/azuread'))) { continue }
        throw [System.InvalidOperationException]::new('Repository plan contains an unexpected resource address or provider binding.')
    }
    foreach ($resource in $resources) {
        if ($resource['mode'] -ceq 'data') { continue }
        if (-not $addresses.Contains($resource['address'])) {
            throw [System.InvalidOperationException]::new('Repository plan omits a managed resource change.')
        }
    }
    if ($null -eq $Settings) {
        if ($retired.Count -gt 0) {
            throw [System.InvalidOperationException]::new('Repository creation cannot retire identity state.')
        }
        return
    }
    $githubChanges = @($Plan['resource_changes'] | Where-Object { $_['address'] -ceq 'module.github.github_repository.this' })
    if ($githubChanges.Count -ne 1 -or $githubChanges[0]['mode'] -cne 'managed' -or $githubChanges[0]['type'] -cne 'github_repository') {
        throw [System.InvalidOperationException]::new('Repository plan must include exactly the verified GitHub repository.')
    }
    $expectedRepository = @{
        name = $Repository.full_name.Split('/')[1]
        full_name = $Repository.full_name
        repo_id = [string]$Repository.id
    }
    foreach ($side in @('before', 'after')) {
        $values = $githubChanges[0]['change'][$side]
        if ($side -ceq 'before' -and $null -eq $values) { continue }
        if ($values -isnot [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new('Repository plan has incomplete GitHub ownership values.')
        }
        foreach ($field in $expectedRepository.Keys) {
            if ($side -ceq 'before' -and $field -cne 'repo_id') { continue }
            $unknown = $githubChanges[0]['change']['after_unknown']
            if ($side -ceq 'after' -and $field -cne 'name' -and
                $unknown -is [System.Collections.IDictionary] -and $unknown[$field] -eq $true) { continue }
            if ([string]$values[$field] -cne $expectedRepository[$field]) {
                throw [System.InvalidOperationException]::new('Repository plan would manage a different GitHub repository; inspect backend ownership.')
            }
        }
    }
    if ($retired.Count -gt 0) {
        Assert-AvmRetiredRepositoryIdentityPlan -Changes $retired.ToArray() -Settings $Settings -Repository $Repository.full_name
    }
    $identityPlan = @{
        errored = $false
        resource_changes = @($Plan['resource_changes'] | Where-Object { $_['address'].StartsWith('module.bami[0].', [StringComparison]::Ordinal) })
        planned_values = @{ root_module = @{ resources = @($resources | Where-Object { $_['address'].StartsWith('module.bami[0].', [StringComparison]::Ordinal) }) } }
        prior_state = $Plan['prior_state']
    }
    Assert-AvmBamiIdentityPlan -Plan $identityPlan -Settings $Settings -Repository $Repository.full_name `
        -RepositoryId ([string]$Repository.id) -RepositoryOwnerId ([string]$Repository.owner.id) `
        -RepositorySyncRepositoryId $RepositorySyncRepositoryId `
        -EntraGroupNames $EntraGroupNames -ExistingIdentity $ExistingIdentity -JobWorkflowPath $JobWorkflowPath `
        -ModuleAddress 'module.bami[0]'
}
