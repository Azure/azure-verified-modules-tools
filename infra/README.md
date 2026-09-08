# Repository-sync Terraform state infrastructure

This Bicep deployment creates **new, dedicated TME infrastructure** for the
repository-sync Terraform backend. It does not reuse BAMI storage or identities,
move state, grant provider deployment permissions, or update GitHub variables.

Only state storage and its authentication move to TME. The `azapi` and `azuread`
providers continue using their existing identity and tenant. Backend access is
independent of provider access.

| Target | Value |
| --- | --- |
| Subscription | `c7fedf3b-cbde-4f68-8c81-7a0313adfc21` |
| Tenant | `70a036f6-8e4d-4615-bad6-149c02e7720d` |
| Default region | `northeurope` |
| Resource group | `rg-avm-repository-sync-state-tme` |
| Storage account | `stavmstate` plus a deterministic 13-character suffix |
| Container | `tfstate` |
| Backend identity | `id-avm-repository-sync-state-tme` |

The account suffix derives from the deployment subscription ID and resource group
name. Reusing those inputs gives the same account name; changing them selects a
different backend. Names are overridable, but use a dedicated resource group and
account rather than pointing this template at unrelated existing resources.
Storage account names must be globally unique, with 3-24 lowercase letters or
digits. Container names must have 3-63 lowercase letters, digits, or hyphens,
without leading, trailing, or consecutive hyphens.

## Resources and safeguards

`main.bicep` runs at subscription scope to create the resource group.
`modules/state-backend.bicep` runs in that group and creates:

- A `StorageV2`, `Standard_ZRS`, Hot-tier account, encrypted at rest with
  Microsoft-managed keys. Zone redundancy protects against zone failures, not
  loss of the whole region.
- A Blob service with versioning and blob/container soft delete. Retention
  defaults to seven days and can be increased up to 365 days.
- A private `tfstate` container. Anonymous access, shared-key authentication,
  cross-tenant object replication, local users, SFTP, NFS, and hierarchical
  namespace are disabled. All traffic requires HTTPS with TLS 1.2 or newer.
- A user-assigned managed identity with **Storage Blob Data Contributor only on
  this container**. No account/subscription Reader role or provider permissions
  are granted. The standard Blob endpoint supports
  `lookup_blob_endpoint=false`; endpoint lookup is not required.
- One GitHub federated identity credential with an exact subject, not wildcard
  or repository-name matching:

  ```text
  issuer:   https://token.actions.githubusercontent.com
  subject:  repository_owner_id:6844498:repository_id:1239632211:environment:avm
  audience: api://AzureADTokenExchange
  ```

  The repository must retain its existing custom, ID-based OIDC subject
  configuration, and the job must use the `avm` environment and have
  `id-token: write`. The two numeric repository IDs are parameters;
  the environment remains exactly `avm`.
- An optional, default-on `CanNotDelete` management lock on the account. This
  protects the account and inherited ARM resources from deletion, **not blobs
  from data-plane deletion**. Blob leases and normal Terraform writes remain
  possible. Setting `enableDeleteLock=false` in a later incremental deployment
  does not remove an existing lock; removal is a separate, approved operation.

The public endpoint deliberately permits network access from GitHub-hosted
`ubuntu-latest` runners. Public networking is not anonymous data access:
Microsoft Entra authentication and container RBAC are still required. A private
endpoint would require a separate runner-network design. There is no trusted
service firewall bypass, and no Key Vault, diagnostic workspace, or automatic
lifecycle deletion policy is added in this slice.

Versioning retains previous versions until they are explicitly removed; the
seven-day soft-delete setting is not an expiry policy for those versions.
Monitor capacity/version growth and agree a recovery window before introducing
cleanup. These safeguards are not an independent backup against privileged
deletion or regional disaster. Use the subscription's existing monitoring and
governance controls; review additional recovery and diagnostic requirements with
the TME owner before production cutover.

## Validate locally

From the repository root, use the existing build entry point:

```powershell
.\build.ps1 infra
```

This compiles `infra/main.bicep` and `infra/main.bicepparam` into `out/infra` using
Azure CLI's Bicep compiler. It does not contact Azure for deployment
validation or deploy resources. Keep generated ARM JSON out of source control.

Review `main.bicepparam` before deployment. Its subscription and tenant comments
are documentation, **not deployment guards**. Azure CLI's selected subscription
and the explicit `--subscription` argument determine the deployment target.

## Operator deployment

These commands are a runbook, not an automated deployment. Do not execute the
create step until the target, resource plan, and what-if have been approved.

Prerequisites:

- Azure CLI with Bicep support. For the `.bicepparam`-only deployment syntax below,
  use Azure CLI 2.53.0 or newer and Bicep CLI 0.22.6 or newer.
- Access to the target subscription in the TME tenant. The deploying principal
  needs subscription-level resource-group creation and deployment permissions,
  resource creation/update permissions in the dedicated group, and
  `Microsoft.Authorization/roleAssignments/write` for the container assignment.
  With the default lock, it also needs
  `Microsoft.Authorization/locks/write`. Contributor alone cannot assign roles
  or create locks. An appropriately scoped combination of deployment and
  authorization roles, or an approved Owner assignment, is needed.
