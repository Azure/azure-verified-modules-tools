# Terraform lifecycle operations: workspace cleanup, init, import-bootstrap,
# plan, and apply (with retry).

# Removes per-run artifacts from the Terraform module directory so each repo
# starts from a known-clean state. Skipped when the caller passes
# `-skipCleanup` to the sync script (useful for local debugging).
function Clear-TerraformWorkspace {
    param([string]$terraformModulePath)

    if (Test-Path "$terraformModulePath/.terraform") {
        Remove-Item "$terraformModulePath/.terraform" -Recurse -Force
    }
    if (Test-Path "$terraformModulePath/terraform.tfvars.json") {
        Remove-Item "$terraformModulePath/terraform.tfvars.json" -Force
    }
    if (Test-Path "$terraformModulePath/terraform.tfstate") {
        Remove-Item "$terraformModulePath/terraform.tfstate" -Force
    }
    if (Test-Path "$terraformModulePath/.terraform.lock.hcl") {
        Remove-Item "$terraformModulePath/.terraform.lock.hcl" -Force
    }
    if (Test-Path "$terraformModulePath/imports.tf") {
        Remove-Item "$terraformModulePath/imports.tf" -Force
    }
}

function Resolve-RepositorySyncStateIdentity {
    param(
        [string]$TenantId,
        [string]$SubscriptionId,
        [string]$ClientId
    )

    $values = @($TenantId, $SubscriptionId, $ClientId)
    $configured = @($values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($configured.Count -eq 0) {
        return $null
    }
    if ($configured.Count -ne 3) {
        throw [System.ArgumentException]::new(
            'Set all three state identity values (tenant, subscription, client), or leave all three unset.'
        )
    }
    foreach ($value in $values) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($value, [ref]$id) -or $id -eq [guid]::Empty) {
            throw [System.ArgumentException]::new('State identity values must be non-empty GUIDs.')
        }
    }

    return [pscustomobject]@{
        TenantId = ([guid]$TenantId).ToString()
        SubscriptionId = ([guid]$SubscriptionId).ToString()
        ClientId = ([guid]$ClientId).ToString()
    }
}

