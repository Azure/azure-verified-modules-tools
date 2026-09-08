# One-shot Terraform AVM state bootstrap

Creates new TME infrastructure for repository-sync state. It does not move live
state, change GitHub variables, or give the backend identity provider permissions.
The AzAPI/AzureAD providers used by repo sync remain in their existing tenant.

| Setting | Default |
| --- | --- |
| Subscription | `c7fedf3b-cbde-4f68-8c81-7a0313adfc21` |
| Tenant | `70a036f6-8e4d-4615-bad6-149c02e7720d` |
| Region | `westus3` (West US 3) |
| Resource group | `rg-avm-repository-sync-state-tme` |
| Storage account | `stavmstate` plus 14 deterministic SHA-256 characters |
| Container | `tfstate` |
| UAMI | `id-avm-repository-sync-state-tme` |

The bootstrap uses these pinned [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/):

- [Resource group 0.4.0](https://registry.terraform.io/modules/Azure/avm-res-resources-resourcegroup/azurerm/0.4.0)
- [Storage account 0.10.0](https://registry.terraform.io/modules/Azure/avm-res-storage-storageaccount/azurerm/0.10.0)
- [Managed identity 0.5.2](https://registry.terraform.io/modules/Azure/avm-res-managedidentity-userassignedidentity/azurerm/0.5.2)

## Storage and identity

StorageV2, Standard_ZRS, and Hot tier. Shared-key authentication and anonymous
blob access are disabled; OAuth is the default. Both providers use the explicit
TME tenant/subscription, and AzureRM is configured for Entra data-plane access.
Local users, SFTP, NFS, hierarchical namespace, and cross-tenant replication are
disabled. Transport requires HTTPS and TLS 1.2 or newer.

The public endpoint is reachable by GitHub-hosted runners, but requests still
need Entra-authorized access. Private networking would need a separate runner
design. The UAMI receives **Storage Blob Data Contributor on the state container
only**. No subscription/account Reader or provider-management role is granted.
AVM manages containers and their roles through ARM; bootstrap itself does not
need a blob data-plane role.

The UAMI trusts this exact existing GitHub OIDC subject:

```text
issuer:   https://token.actions.githubusercontent.com
subject:  repository_owner_id:6844498:repository_id:1239632211:environment:avm
audience: api://AzureADTokenExchange
```

Blob versioning, seven-day blob/container soft delete, and a default-on
`CanNotDelete` account lock protect recovery. The management lock does not
prevent data-plane blob deletion. Versioning is not an independent backup and
previous versions do not expire automatically.

## Validate without deploying

Use PowerShell 7.4+, Terraform 1.10 or newer, and the repository's build runner:

```powershell
.\build.ps1 infra
```

This runs `fmt -check`, downloads the pinned modules and providers satisfying
their version constraints with the backend disabled, and runs `validate`. It
does not plan or apply Azure changes. Terraform generates a local provider lock
file during init. That lock file, `tme.outputs.json`, `.terraform`, plans, and
state are ignored by Git and must not be committed. CI initializes its own lock
file on each fresh checkout.

## Deploy once

Do not run deployment without approval. Use a clean PowerShell session with no
leftover Terraform CI credentials, then authenticate to TME with Azure CLI.
The deploying account needs resource-group creation, resource deployment,
role-assignment write, and lock write permissions. Reader or Contributor alone
is insufficient. Storage and ManagedIdentity providers must already be registered.

Run from the repository root:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$tenantId = '70a036f6-8e4d-4615-bad6-149c02e7720d'
$subscriptionId = 'c7fedf3b-cbde-4f68-8c81-7a0313adfc21'

az login --tenant $tenantId --output none
$account = az account show --subscription $subscriptionId -o json | ConvertFrom-Json
if ($account.id -ne $subscriptionId -or $account.tenantId -ne $tenantId) {
    throw 'Wrong subscription or tenant. Do not deploy.'
}

terraform -chdir=infra init -input=false
terraform -chdir=infra plan -input=false '-out=bootstrap.tfplan'
```

Review the plan: only new resources in the dedicated West US 3 group should be
created. Verify shared-key/public-blob access are disabled, the federation
subject is exact, and RBAC is container-scoped. Stop if the group/account already
exists or the plan would change unrelated resources. Resource names are stable,
but deleting local state does **not** make subsequent applies idempotent.

After approval of that plan:

```powershell
terraform -chdir=infra apply -input=false bootstrap.tfplan
$settingsJson = terraform -chdir=infra output -json workflowVariables
$settings = $settingsJson | ConvertFrom-Json
if ($settings.ARM_BACKEND_SUBSCRIPTION_ID -ne $subscriptionId -or
    $settings.ARM_BACKEND_TENANT_ID -ne $tenantId) {
    throw 'Unexpected bootstrap outputs. Keep state and investigate.'
}
$settingsJson | Set-Content -LiteralPath .\infra\tme.outputs.json -Encoding utf8NoBOM

az storage account show --subscription $subscriptionId `
    --resource-group $settings.STORAGE_ACCOUNT_RESOURCE_GROUP_NAME `
    --name $settings.STORAGE_ACCOUNT_NAME `
    --query '{name:name,location:location,sharedKeys:allowSharedKeyAccess,publicBlobs:allowBlobPublicAccess,httpsOnly:enableHttpsTrafficOnly}' -o json
az identity federated-credential list --subscription $subscriptionId `
    --resource-group $settings.STORAGE_ACCOUNT_RESOURCE_GROUP_NAME `
    --identity-name id-avm-repository-sync-state-tme -o json
```

Confirm Entra-only settings, versioning/soft delete, the exact federated subject,
and container-scoped role assignment before cleanup. Allow for role/federation
propagation. These infrastructure checks do not replace a later sync canary.

## Discard bootstrap state, not the infrastructure

This is deliberately fire-and-forget: local state is needed only while Terraform
creates the infrastructure. **First save and retain `tme.outputs.json`**, which
contains only identifiers needed for cutover, not Terraform state or secrets.
Keep it locally; it is deliberately excluded from source control.
Then, after successful deployment and verification:

```powershell
Remove-Item -LiteralPath .\infra\terraform.tfstate, .\infra\bootstrap.tfplan
if (Test-Path -LiteralPath .\infra\terraform.tfstate.backup) {
    Remove-Item -LiteralPath .\infra\terraform.tfstate.backup
}
Remove-Item -LiteralPath .\infra\.terraform -Recurse
```

Never run `terraform destroy` as cleanup. Do not delete state after an interrupted
or failed apply: keep it until the partial deployment is reconciled. Once state
is discarded, maintain resources through Azure or import them (including any
module-generated role-assignment IDs) before using Terraform again.

The bootstrap state is **not** the repository-sync state. Do not delete, overwrite,
or discard the state blobs used by the existing sync workflow.

## Cutover handoff

`workflowVariables`/`tme.outputs.json` contains:

- `ARM_BACKEND_CLIENT_ID`, `ARM_BACKEND_TENANT_ID`, `ARM_BACKEND_SUBSCRIPTION_ID`
- `STORAGE_ACCOUNT_NAME`, `STORAGE_ACCOUNT_RESOURCE_GROUP_NAME`, `STORAGE_ACCOUNT_CONTAINER_NAME`

These are workflow inputs translated into non-secret `-backend-config` settings
by the repo-sync script; released Terraform is sufficient. Do not update GitHub
variables just because bootstrap succeeded. Follow the
[state cutover and rollback runbook](../repository-management/repository-sync/README.md)
under a separate migration approval.

Record the retained infrastructure and non-secret outputs in
[Azure-Verified-Modules-Docs](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs)
when documenting the operational handoff.

## Deployed bootstrap

The approved bootstrap was deployed to West US 3. Storage account
`stavmstate92172623a0c0c6` and UAMI `id-avm-repository-sync-state-tme` are in
`rg-avm-repository-sync-state-tme`. The non-secret handoff values are kept locally
in `infra/tme.outputs.json`, not in the repository.

Local bootstrap state and the apply plan were discarded after verification.
Do not apply this configuration again without importing the existing resources.
Live repo-sync state has not been copied and its GitHub configuration is unchanged.

If the local output file is missing, reconstruct it using read-only Azure queries
instead of applying the bootstrap again. Sign in to the TME tenant first, then
run from the repository root:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$subscriptionId = 'c7fedf3b-cbde-4f68-8c81-7a0313adfc21'
$resourceGroup = 'rg-avm-repository-sync-state-tme'
$identity = az identity show --subscription $subscriptionId `
    --resource-group $resourceGroup --name id-avm-repository-sync-state-tme -o json |
    ConvertFrom-Json
$accountName = az storage account show --subscription $subscriptionId `
    --resource-group $resourceGroup --name stavmstate92172623a0c0c6 --query name -o tsv
if ($identity.tenantId -ne '70a036f6-8e4d-4615-bad6-149c02e7720d') {
    throw 'Unexpected identity tenant.'
}
@{
    ARM_BACKEND_CLIENT_ID = $identity.clientId
    ARM_BACKEND_TENANT_ID = $identity.tenantId
    ARM_BACKEND_SUBSCRIPTION_ID = $subscriptionId
    STORAGE_ACCOUNT_NAME = $accountName
    STORAGE_ACCOUNT_RESOURCE_GROUP_NAME = $resourceGroup
    STORAGE_ACCOUNT_CONTAINER_NAME = 'tfstate'
} | ConvertTo-Json | Set-Content -LiteralPath .\infra\tme.outputs.json -Encoding utf8NoBOM
```
