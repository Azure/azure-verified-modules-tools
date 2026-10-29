# Bicep test identities

The existing [Bicep Sync workflow](../../.github/workflows/repository-management-bicep-sync.yml)
provisions one dedicated user-assigned managed identity per source-backed
root Bicep module. It discovers `avm/{res,ptn,utl}/{namespace}/{module}/main.bicep`
from the registry's trusted `main` checkout, including roots without their own
workflow. Child modules share their root identity. Registry source is inventory
data only; the provisioning job never executes its scripts or actions.

Identity resources and individual Entra membership edges use the same
[Azure Terraform module](../repository-sync/terraform/modules/azure) as Terraform
repository sync. Bicep has one state key, `bicep-module-identities.tfstate`, in
the existing backend. The job uses the five `ARM_BACKEND_*` settings for the
state-only identity and the existing eight-field BAMI bundle for provisioning.
Only the identity job can request OpenID Connect (OIDC) tokens; the mapping
publisher uses a separate, target-scoped Actions Variables token.

## Identity names

Bicep uses `id-test-bicep-` followed by the complete canonical root path with
slashes replaced by hyphens. For example, `avm/res/storage/storage-account`
becomes `id-test-bicep-avm-res-storage-storage-account`. There is no hash,
truncation or duplicated `avm` prefix. Child modules do not create another name.

