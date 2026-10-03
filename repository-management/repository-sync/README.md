# Repository-sync state in TME

Repository sync manages GitHub configuration and Azure test identities. Its
Terraform state can live in TME without moving those identities or changing the
AzAPI/AzureAD providers' tenant.

[State infrastructure](../../../infra/README.md) provisions the TME resource
group, storage account, container, and federated state-only managed identity.
Terraform AVM creates the infrastructure once using disposable local bootstrap
state. That bootstrap state is separate from the live repo-sync state blobs.

## Authentication and configuration

The identity and storage settings below are GitHub **`avm` environment variables**, not secrets.

| Settings | Purpose |
| --- | --- |
| Eight `TEST_BAMI_*` values | BAMI identity provisioning and validated test settings |
| `ARM_BACKEND_CLIENT_ID`, `ARM_BACKEND_TENANT_ID`, `ARM_BACKEND_SUBSCRIPTION_ID` | TME state-only identity |
| `ARM_BACKEND_STORAGE_ACCOUNT_NAME`, `ARM_BACKEND_STORAGE_CONTAINER_NAME` | TME state location, selected with the state identity |

Set all five `ARM_BACKEND_*` values together. The workflow and sync command
reject missing or partial backend configuration before repository mutations;
provider identity and storage aliases are not fallbacks. The shared backend
is required for normal BAMI sync. Direct calls to
`Invoke-RepositorySync.ps1` must supply `stateTenantId`, `stateSubscriptionId`,
`stateClientId`, `stateStorageAccountName`, and `stateContainerName`.
Repository-creation mode continues to use a local backend without these values.

The sync script passes the complete backend configuration through `terraform init
-backend-config`, together with Entra/OIDC authentication and disabled CLI/MSI
fallback. This works with released Terraform: these workflow variables do not
require native Terraform support for backend-specific environment variables.

The runtime no longer accepts a state resource-group name. Entra/OIDC access
uses the standard blob endpoint with `lookup_blob_endpoint=false`, and
blob-lease recovery uses account/container/blob names. The deployed resource
group is still needed for bootstrap and management commands, not runtime state
access.

Only non-secret identifiers and authentication flags are persisted in backend
configuration and plans. GitHub provides fresh OIDC tokens for both identities;
never pass tokens, SAS credentials, or account keys through `-backend-config`.
The state UAMI trusts the same repository-ID/`avm` environment subject as the
existing provider UAMI, in its own tenant.

Azure CLI logs in as the state identity for blob-lease recovery. Providers use
the verified BAMI tenant, administration subscription, and controller from the
settings bundle; old `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`
and legacy subscription/group inputs are no longer source requirements.
State recovery forwards the
state subscription explicitly. Keep workflow concurrency at one active run and
do not run another state writer outside that workflow.

Pause this workflow through GitHub's workflow disable control, not a repository
variable. Disabling stops manual dispatch as well as automatic runs.
Re-enabling permits scheduled and repository-dispatch applies too; obtain
approval for that consequence before running manual canaries.

## BAMI candidate identities

