# Repository-sync state in TME

Repository sync manages GitHub configuration and Azure test identities. Its
Terraform state can live in TME without moving those identities or changing the
AzAPI/AzureAD providers' tenant.

[State infrastructure](../../../infra/README.md) provisions the TME resource
group, storage account, container, and federated state-only managed identity.
Terraform AVM creates the infrastructure once using disposable local bootstrap
state. That bootstrap state is separate from the live repo-sync state blobs.

## Authentication and configuration

All runtime settings below are GitHub **`avm` environment variables**, not secrets.

| Settings | Purpose |
| --- | --- |
| `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` | Existing provider identity and Azure resource targets; do not change these during migration |
| `ARM_BACKEND_CLIENT_ID`, `ARM_BACKEND_TENANT_ID`, `ARM_BACKEND_SUBSCRIPTION_ID` | State-only identity; set all three together |
| `STORAGE_ACCOUNT_NAME`, `STORAGE_ACCOUNT_RESOURCE_GROUP_NAME`, `STORAGE_ACCOUNT_CONTAINER_NAME` | State location |

With no backend identity variables, existing authentication is unchanged. A
partial or invalid identity is rejected before repository mutations. The sync
script passes the complete backend identity through `terraform init
-backend-config`, together with Entra/OIDC authentication and disabled CLI/MSI
fallback. This works with released Terraform: these workflow variables do not
require native Terraform support for backend-specific environment variables.

Only non-secret identifiers and authentication flags are persisted in backend
configuration and plans. GitHub provides fresh OIDC tokens for both identities;
never pass tokens, SAS credentials, or account keys through `-backend-config`.
The state UAMI trusts the same repository-ID/`avm` environment subject as the
existing provider UAMI, in its own tenant.

Azure CLI logs in as the state identity for blob-lease recovery, while providers
continue using the existing `ARM_*` environment. State recovery forwards the
state subscription explicitly. Keep workflow concurrency at one active run and
do not run another state writer outside that workflow.

`AVM_SYNC_PAUSED` is a **repository variable**, not an `avm` environment variable.
When its value is `true`, scheduled and repository-dispatch runs are skipped.
Manual runs remain available for operator-controlled canaries. Other workflows
and module test identities are unaffected.

## Cutover (operator only)

Do not run these commands without approval for the production change. Use
PowerShell 7.4+, Azure CLI, GitHub CLI, and access to both tenants. The account
performing the copy needs Blob Data Reader on the old container and Blob Data
Contributor on the new container. Provision access separately; do not grant the
runtime state identity cross-tenant or provider-management permissions.

1. Deploy the [Terraform AVM bootstrap](../../../infra/README.md). Save its
   `workflowVariables` output to `infra/tme.outputs.json` before discarding the
   local bootstrap state. This non-secret file contains the six new environment
   values. Do not configure them yet.
2. Merge the tools change, then pause automatic sync and agree that no other
   operators will run manual sync or Terraform during the copy:

   ```powershell
   gh variable set AVM_SYNC_PAUSED --repo Azure/azure-verified-modules-tools --body true
   gh run list --repo Azure/azure-verified-modules-tools --workflow repository-management-sync.yml --limit 100
   ```

   Wait for **all** active, waiting, and queued runs to finish. Do not cancel a
   state writer or break a lease to speed up the migration.
3. Run the copy below from the repository root on a trusted machine. It refuses
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
   $targetAccount = $settings.STORAGE_ACCOUNT_NAME
   $targetContainer = $settings.STORAGE_ACCOUNT_CONTAINER_NAME
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
4. Still paused, inspect `target-variables.json`, then set its six values:

   ```powershell
   foreach ($setting in $settings.PSObject.Properties) {
     gh variable set $setting.Name --repo $repo --env avm --body ([string]$setting.Value)
   }
   ```

   Leave provider `ARM_*`, management group, identity resource group, and test
   subscription variables unchanged. No state migration flags are needed during
   normal init: fresh workflow checkouts select the copied state by the unchanged
   `<repoId>.tfstate` key.
5. Run a manual plan-only canary from `main` while automated sync remains paused:

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
6. After approval, run the same canary with `plan_only=false`. Confirm its state
   is updated in TME and provider resources remain in the original tenant.
   Then remove `AVM_SYNC_PAUSED` to resume normal scheduled sync:

   ```powershell
   gh variable delete AVM_SYNC_PAUSED --repo $repo
   ```

   Retain the old account and its versions for the agreed recovery period.
   Securely remove the local state copies after approval. Record the final
   storage inventory and runbook in
   [Azure-Verified-Modules-Docs](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs).

## Rollback

Pause automatic sync and drain all writers again. **Before any apply has written
to TME**, restore the three original `STORAGE_ACCOUNT_*` variables and remove all
three `ARM_BACKEND_*_ID` variables together. Use the saved original-variable file
and confirm a canary plan before resuming.

**After an apply has written to TME, the old blobs are stale.** Do not simply
point the workflow back. Export the latest TME state, verify lineage/serial and
hashes, and perform an explicitly approved reverse copy into the old container
while both sides are quiescent. Preserve old versions, verify a readback, then
switch configuration and confirm a plan. Never force-push state, edit its JSON,
or run against an empty container to recover.
