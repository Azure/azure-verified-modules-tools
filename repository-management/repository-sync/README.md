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
| `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` | Existing provider identity and Azure resource targets; do not change these during migration |
| `ARM_BACKEND_CLIENT_ID`, `ARM_BACKEND_TENANT_ID`, `ARM_BACKEND_SUBSCRIPTION_ID` | TME state-only identity |
| `ARM_BACKEND_STORAGE_ACCOUNT_NAME`, `ARM_BACKEND_STORAGE_CONTAINER_NAME` | TME state location, selected with the state identity |

Set all five `ARM_BACKEND_*` values together. The workflow and sync command
reject missing or partial backend configuration before repository mutations;
provider identity and storage aliases are not fallbacks. The shared backend
is required for both legacy and BAMI test tenants. Direct calls to
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

Azure CLI logs in as the state identity for blob-lease recovery, while providers
continue using the existing `ARM_*` environment. State recovery forwards the
state subscription explicitly. Keep workflow concurrency at one active run and
do not run another state writer outside that workflow.

Pause this workflow through GitHub's workflow disable control, not a repository
variable. Disabling stops manual dispatch as well as automatic runs.
Re-enabling permits scheduled and repository-dispatch applies too; obtain
approval for that consequence before running manual canaries.

## BAMI candidate identities

The central `testTenant` selection determines which repositories use BAMI;
there is no additional activation variable or script parameter. BAMI-selected
repositories require the [complete BAMI bundle](../README.md#test-tenant-selection)
before cleanup, Terraform, or repository mutations. In GitHub Actions they also
require the trusted Tools repository and `refs/heads/main`. Legacy selections
retain their normal path without requiring BAMI values.

Selected canaries attempt BAMI preparation during normal trusted-main syncs,
including scheduled and repository-dispatch applies. Manual `plan_only` still
defaults to `true`; `false` permits the existing write path. Selecting `legacy`
in configuration restores the legacy consumer tuple, rather than merely
pausing the BAMI path.

The [candidate root](bami-identity/main.tf) reuses the Azure identity module
only for selected repositories. Each candidate has its own
`bami-identities/<tenantGuid>/<repoId>.tfstate` key in the **same configured TME
backend**. The legacy `<repoId>.tfstate`, `module.azure[0]`, provider `ARM_*`,
and `ARM_BACKEND_*` settings remain unchanged. Switching
the central selection back to `legacy` restores legacy consumer secrets
without touching candidate identities or state. A later candidate tenant uses
a different internal key; it does not replace the previous tenant's identities.

Plan-only never applies to obtain a client ID. If the candidate ID is still
unknown, the run reports `PendingCandidateIdentity` and leaves the consumer
update pending. Apply uses only a saved plan checked for the complete bounded
identity scope, no deletes/replacements, and the required delegation deny
condition. Failed or uncertain applies do not trigger automatic state repair,
state imports, or apply retries.

Before any operator-approved BAMI run, verify the
[Owner delegation fix](https://github.com/Azure/azure-verified-modules-tools/pull/111)
has landed: Owner, User Access Administrator, and RBAC Administrator must all
be denied for delegation in both write and delete clauses. The current
candidate plan guard rejects the older condition. Verify controller federation,
identity/FIC permissions, constrained management-group role assignment, and
lookup/membership access to
`grp-sec-avm-tf-end-to-end-testing-entra-readers`. The group exists in BAMI, but
controller directory-role assignment alone does not establish Graph API
readiness; lookup and membership operations remain unproved.

Keep scheduled sync paused while approving the first repository-scoped plan
and cutover. Explicit `ARM_*_OVERRIDE` values and environment-level secrets
retain their existing consumer precedence; audit them before activating a
canary. Do not run another writer outside the serialized sync workflow.
Do not change the backend, move state, grant permissions, or reuse the
controller as an execution identity to bypass a failed prerequisite.

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

   Leave provider `ARM_*`, management group, identity resource group, and test
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