Discovery, the plan guard and Terraform reject flattened-name collisions.
The existing canonical-path limit remains 68 characters; identity names retain
the repository's 90-character bound. These are repository policies, not Azure's
absolute limits: Azure allows [3-128 identity name characters](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules#microsoftmanagedidentity)
and [3-120 federated credential name characters](https://learn.microsoft.com/en-us/azure/templates/microsoft.managedidentity/userassignedidentities/federatedidentitycredentials).
Terraform checks complete credential names, including the `module-` and
`registry-` discriminators.

## Group configuration

[`bicep-config/config.json`](../bicep-config/config.json) mirrors Terraform's
ordered group structure using `moduleGroups[].modules` selectors and flat
`entraGroups` arrays. Selectors are exact canonical module paths or `*`.
Matching group lists accumulate and deduplicate; a later match cannot replace
the defaults. New modules inherit Directory Readers and conditional Owner
through `avm-test-entra-readers` and `avm-test-management-group-owners`.
Additional permissions require an explicit configuration change.

The checked-in exceptions were assessed against registry commit
[`76810a51`](https://github.com/Azure/bicep-registry-modules/tree/76810a51c9f8d25230a0d4f8de66858cc45b617d):

| Selection | Additional group | Reason |
| --- | --- | --- |
| Privileged role-assignment tests | `avm-test-management-group-iam-admins` | Explicit Owner, User Access Administrator or RBAC Administrator assignments cannot be made through conditional Owner. This includes HCI shared dependencies and PIM/sub-vending tests. |
| Six HCI image consumers, including Hybrid Container Service | `avm-test-subscription-persistent-readers` | Read the prebuilt host image in the Persistent subscription. |

Management-group scope alone does not require IAM administration: the default
Owner group already inherits from the test management group. Fabric capacity
currently deploys ARM resources, not Fabric admin APIs, so it retains only the
defaults, like Terraform's Fabric capacity module. The existing Fabric API
group remains available for a future explicit selector when a test requires it.
Role IDs used only as alert recipients or Lighthouse authorization metadata
do not trigger IAM membership.

Persistent Reader does not provide Key Vault secret access, HSM data-plane
permissions, managed-identity assignment rights or network writes. Existing
HCI credentials and persistent HSM/network dependencies still require separate
readiness checks before the consumer cutover; these groups do not claim to
make those tests deployable.

## Mapping and safety

After applying one verified saved plan, the job validates every output's
module identity resource ID, tenant and unique client ID. It publishes
`VALIDATE_MODULE_CLIENT_IDS` as compact JSON:

```json
{"avm/res/storage/storage-account":"00000000-0000-4000-8000-000000000001"}
```

Client IDs are not credentials. The publisher checks the actual UTF-8 size
against the 48 KiB variable limit and refuses empty, incomplete, duplicate,
shared/controller or arbitrarily retargeted bindings. It uses a request file rather than
putting the mapping on the command line. Existing variables are protected by
the shared pre-write and readback checks; unacknowledged writes are never
retried or rolled back automatically.

### Subscription-vending billing scope handoff

When the exact `avm/ptn/lz/sub-vending` selector remains configured and the
complete bootstrap-owned vending identity tuple verifies, the variable sync
publishes the `avm` environment secret `VALIDATE_MODULE_BILLING_SCOPES` in the
Bicep Registry. Its compact JSON value contains only that canonical root and
its invoice-section resource ID. If the selector is removed, it publishes
`{}` so a previous scope cannot be reused. The value is provided to `gh` on
standard input from an ephemeral workspace file, never as an argument or log
value.

The Bicep Registry workflow must select this secret only by the canonical
`avm/ptn/lz/sub-vending` root, then fall back to its legacy Key Vault lookup.
No generic management-group selector or CI Key Vault/permission change is
part of this handoff.

The plan guard rejects foreign state, unrelated identity deletion or replacement, direct
role assignments, moved/imported identities, widened federation and incomplete
group/provider evidence. Removing a configured membership is allowed only for
that module's verified principal. Missing modules stop the run rather than
destroying their identities. After verification, `terraform show -no-color`
displays the saved plan's resource actions and attribute differences in the
job log, including plan-only runs. Apply streams resource progress as it
happens. Both streams use the shared credential redactor; ordinary identity
names and client IDs stay visible and Terraform's sensitive-value markers
remain intact. Saved plan files, machine-readable plan/output JSON and raw
state remain private. No state repair, force-unlock or automatic apply retry
is used.

### Existing identity naming transition

The sole naming exception replaces the exact former
`id-avm-bicep-<flattened-path>-<hash8>` identity with its computed hash-free name
for the same module and tenant. The legacy suffix is still checked against the
first eight lowercase SHA-256 characters of the original canonical path.
Before allowing replacement, the guard verifies the old resource, tenant,
dedicated client/principal and existing repository/caller federation. All
retained credentials and membership edges must move to the new identity;
only the verified old principal's edges can be removed. Renaming itself
does not broaden permissions or change the configured federation subjects.

The identity step supplies `-IdentityMigrationPath` for a separate, unused
job-local JSON file. After the saved plan succeeds and outputs are validated,
that file records the verified old and applied new identity tuples, bound to
the Tools repository ID, workflow ref, commit, run ID and attempt. The publisher
accepts only matching evidence from that same trusted run. Existing module
bindings must equal either the verified old client or the already-published
new client; third values, removed modules, stale evidence and reused clients
are rejected. Other execution values remain unchanged except for the separate
[same-inventory subscription-tag update](../README.md#bicep-variable-publication):
the complete identity bundle must match, subscription order/IDs/names cannot
change, and an untagged historical source cannot erase a reservation.

This file relies on the trusted job's local-file boundary, like the mapping
output; it is not a signed artifact or an operator-supplied rebinding override.
Plan-only and failed apply/output validation produce neither consumable file.
Do not replace an existing evidence file or run a second writer. If apply
succeeds but the job loses its evidence before publication, a later run cannot
reconstruct ownership of a deleted identity: routine rebinding fails closed.
Stop for separately approved recovery using preserved plan/state evidence;
do not synthesize evidence, roll back automatically or blindly retry a write.

This narrow replacement/publication exception requires recorded SFI sign-off
before merge. Source changes do not authorize a live apply or publication.
Coordinate the first approved reconciliation with active test runs because
identity replacement changes client IDs and invalidates the old federation.

## Registry authentication and separate cutover

Registry and Tools use `include_claim_keys` in this order:
`repository_owner_id`, `repository_id`, `context`. Neither workflow claim is
included. The producer adds one `<identity>-registry-avm-validation` credential
per module for the registry's current subject:

```text
repository_owner_id:{Azure ID}:repository_id:{registry ID}:environment:avm-validation
```

The issuer remains `https://token.actions.githubusercontent.com`, and the sole
audience is `api://AzureADTokenExchange`. This uses the existing federation API;
no flexible credential, GitHub subject change or tools-SHA-bound credential is
needed. Future workflow restrictions are a separate change.

The same registry subject is accepted by every module identity. Strict workflow
selection of `VALIDATE_MODULE_CLIENT_IDS` is therefore a code-level control,
not federated isolation between modules. Ordinary and generic/bulk test runs
select the canonical root's client for both Azure CLI and PowerShell; child
modules share that entry. Existing opt-in labels and internal-fork controls
remain unchanged, including generic pull-request runs.

The existing `<identity>-module-avm-validation` staged credential remains
unchanged:

```text
repository_owner_id:{Azure ID}:repository_id:{registry ID}:environment:avm-validation:job_workflow_ref:Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main:workflow_ref:Azure/bicep-registry-modules/.github/workflows/{module.path}.yml@refs/heads/main
```

The distinct `<identity>-avm-validation` credential still binds the Tools
repository ID, not the registry, and cannot substitute for registry
authentication. The producer leaves `VALIDATE_CLIENT_ID`, the shared
`id-avm-bicep` identity, its federation and permissions untouched.

Source qualification and branch publication do not apply these credentials or
prove live login readiness. The main-only scheduled identity reconciliation can
apply them after merge; coordinate that merge/apply separately, before an
approved registry cutover to the qualified tools SHA and package version.
Changing the tools pin later does not require federation restaging under this
three-claim subject. Retire the shared identity only after a separately approved
complete cutover.

## Local checks

```powershell
.\build.ps1 test,component -TestName '*Bicep*', 'Configured repository Entra memberships'
.\build.ps1 test-tenant-terraform
.\build.ps1 pre-commit
```

The Terraform task uses mocked providers only. It runs the actual Bicep root's
plan through the production ownership guard and checks the applied mapping,
checks both ecosystems' legacy replacement plans and unchanged subsequent
Bicep plans, without provisioning Azure resources or editing GitHub variables.
