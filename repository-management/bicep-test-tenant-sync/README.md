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
shared/controller or retargeted bindings. It uses a request file rather than
putting the mapping on the command line. Existing variables are protected by
the shared pre-write and readback checks; unacknowledged writes are never
retried or rolled back automatically.

The plan guard rejects foreign state, identity deletion or replacement, direct
role assignments, moved/imported identities, widened federation and incomplete
group/provider evidence. Removing a configured membership is allowed only for
that module's verified principal. Missing modules stop the run rather than
destroying their identities. Raw plans and output documents are not streamed
to workflow logs. No state repair, force-unlock or automatic apply retry is used.

## Separate consumer cutover

This producer does not change Bicep validation workflows, their OIDC subject
template, or `VALIDATE_CLIENT_ID`. BAMI continues to own and retain the shared
`id-avm-bicep` identity, its federation and permissions.

Each new identity stages a future subject with claims in this order:

```text
repository_owner_id:{Azure ID}:repository_id:{registry ID}:environment:avm-validation:job_workflow_ref:Azure/bicep-registry-modules/.github/workflows/avm.template.module.deployment.yml@refs/heads/main:workflow_ref:Azure/bicep-registry-modules/.github/workflows/{module.path}.yml@refs/heads/main
```

The later cutover must select the client ID by canonical root module path and
emit this exact subject. `workflow_ref` identifies the top-level module caller;
`job_workflow_ref` identifies the shared deployment workflow. Keep both bindings:
the shared workflow alone does not isolate modules. The separate protected
Tools `avm-validation` credential remains available, as for Terraform identities.
Module and Tools credentials have distinct names.
Registry pushes and manual dispatches on `main` match these workflow references;
dispatches on other branches do not. The cutover must preserve that boundary.

Roll out and inspect the producer first, then make the separately reviewed
consumer change and verify actual logins and permissions. Retire the shared
BAMI identity only after that cutover is complete.

## Local checks

```powershell
.\build.ps1 test,component -TestName '*Bicep*', 'Configured repository Entra memberships'
.\build.ps1 test-tenant-terraform
.\build.ps1 pre-commit
```

The Terraform task uses mocked providers only. It runs the actual Bicep root's
plan through the production ownership guard and checks the applied mapping,
without provisioning Azure resources or editing GitHub variables.