The central `testTenant` default selects BAMI for all repositories discovered by
Terraform sync, including new and otherwise unlisted repositories. The legacy
tenant is retired; normal sync explicitly rejects that selection instead of
accessing an old provider. There is no additional activation variable or
script parameter. Normal sync requires the
[complete BAMI bundle](../README.md#test-tenant-selection)
before cleanup, Terraform, or repository mutations. GitHub Actions executions
require the trusted Tools repository and `refs/heads/main`. Repository creation
does not provision or publish test identities.

All BAMI-selected repositories attempt preparation during normal trusted-main
syncs, including scheduled and repository-dispatch applies. Manual `plan_only` still
defaults to `true`; `false` permits the existing coupled candidate-identity apply
and consumer-secret update. Sync does not run module deployment tests.

The [candidate root](bami-identity/main.tf) reuses the Azure identity module
only for selected repositories. Each candidate has its own
`bami-identities/<tenantGuid>/<repoId>.tfstate` key in the **same configured TME
backend**. The ordinary `<repoId>.tfstate` root now manages GitHub configuration
only; it consumes the verified candidate tuple instead of executing the retired
Azure module. Backend keys and `ARM_BACKEND_*` settings are unchanged.

Plan-only never applies to obtain a client ID. If the candidate ID is still
unknown or any identity, federation, or membership change is pending, the run
reports `PendingCandidateIdentity` and leaves the consumer update pending.
Apply uses only a saved plan checked for the complete bounded identity,
federation, provider, and group scope. Identity replacements and unrelated
deletes remain forbidden; only the exact permission migration/revocation
below is allowed. Failed or uncertain applies do not trigger automatic state
repair, state imports, or apply retries.

After validation, both paths log an allow-listed candidate-plan summary:
repository and tenant identifiers, the identity, four federation credentials,
every configured membership, and bounded migration/revocation actions.
It includes observed group names/IDs and membership scopes;
obsolete Owner deletions also show the previous scope, principal, and
delegation condition. Unknown and sensitive fields are marked explicitly. The summary
excludes raw plans, state, variables, output documents, and credentials; it
uploads no artifact.
This diagnostic grants no approval and changes no cutover gate. A later apply
generates and validates its own saved plan, not the earlier preview binary.

Before any operator-approved BAMI run, verify the bootstrap group's Owner
assignment retains the
[nondelegation condition](https://github.com/Azure/azure-verified-modules-tools/pull/111):
Owner, User Access Administrator, and RBAC Administrator are denied with
`ForAnyOfAllValues:GuidNotEquals` in both write and delete clauses,
`conditionVersion = "2.0"`. Verify controller federation, identity/FIC
permissions, and configured-name group read/membership access. Controller directory-role
assignment alone does not establish Graph API readiness; offline checks do
not prove the role-only route or effective live permissions.

Coordinate approved reconciliation through the serialized sync workflow.
Explicit `ARM_*_OVERRIDE` values and environment-level secrets retain their
existing consumer precedence; audit them when verifying a repository's effective
test identity. Do not run another writer outside the serialized sync workflow.
Do not change the backend, move state, grant permissions, or reuse the
controller as an execution identity to bypass a failed prerequisite.

## BAMI group access and migration

Flat `repositoryGroups[].entraGroups` arrays contain arbitrary Entra group display
names. Matching groups are ordered by `order`, then declaration, and their names
accumulate with exact-name deduplication. A repository-specific list adds to
defaults; an empty list does not remove inherited memberships.
Terraform resolves each name uniquely in the selected BAMI tenant. Missing,
ambiguous, nonsecurity, or directory-dynamic groups that cannot accept individual
membership updates fail explicitly. Repository sync manages
only each dedicated test identity's membership edges, never the shared groups'
complete membership lists or their Azure/directory role assignments.
The candidate's private `test_group_contract` output exposes only observed
provider identifiers and allow-listed group metadata, not group members,
owners, or credentials. `test_identity` and consumer secrets are unchanged.

The checked-in default and Fabric selection are:

```json
[
  {
    "name": "default",
    "repositories": ["*"],
    "entraGroups": ["avm-test-entra-readers", "avm-test-identity-owners"]
  },
  {
    "name": "fabric",
    "repositories": ["avm-ptn-unified-data-platform"],
    "entraGroups": ["avm-test-fabric-admins"]
  }
]
```

The unified-data-platform identity therefore gets all three memberships; other
repositories get the two defaults. Removing a name from all matching groups
removes only that repository's edge on an approved apply. Group object IDs are
looked up anew, so Terraform-owned group recreation refreshes/replaces those
edges without a publisher change. There is no fixed group-ID interface or
`testCapabilities` flag.
`avm-bootstrap-fabric-admins` is not a consumer group. Tenant registration,
licensing, first portal access, and Fabric tenant settings remain bootstrap
operator work outside repository sync.

BAMI creates no direct Owner assignment. A future approved saved plan destroys
only the obsolete deterministic
Owner assignment for the same repository principal, pinned management group,
role, and resource ID. Keep the controller's existing Owner-assignment deletion
permission until this migration finishes. Old singleton readers edges and
name-keyed memberships can be removed/replaced only for the same repository
principal. No live BAMI role or membership is forgotten with
`removed { destroy = false }`; whole-group reconciliation is never used.

The separate ordinary-root `retired-identity.tf` forgets only `module.azure`
state from the already-nonexistent legacy tenant. That explicitly approved
retirement avoids old resource refresh, data-source reads, and destruction;
it does not touch the isolated live BAMI identity root or state backend.
Terraform 1.9+ is required. The local gate proves this with disposable mock
state: seven original objects produce only `forget` actions, retain their
before-values, and have no refresh/data-read trace. A seed `command = apply`
is permitted only inside that fully mocked Terraform test, never as a live
apply or actual state operation.

Bootstrap prerequisites and the shared group assignment are delivered in
[azure-cloud-native/Azure-Verified-Modules-Tooling-BAMI#43](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Tooling-BAMI/pull/43).
Team operating guidance is maintained in
[azure-cloud-native/Azure-Verified-Modules-Docs#52](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/52).
Merging source does not authorize a workflow run, apply, variable publication,
or Fabric activation; coordinate those separately with the bootstrap owner.

## Isolated branch testing

After an approved snapshot copy, test the migration branch explicitly with all
five backend variables set for that snapshot, without changing provider settings:

```powershell
$migrationRef = 'YOUR-MIGRATION-BRANCH'
gh workflow run repository-management-sync.yml --repo Azure/azure-verified-modules-tools `
    --ref $migrationRef -f repositories=avm-ptn-example-repo `
    -f plan_only=true -f sync_project_items=false
```

Use **plan-only**. Separate variables isolate configuration, not the resources
tracked by the two state copies. Never apply from both copies. A snapshot
becomes stale if the original sync writes again; copy fresh state during the
final freeze rather than treating an old test copy as authoritative.

## Cutover (operator only)

Do not run these commands without approval for the production change. Use
PowerShell 7.4+, Azure CLI, GitHub CLI, and access to both tenants. The account
performing the copy needs Blob Data Reader on the old container and Blob Data
Contributor on the new container. Provision access separately; do not grant the
runtime state identity cross-tenant or provider-management permissions.

1. Deploy the [Terraform AVM bootstrap](../../../infra/README.md). Save its
   `workflowVariables` output to `infra/tme.outputs.json` before discarding the
   local bootstrap state. This non-secret file contains the five backend environment
   values and is ignored by Git. For an already-deployed bootstrap with no local
   file, use the infrastructure README's read-only output recovery commands.
   Leave provider and test-tenant variables unchanged.
1. Before merging the tools change, disable the workflow
   and agree that no other
   operators will run manual sync or Terraform during the copy:

   ```powershell
   gh workflow disable repository-management-sync.yml --repo Azure/azure-verified-modules-tools
   gh run list --repo Azure/azure-verified-modules-tools --workflow repository-management-sync.yml --limit 100
   ```

   Wait for **all** active, waiting, and queued runs to finish. Do not cancel a
   state writer or break a lease to speed up the migration.
   Keep the workflow disabled until the copy and merge are complete.
1. Run the copy below from the repository root on a trusted machine. It refuses
   a populated destination, leased source blobs, unexpected blob names, and
   byte mismatches. Keep the protected local backup until cutover succeeds.
   Never upload state backups or plans as workflow artifacts or commit them.

   ```powershell
   $ErrorActionPreference = 'Stop'
   $PSNativeCommandUseErrorActionPreference = $true
   $repo = 'Azure/azure-verified-modules-tools'
   $sourceSubscription = '90ac8d2f-cfce-452a-89ae-d7a73caf7fdf'
   $sourceTenant = '13b2a159-de04-4835-a3ad-fd814c6adb4f'
   $sourceAccount = 'stoe2etestingmodulestate'
   $sourceContainer = 'tfstate'
   $targetSubscription = 'c7fedf3b-cbde-4f68-8c81-7a0313adfc21'
   $targetTenant = '70a036f6-8e4d-4615-bad6-149c02e7720d'
   $settings = Get-Content -Raw .\infra\tme.outputs.json | ConvertFrom-Json
   if ($settings.ARM_BACKEND_SUBSCRIPTION_ID -ne $targetSubscription -or
       $settings.ARM_BACKEND_TENANT_ID -ne $targetTenant) {
     throw 'Bootstrap outputs do not match the approved TME target.'
   }
   $backup = Join-Path $PWD "out/state-migration-$([guid]::NewGuid())"
   $null = New-Item -ItemType Directory -Path "$backup/source", "$backup/readback"
   gh variable list --repo $repo --env avm --json name,value |
     Set-Content "$backup/original-variables.json"

   function Get-StateBlobs([string]$Account, [string]$Container, [string]$Subscription) {
     $json = az storage blob list --account-name $Account --container-name $Container `
       --subscription $Subscription --auth-mode login --num-results '*' `
       --query '[].{name:name,etag:properties.etag,size:properties.contentLength,lease:properties.lease.status}' -o json
     return @($json | ConvertFrom-Json)
   }
   function Get-StateHashes([string]$Folder) {
     Get-ChildItem -LiteralPath $Folder -File | ForEach-Object {
       [pscustomobject]@{ Name = $_.Name; Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
     }
   }

   az login --tenant $sourceTenant --output none
   az account set --subscription $sourceSubscription
   $source = @(Get-StateBlobs $sourceAccount $sourceContainer $sourceSubscription)
   if ($source.Count -eq 0) { throw 'Source is empty; stop the migration.' }
   if (@($source | Where-Object { $_.lease -eq 'locked' }).Count) { throw 'Source has leased blobs.' }
   if (@($source | Where-Object { $_.name -notmatch '^[A-Za-z0-9._-]+\.tfstate$' }).Count) {
     throw 'Unexpected blob names/workspaces; review the inventory before copying.'
   }
   $source | ConvertTo-Json | Set-Content "$backup/source-inventory.json"
   az storage blob download-batch --source $sourceContainer --destination "$backup/source" `
     --account-name $sourceAccount --subscription $sourceSubscription --auth-mode login --output none
   $hashes = @(Get-StateHashes "$backup/source")
   if ($hashes.Count -ne $source.Count) { throw 'Incomplete download.' }
   $hashes | ConvertTo-Json | Set-Content "$backup/source-hashes.json"

   az login --tenant $targetTenant --output none
   az account set --subscription $targetSubscription
   $targetAccount = $settings.ARM_BACKEND_STORAGE_ACCOUNT_NAME
   $targetContainer = $settings.ARM_BACKEND_STORAGE_CONTAINER_NAME
   if (@(Get-StateBlobs $targetAccount $targetContainer $targetSubscription).Count) {
     throw 'Destination is not empty; do not overwrite an existing state.'
   }
   az storage blob upload-batch --source "$backup/source" --destination $targetContainer `
     --account-name $targetAccount --subscription $targetSubscription --auth-mode login --overwrite false --output none
   az storage blob download-batch --source $targetContainer --destination "$backup/readback" `
     --account-name $targetAccount --subscription $targetSubscription --auth-mode login --output none
   $readback = @(Get-StateHashes "$backup/readback")
   if ($readback.Count -ne $hashes.Count -or (Compare-Object $hashes $readback -Property Name,Hash)) {
     throw 'Destination content differs from the source backup.'
   }

   az account set --subscription $sourceSubscription
   $currentSource = @(Get-StateBlobs $sourceAccount $sourceContainer $sourceSubscription)
   if (Compare-Object $source $currentSource -Property name,etag,size,lease) {
     throw 'Source changed during migration; do not cut over.'
   }
   $settings | ConvertTo-Json | Set-Content "$backup/target-variables.json"
   ```

   This copies the current state bytes, preserving Terraform lineage, serial,
   and resource IDs. It does not migrate historical versions, snapshots, or
   leases; retain the source account for historical recovery. If interrupted,
   leave automatic sync paused and reconcile the destination against the saved
   manifest rather than blindly rerunning or overwriting blobs.
1. Still disabled, inspect `target-variables.json`, then set or confirm only the
   five backend values:

   ```powershell
   $backendVariableNames = @(
     'ARM_BACKEND_CLIENT_ID', 'ARM_BACKEND_TENANT_ID', 'ARM_BACKEND_SUBSCRIPTION_ID',
     'ARM_BACKEND_STORAGE_ACCOUNT_NAME', 'ARM_BACKEND_STORAGE_CONTAINER_NAME'
   )
   foreach ($name in $backendVariableNames) {
     if ([string]::IsNullOrWhiteSpace($settings.$name)) { throw "Missing $name." }
   }
   foreach ($name in $backendVariableNames) {
     gh variable set $name --repo $repo --env avm --body ([string]$settings.$name)
   }
   ```

   Leave the BAMI settings bundle, management group, identity resource group, and test
   subscription variables unchanged. No state migration flags are needed during
   normal init: fresh workflow checkouts select the copied state by the unchanged
   `<repoId>.tfstate` key.
   Merge the reviewed tools change under the cutover approval. Re-enable the
   workflow only after approval also covers scheduled/repository-dispatch
   applies, and coordinate the manual canary outside the scheduled run times:

   ```powershell
   gh workflow enable repository-management-sync.yml --repo $repo
   ```
1. Run a manual plan-only canary from `main`. The enabled workflow can also run
   automatically; do not assume this is a manual-only window:

   ```powershell
   gh workflow run repository-management-sync.yml --repo $repo --ref main `
     -f repositories=avm-ptn-example-repo -f plan_only=true -f sync_project_items=false
   ```

   Review the plan and state account/tenant. Reject unexpected resource
   recreation, changed provider tenant, missing state, or identity replacements.
   Check every copied blob against the manifest, not just the canary. Existing
   drift may still appear in the plan; migration itself must not change resource
   IDs. A successful plan exercises blob leases; never test recovery by breaking
   a live lease.
1. After approval, run the same canary with `plan_only=false`. Confirm its state
   is updated in TME and provider resources remain in the original tenant.
   Disable the workflow again if automatic writes must stop; re-enabling is
   the control for resuming them.

   Retain the old account and its versions for the agreed recovery period.
   Securely remove the local state copies after approval. Record the final
   storage inventory and runbook in
   [Azure-Verified-Modules-Docs](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs).

## Rollback

Pause automatic sync and drain all writers again. **Before any apply has written
to TME**, set all five `ARM_BACKEND_*` values to the original state tenant,
subscription, client, storage account, and container from the approved migration
record. Do not unset them or rely on provider settings or storage aliases.
Keep sync disabled while updating the values so no run sees a partial
configuration. Confirm a canary plan before resuming.

**After an apply has written to TME, the old blobs are stale.** Do not simply
point the workflow back. Export the latest TME state, verify lineage/serial and
hashes, and perform an explicitly approved reverse copy into the old container
while both sides are quiescent. Preserve old versions, verify a readback, then
switch configuration and confirm a plan. Never force-push state, edit its JSON,
or run against an empty container to recover.