- The `Microsoft.Storage` and `Microsoft.ManagedIdentity` providers must be
  registered. The TME owner must confirm current regional/SKU availability,
  account quota, allowed locations, and applicable Azure Policy requirements.
  North Europe is the default, not a guarantee of capacity or policy acceptance.
  Select another approved ZRS-capable region before initial deployment if needed.
- Confirm the deterministic storage name is available and the what-if creates
  only the dedicated resources. Stop if it would modify unrelated resources.

Run from the repository root in PowerShell. Check **both** subscription and
tenant; a successful login alone is not sufficient:

```powershell
$tenantId = '70a036f6-8e4d-4615-bad6-149c02e7720d'
$subscriptionId = 'c7fedf3b-cbde-4f68-8c81-7a0313adfc21'
$deploymentName = 'avm-repository-sync-state-tme'
$deploymentLocation = 'northeurope'

az login --tenant $tenantId
if ($LASTEXITCODE -ne 0) { throw 'TME login failed.' }
az account set --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { throw 'TME subscription selection failed.' }
$accountJson = az account show --subscription $subscriptionId --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the deployment account.' }
$account = $accountJson | ConvertFrom-Json
if ($account.id -ne $subscriptionId -or $account.tenantId -ne $tenantId) {
    throw 'Wrong subscription or tenant. Do not deploy.'
}

az deployment sub what-if `
    --subscription $subscriptionId `
    --name $deploymentName `
    --location $deploymentLocation `
    --parameters .\infra\main.bicepparam
if ($LASTEXITCODE -ne 0) { throw 'What-if failed. Do not deploy.' }
```

The deployment location stores deployment metadata; `location` in
`main.bicepparam` places the resources. Keep both deliberate. An existing
deployment name cannot be reused at a different deployment location.

After reviewing and approving the what-if, rerun the account guard if the shell
context has changed, then deploy:

```powershell
az deployment sub create `
    --subscription $subscriptionId `
    --name $deploymentName `
    --location $deploymentLocation `
    --parameters .\infra\main.bicepparam
if ($LASTEXITCODE -ne 0) { throw 'Infrastructure deployment failed.' }

az deployment sub show `
    --subscription $subscriptionId `
    --name $deploymentName `
    --query properties.outputs.workflowVariables.value `
    --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read deployment outputs.' }
```

The `.bicepparam` file links to `main.bicep` with `using`; do not prefix its path
with `@`. Allow time for new role assignments and federation to propagate before
testing authenticated access. A successful ARM deployment does not prove the
GitHub OIDC subject or data-plane access works.

## Outputs and GitHub environment handoff

`workflowVariables` is a **non-secret** output map for the operator:

| Variable in the existing GitHub `avm` environment | Deployment output value |
| --- | --- |
| `ARM_BACKEND_CLIENT_ID` | New backend managed identity's client ID |
| `ARM_BACKEND_TENANT_ID` | Tenant containing the new managed identity |
| `ARM_BACKEND_SUBSCRIPTION_ID` | Deployment subscription ID |
| `STORAGE_ACCOUNT_NAME` | New storage account name |
| `STORAGE_ACCOUNT_RESOURCE_GROUP_NAME` | Dedicated resource group name |
| `STORAGE_ACCOUNT_CONTAINER_NAME` | State container name |

The three `ARM_BACKEND_*` names are **this repository's workflow inputs**. The
repository-sync script translates their non-secret values into explicit
Terraform `-backend-config` identity settings, using released Terraform. This
does not depend on Terraform automatically recognizing these names, an
unreleased environment-suffix feature, or any upstream fixed-prefix change.
Leave the providers' existing identity configuration unchanged.

Additional outputs expose `resourceGroupId`, `storageAccountId`,
`stateContainerId`, `backendIdentityId`, `blobEndpoint`, and `federatedSubject`
for verification. No access keys, tokens, connection strings, state content,
or GitHub changes are produced by the template.

**Do not configure these variables merely because deployment succeeded.** Follow
the [repository-sync migration runbook](../repository-management/repository-sync/README.md)
for the freeze, authenticated state copy, verification, coordinated variable
cutover, and rollback. Existing behavior stays in place until the operator
explicitly enables the new backend.

## References

- [Blob Storage Well-Architected guidance](https://learn.microsoft.com/azure/well-architected/service-guides/azure-blob-storage)
- [ARM resource naming rules](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules)
- [Blob data role assignments and propagation](https://learn.microsoft.com/azure/storage/blobs/assign-azure-role-data-access)
- [GitHub workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity)
- [Blob versioning and soft delete](https://learn.microsoft.com/azure/storage/blobs/versioning-overview)
- [Storage account management locks](https://learn.microsoft.com/azure/storage/common/lock-account-resource)
- [Bicep deployment with Azure CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-cli)
