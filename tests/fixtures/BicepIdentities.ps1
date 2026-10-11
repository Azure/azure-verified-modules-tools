function New-AvmTestBicepIdentityContext {
    [pscustomobject]@{ RepositoryId = '447791597'; OrganizationId = '6844498'; ToolsRepositoryId = '1239632211' }
}

function New-AvmTestBicepIdentityModules {
    [ordered]@{
        'avm/res/fabric/capacity' = @('avm-test-entra-readers', 'avm-test-management-group-owners')
        'avm/res/storage/storage-account' = @(
            'avm-test-entra-readers', 'avm-test-management-group-owners', 'avm-test-management-group-iam-admins'
        )
    }
}

function New-AvmTestBicepIdentityPlan {
    param(
        [switch] $KnownClient,
        [switch] $NamingMigration,
        [System.Collections.IDictionary] $Modules = (New-AvmTestBicepIdentityModules)
    )

    $plan = @{
        errored = $false
        complete = $true
        resource_changes = @()
        planned_values = @{ root_module = @{ child_modules = @() } }
        prior_state = @{ values = @{ root_module = @{ child_modules = @() } } }
    }
    $number = 0
    foreach ($path in $Modules.Keys) {
        $slice = New-AvmTestBamiPlan -KnownClient:$KnownClient -GroupNames $Modules[$path] `
            -NamingMigration:$NamingMigration -PreviousIdentityName (Get-AvmTestIdentityName -ModulePath $path -Legacy) `
            -PreviousClientId ('10000000-0000-4000-8000-{0:d12}' -f (106 + $number)) `
            -PreviousPrincipalId ('10000000-0000-4000-8000-{0:d12}' -f (107 + $number)) `
            -ModuleAddress "module.bicep[`"$path`"]" -RepositoryId '447791597' `
            -IdentityName (Get-AvmBicepModuleIdentityName -ModulePath $path) -Environments @('avm-validation') `
            -ClientId ('10000000-0000-4000-8000-{0:d12}' -f (6 + $number)) `
            -PrincipalId ('10000000-0000-4000-8000-{0:d12}' -f (7 + $number)) `
            -JobWorkflowRef 'Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main' `
            -WorkflowRef "Azure/bicep-registry-modules/.github/workflows/$($path.Replace('/', '.')).yml@refs/heads/main"
        $plan.resource_changes += $slice.resource_changes
        $plan.planned_values.root_module.child_modules += $slice.planned_values.root_module.child_modules
        $plan.prior_state.values.root_module.child_modules += $slice.prior_state.values.root_module.child_modules
        $number += 10
    }
    return $plan
}

function New-AvmTestBicepIdentityMigration {
    $settings = Get-AvmBamiSettings -Values (New-AvmTestBamiSettings)
    $modules = New-AvmTestBicepIdentityModules
    return [ordered]@{
        schemaVersion = 1
        context = Get-AvmBicepIdentityPublicationContext
        before = Assert-AvmBicepIdentityPlan -Plan (New-AvmTestBicepIdentityPlan -NamingMigration) `
            -Settings $settings -Modules $modules -Context (New-AvmTestBicepIdentityContext) -PassThru
        after = New-AvmTestBicepIdentityOutputs
    }
}

function New-AvmTestBicepIdentityOutputs {
    param([System.Collections.IDictionary] $Modules = (New-AvmTestBicepIdentityModules))

    $plan = New-AvmTestBicepIdentityPlan -KnownClient -Modules $Modules
    $identities = [ordered]@{}
    foreach ($module in $plan.planned_values.root_module.child_modules) {
        $path = [regex]::Match($module.address, '^module\.bicep\["([^"]+)"\]$').Groups[1].Value
        $identity = @($module.resources | Where-Object { $_.address.EndsWith('.azapi_resource.identity') })[0].values
        $identities[$path] = @{
            tenant_id = $identity.output.properties.tenantId
            client_id = $identity.output.properties.clientId
            identity_resource_id = $identity.id
        }
    }
    return $identities
}

function New-AvmTestSizedBicepClientIds {
    param([int] $ByteCount = 49152)

    $base = [ordered]@{}
    foreach ($number in 1..600) {
        $base['avm/res/test/module-{0:d4}' -f $number] = '30000000-0000-4000-8000-{0:d12}' -f $number
    }
    $remaining = $ByteCount - [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $base -Compress))
    if ($remaining -lt 0) { throw 'Requested fixture size is too small.' }
    $result = [ordered]@{}
    foreach ($path in $base.Keys) {
        $padding = [Math]::Min(68 - $path.Length, $remaining)
        $result[$path + ('x' * $padding)] = $base[$path]
        $remaining -= $padding
    }
    if ($remaining -ne 0) { throw 'Requested fixture size is too large.' }
    return $result
}