function Resolve-RepositorySyncStateConfiguration {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Backend
    )

    $names = @('TenantId', 'SubscriptionId', 'ClientId', 'StorageAccountName', 'ContainerName')
    $configured = @($names | Where-Object { -not [string]::IsNullOrWhiteSpace($Backend[$_]) })
    if ($configured.Count -ne $names.Count) {
        throw [System.ArgumentException]::new(
            'Set all five backend identity and storage values (tenant, subscription, client, storage account, container).'
        )
    }
    $identity = Resolve-RepositorySyncStateIdentity `
        -TenantId $Backend.TenantId -SubscriptionId $Backend.SubscriptionId -ClientId $Backend.ClientId
    if ($Backend.StorageAccountName -cnotmatch '^[a-z0-9]{3,24}$') {
        throw [System.ArgumentException]::new('The state storage account must have 3-24 lowercase letters or digits.')
    }
    if ($Backend.ContainerName -cnotmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' -or
        $Backend.ContainerName.Contains('--')) {
        throw [System.ArgumentException]::new('The state container must have 3-63 lowercase letters, digits, or single hyphens, with no leading or trailing hyphen.')
    }
    return [pscustomobject]@{
        TenantId = $identity.TenantId
        SubscriptionId = $identity.SubscriptionId
        ClientId = $identity.ClientId
        StorageAccountName = $Backend.StorageAccountName
        ContainerName = $Backend.ContainerName
    }
}

# Runs `terraform init`. In repository-creation mode this is a local-backend
# bootstrap (writes `backend_override.tf` first); otherwise it points at the
# remote AzureRM backend using the supplied state-storage parameters.
function Invoke-TerraformInit {
    param(
        [string]$terraformModulePath,
        [bool]$repositoryCreationModeEnabled,
        [string]$repoId,
        [string]$orgAndRepoName,
        [string]$stateStorageAccountName,
        [string]$stateContainerName,
        [string]$stateTenantId,
        [string]$stateSubscriptionId,
        [string]$stateClientId,
        [array]$issueLog
    )

    if ($repositoryCreationModeEnabled) {
        Set-Content -Path "$terraformModulePath/backend_override.tf" -Value @"
terraform {
    backend "local" {}
}
"@

        $result = Invoke-TerraformWithRetry `
            -commands @(
                @{
                    Arguments = @("init", "-upgrade")
                    OutputLog = "init.log"
                }
            ) `
            -workingDirectory $terraformModulePath `
            -printOutput
    } else {
        $state = Resolve-RepositorySyncStateConfiguration -Backend @{
            TenantId = $stateTenantId
            SubscriptionId = $stateSubscriptionId
            ClientId = $stateClientId
            StorageAccountName = $stateStorageAccountName
            ContainerName = $stateContainerName
        }
        $initArguments = @(
            "init",
            "-upgrade",
            "-backend-config=`"storage_account_name=$($state.StorageAccountName)`"",
            "-backend-config=`"container_name=$($state.ContainerName)`"",
            "-backend-config=`"key=$($repoId).tfstate`"",
            "-backend-config=tenant_id=$($state.TenantId)",
            "-backend-config=subscription_id=$($state.SubscriptionId)",
            "-backend-config=client_id=$($state.ClientId)",
            "-backend-config=use_azuread_auth=true",
            "-backend-config=use_oidc=true",
            "-backend-config=use_cli=false",
            "-backend-config=use_msi=false",
            "-backend-config=lookup_blob_endpoint=false"
        )
        $result = Invoke-TerraformWithRetry `
            -commands @(
                @{
                    Arguments = $initArguments
                    OutputLog = "init.log"
                }
            ) `
            -workingDirectory $terraformModulePath `
            -stateStorageAccountName $state.StorageAccountName `
            -stateContainerName $state.ContainerName `
            -stateBlobName "$($repoId).tfstate" `
            -stateSubscriptionId $state.SubscriptionId `
            -printOutput
    }

    if (!(Test-CommandResultsSucceeded -results $result)) {
        Write-Warning "Terraform init failed for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "init-failed" -message "Terraform init failed for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    return $issueLog
}

# Runs `terraform plan`, parses the resulting plan JSON, applies the
# can-this-be-destroyed gate, and (if safe) runs `terraform apply` with a
# one-shot replan/apply retry on first failure.
function Invoke-TerraformPlanAndApply {
    param(
        [string]$terraformModulePath,
        [string]$repoId,
        [string]$orgAndRepoName,
        [bool]$planOnly,
        [string[]]$resourceTypesThatCannotBeDestroyed,
        [string]$stateStorageAccountName,
        [string]$stateContainerName,
        [string]$stateSubscriptionId,
        [array]$issueLog
    )

    $result = Invoke-TerraformWithRetry `
        -commands @(
            @{
                Arguments = @("plan", "-out=`"$($repoId).tfplan`"")
                OutputLog = "plan.log"
            }
        ) `
        -workingDirectory $terraformModulePath `
        -stateStorageAccountName $stateStorageAccountName `
        -stateContainerName $stateContainerName `
        -stateBlobName "$($repoId).tfstate" `
        -stateSubscriptionId $stateSubscriptionId `
        -printOutput

    if (!(Test-CommandResultsSucceeded -results $result)) {
        Write-Warning "Terraform plan failed for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-failed" -message "Terraform plan failed for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    $plan = $(terraform -chdir="$terraformModulePath" show -json "$($repoId).tfplan") | ConvertFrom-Json

    if (!$plan -or !$plan.resource_changes) {
        Write-Warning "Failed to parse Terraform plan for $orgAndRepoName. Exiting."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-parse-failed" -message "Failed to parse Terraform plan for $orgAndRepoName." -data $null -issueLog $issueLog
        exit 1
    }

    $hasDestroy = $false
    foreach ($resource in $plan.resource_changes) {
        if ($resource.change.actions -contains "delete") {
            if ($resourceTypesThatCannotBeDestroyed -contains $resource.type) {
                Write-Warning "Planning to destroy: $($resource.address). Resource type: $($resource.type) cannot be destroyed, so skipping the apply."
                $hasDestroy = $true
            } else {
                Write-Host "Planning to destroy: $($resource.address). Resource type: $($resource.type) can be destroyed, so allowing the apply to continue."
            }
        }
    }

    if ($hasDestroy) {
        Write-Warning "Skipping: $orgAndRepoName as it has at least one destroy actions."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-includes-destroy" -message "Plan includes destroy for $orgAndRepoName." -data $plan -issueLog $issueLog
    }

    if (!$planOnly -and $plan.errored) {
        Write-Warning "Skipping: Plan failed for $orgAndRepoName."
        $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "plan-failed" -message "Plan failed for $orgAndRepoName." -data $plan -issueLog $issueLog
    }

    if (!$hasDestroy -and !$planOnly -and !$plan.errored) {

        Write-Host "Applying plan for $orgAndRepoName"
        $result = Invoke-TerraformWithRetry `
            -commands @(
                @{
                    Arguments = @("apply", "$($repoId).tfplan")
                    OutputLog = "apply.log"
                }
            ) `
            -workingDirectory $terraformModulePath `
            -stateStorageAccountName $stateStorageAccountName `
            -stateContainerName $stateContainerName `
            -stateBlobName "$($repoId).tfstate" `
            -stateSubscriptionId $stateSubscriptionId `
            -printOutput `
            -maxRetries 0

        if (!(Test-CommandResultsSucceeded -results $result)) {
            Write-Warning "Terraform apply first attempt failed for $orgAndRepoName. Entering plan apply retry loop..."
            $result = Invoke-TerraformWithRetry `
                -commands @(
                    @{
                        Arguments = @("plan", "-out=`"$($repoId).tfplan`"")
                        OutputLog = "plan.log"
                    },
                    @{
                        Arguments = @("apply", "$($repoId).tfplan")
                        OutputLog = "apply.log"
                    }
                ) `
                -workingDirectory $terraformModulePath `
                -stateStorageAccountName $stateStorageAccountName `
                -stateContainerName $stateContainerName `
                -stateBlobName "$($repoId).tfstate" `
                -stateSubscriptionId $stateSubscriptionId `
                -printOutput
        }

        if (!(Test-CommandResultsSucceeded -results $result)) {
            Write-Warning "Terraform apply failed for $orgAndRepoName. Exiting."
            $issueLog = Add-IssueToLog -orgAndRepoName $orgAndRepoName -type "apply-failed" -message "Terraform apply failed for $orgAndRepoName." -data $null -issueLog $issueLog
            exit 1
        } else {
            Write-Host "Terraform apply succeeded for $orgAndRepoName"
        }
    }

    return $issueLog
}
