# Non-resource-group Bicep end-to-end safety design

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Propose an isolation and teardown contract for subscription-, management-group-,
and tenant-scoped Bicep deployments. This is a design only: `avm test e2e`
continues to reject all three scopes. Neither tenant-wide access nor automatic
deletion of higher-level targets is approved by this document.

## Existing registry CI baseline

The [registry module workflow](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff/.github/workflows/avm.template.module.yml)
passes a configured test-subscription pool, tenant ID and management-group ID
to its [deployment action](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff/.github/actions/templates/avm-validateModuleDeployment/action.yml).
That action selects an **existing** subscription, logs in, replaces tokens,
validates and deploys resource-group, subscription, management-group or tenant
examples, and runs post-deployment Pester when reached. It does **not** create
a fresh subscription or tenant for each run.

With `removeDeployment` enabled (the default), its removal step runs on
success or failure **when deployment names were emitted**. It calls
[`Initialize-DeploymentRemoval`](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff/utilities/pipelines/e2eValidation/resourceRemoval/Initialize-DeploymentRemoval.ps1),
which uses the attempted names. The
[resource discovery helper](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff/utilities/pipelines/e2eValidation/resourceRemoval/helper/Get-DeploymentTargetResourceList.ps1)
recursively follows deployment operations across scopes; the
[removal helper](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff/utilities/pipelines/e2eValidation/resourceRemoval/helper/Remove-Deployment.ps1)
orders resolved IDs for deletion and excludes known system resources. This
is the **behavioral parity baseline**, not evidence of an exclusive target,
ownership proof for every resolved resource, or recovery when CI terminates
before removal. The new CLI must not claim parity merely by implementing
only the stronger subset below.

## Proposed safety enhancement: isolated targets

| Scope | Dedicated target and ownership proof | Permitted teardown and access |
| --- | --- | --- |
| Subscription | A pre-provisioned, exclusive nonproduction test subscription, identified explicitly by tenant and subscription ID, with a per-case lease and run ID. Require absence of conflicting case resources, `Create`-only what-if, and exact IDs from deployment operations; verify live run-ID tags where supported and otherwise unique names plus the lease/manifest. This is stricter than selecting a subscription from the existing CI pool. | Delete only individually recorded, owned resources and groups in reverse dependency order. Never delete the subscription or modify an existing resource. The test identity needs deployment, read, write and delete actions only for reviewed resource types in this subscription; provisioning the subscription is a separate privileged action. |
| Management group | A new, uniquely named child of a designated **nonproduction** parent, created by a provisioning identity and assigned exclusively to one test. Verify its ID, parent, creation record and run ID; assert no pre-existing policies or descendants and never attach production subscriptions. | Remove only confirmed test resources, then delete the child group **only when empty**. The deployment identity needs deployment and type-specific rights on the child; a separate identity needs limited parent-group creation and child deletion rights. Never delete/move the parent or an existing subscription. |
| Tenant | A pre-provisioned, separate test tenant with a pinned tenant ID and exclusive test identity; a production tenant is never an eligible target. Require a reviewed allowlist of tenant resource types, exact new IDs and a persisted run manifest. The baseline instead uses a configured tenant. | Remove exact owned objects; never delete the tenant or its root group automatically. Tenant-scope deployment requires `Microsoft.Resources/deployments/*` plus the resource type's actions at `/` **inside that test tenant**. Role assignments require Owner at `/`, so RBAC, subscription aliases, billing and other privileged tenant resources remain unsupported pending a separate review. |

Subscription- and management-group-scoped Bicep files can deploy nested
modules to other scopes, including the tenant. A top-level scope check is
insufficient: inspect every nested deployment and resource type; reject linked,
dynamic, cross-target, lock, authorization, script and uninspectable operations
until each has a reviewed ownership and inverse-operation policy. An inherited
test credential must not have write access outside its isolated target.

## Proposed lifecycle before enabling a new scope

1. Bind the identity, explicit target ID, lease and run ID; verify an exclusive
   lease on a pre-provisioned subscription or tenant, or a newly created test
   child management group, and record a durable manifest outside the source
   repository. Refuse shared or unknown targets, including any deployment
   name already present at a different location.
1. Compile all selected examples before cloud operations. ARM validate and
   what-if must predict only `Create` operations on allowlisted types at the
   isolated target. Record exact expected IDs and fail closed if they differ
   from deployment-operation records or live resources.
1. Run case-local assertions only after a verified successful deployment.
   In `finally`, compare the current target, parentage, lease and each live
   object's type/ID/owner marker against the manifest; delete only exact
   proven-owned IDs in reverse order and verify absence. Unknown ownership,
   unsuccessful deletion or interrupted credentials must yield a failure with
   `CleanupPending` IDs; do not start the next case.
1. A separate recovery mechanism must handle process termination, machine
   loss and interrupted CI, when `finally` cannot run. It must apply the same
   proof checks, retain its audit trail and quarantine ambiguous resources
   for **manual** review rather than bulk deleting a subscription, management
   group hierarchy or tenant.

## Review decisions and remaining boundary

Decide whether the new CLI should first match the existing configured-target
and deployment-operation teardown contract or require these stronger isolation
controls before any non-resource-group deployment. Either choice needs explicit
review of what can be modified, proven owned and reliably cleaned; matching
the legacy workflow does not by itself establish that a target is disposable.
Before implementation, agree who provisions and leases isolated targets,
which individual resource types are eligible (especially untaggable policy
objects), how a recovery identity is scoped, and who approves tenant-level
rights and manual cleanup. Coverage of privileged authorization, billing,
subscription creation, inherited policy effects and cross-scope examples
requires separate designs; this proposal alone cannot make the module-owner
or CI migration complete. Do not deploy, change permissions, or dispatch a
cloud workflow to test this design without explicit approval for that target.

The constraints follow Microsoft's
[subscription](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-subscription),
[management-group](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-management-group)
and [tenant](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-tenant)
deployment guidance. A
[management group must have no children before deletion](https://learn.microsoft.com/azure/governance/management-groups/manage#delete-a-management-group).

## Checklist

- [x] Identify isolated targets, ownership proof and teardown for each scope.
- [x] Distinguish current registry CI behavior from proposed stronger isolation.
- [x] Specify fail-closed failure recovery and permissions boundaries.
- [x] Record design-only validation and prepare a safety review; do not add
      non-resource-group deployment code.

## Validation

Checked the proposed scope and permission boundaries against current
Microsoft Learn guidance linked above, and the registry CI workflow and
removal helpers at `6eb8e6ff`. Documentation-only change; no build or
live Azure operation is required. Safety review is still pending.

## Blockers or dependencies

This is not implementation authorization. Resource-type allowlists, isolated
target provisioning, crash recovery and privileged access require explicit
review and user approval before any non-resource-group deployment code or
live Azure operation is allowed.
