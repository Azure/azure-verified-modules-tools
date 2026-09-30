# Source-only broader Bicep BAMI batch

**Status**: blocked
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bami-broader-bicep-batch`

## Outcome

Prepared exactly the five requested additions in the
[central Bicep configuration](../../repository-management/bicep-test-tenant-config/config.json),
preserving all seven existing selections, group order, and the `legacy`
default. This slice owns only that configuration and this progress record.
The resulting twelve selected paths are not twelve qualified modules:
Lab remains selected but unqualified and is not authorized for testing.

This is source preparation only, with no live test budget or activation
approval. The Bicep publisher is active, so merging this configuration can
activate the additions at the next publication. The review must remain
draft and unmerged pending candidate-scope review and separately approved
live qualification, two-pass, concurrency, and capacity gates.

## Checklist

- [x] Read repository instructions and active or blocked progress records.
- [x] Confirm a clean worktree based on current Tools `main` and check related reviews.
- [x] Recheck all candidate fixtures and critical dependencies at the pinned Bicep source.
- [x] Add only the five requested paths; preserve every existing setting.
- [x] Prove the actual before/after projection has five additions and no removals.
- [x] Run the existing focused configuration, selector, bundle, and publisher gates.
- [x] Check UTF-8 without BOM, LF endings, whitespace, and the protected-source diff.
- [x] Record draft-only publication and remaining live-approval boundaries.

## Candidate source assessment

Inspected all fixture entry points, dependency files, root resource declarations,
and the data collection rule's nested lock and compiled role-assignment helper
at [Bicep source `dcfba62f2b4a454d27865075067ecbdc2798af88`](https://github.com/Azure/bicep-registry-modules/tree/dcfba62f2b4a454d27865075067ecbdc2798af88).
The source's pure `Get-ModuleWorkflowMatrix` function confirms exactly
24 fixtures, with zero `.e2eignore` exclusions. No fixture is omitted from
the proposed scope.

| Added module path | Count | Fixtures under `tests/e2e/` |
| --- | --- | --- |
| `avm/res/insights/data-collection-endpoint` | 3 | `defaults`, `max`, `waf-aligned` |
| `avm/res/insights/data-collection-rule` | 12 | `agent-settings`, `customadv`, `custombasic`, `customiis`, `defaults`, `direct`, `linux`, `max`, `plat-tele`, `waf-aligned`, `windows`, `wksp-trans` |
| `avm/res/network/private-link-service` | 3 | `defaults`, `max`, `waf-aligned` |
| `avm/res/network/service-endpoint-policy` | 3 | `defaults`, `max`, `waf-aligned` |
| `avm/res/network/virtual-wan` | 3 | `defaults`, `max`, `waf-aligned` |

All 24 fixtures use subscription-scope entry points, create their own resource
groups, and default `resourceLocation` to `deployment().location`. No hardcoded
tenant or subscription ID, West Europe or enforced-location pin, or Azure CI
secret parameter was found in the inspected fixture source. Role-definition
and role-assignment GUIDs are not tenant or subscription pins.

- Data collection endpoint: `max` adds a user-assigned managed identity,
  resource-scoped role assignments, and a lock.
- Data collection rule: twelve monitoring scenarios cover rule kinds,
  custom tables, and transformations, not just defaults/max/WAF names.
  Dependencies create Log Analytics workspaces, custom tables, data collection
  endpoints, and a managed identity for `max`. No virtual machines, agent
  installation, or ingestion simulation are declared. The resource-scoped
  role-assignment helper is pinned to
  `br/public:avm/ptn/authorization/resource-role-assignment:0.1.2`; its compiled
  template assigns roles to the created rule, not the tenant or subscription.
- Private Link Service: dependencies create a virtual network and a Standard
  Load Balancer with a private frontend; `max` also creates a managed identity.
  No virtual machine or public IP is declared. Both `max` and `waf-aligned`
  set `autoApprovalSubscriptionIds: ['*']` while
  `visibilitySubscriptionIds` contains only `subscription().subscriptionId`.
  This is an explicit fixture review point, not a tenant-wide role grant.
- Service Endpoint Policy: `max` adds only a managed identity, resource-scoped
  roles, and a lock; no storage account is deployed by its fixtures.
- Virtual WAN: `defaults` inherits the module's `Standard` type; `max` and
  `waf-aligned` explicitly request `Basic`. `max` adds a managed identity,
  resource-scoped roles, and a lock. No virtual hub, VPN or ExpressRoute
  gateway, or data-plane appliance is declared.

The parent confirmed the corrected Virtual WAN and Private Link Service
assessment before the configuration edit. The corrections do not substitute
or skip a fixture, add a deployment, widen permissions, or authorize live work.
Static source inspection is not a zero-cost claim or runtime readiness proof.

## Validation

Tools baseline: `fb3f33ed92121c3a0d3e91c0d64063b7ba82affe`.
Bicep source inspected: `dcfba62f2b4a454d27865075067ecbdc2798af88`.
Both matched their repositories' `main` heads at the initial check.
Both were unchanged when rechecked after the focused gate.

```powershell
.\build.ps1 pre-commit -TestName @(
    'Central test tenant group resolution*'
    'Tools-owned Bicep configuration*'
    'Complete BAMI input bundle*'
    'Bicep module-path array validation*'
    'Guarded nonsecret Bicep variable publication*'
    'Narrow GitHub nonsecret variable adapter*'
    'Bicep variable adapter uses Invoke-AvmProcess*'
    'Bicep workflow isolation*'
    'Bicep test tenant entry point*'
    'Bicep variable readback*'
)
```

Passed: layout, lint, 155 unit tests, and 17 component tests; zero failures
or skips. Publication tests use mocked GitHub calls and local process
fixtures, not live services. No tests or dependencies were added or changed;
the full suite and integration tests were not needed.

The one-time pure projection passed the actual baseline and edited
configurations through `ConvertTo-AvmBicepModulePaths`: seven selected paths
become twelve, with exactly the five listed additions and zero removals.
Removing only those additions from an in-memory copy reproduces the entire
baseline configuration, including all other settings and group order.
Existing selections stay on BAMI; default, synthetic unselected, and deferred
module paths remain on `legacy`. Canonical selections remain sorted.

`git diff --check` and explicit UTF-8 without BOM, LF, and trailing-whitespace
checks passed. The diff is empty outside this configuration and progress
record, including publisher/resolver code, workflows, identities, Terraform
configuration, backend/state code, README files, and all tests.

## Blockers or dependencies

Source preparation is complete; live approval and full fixture qualification
remain blocked and outside this slice. Source freezes after draft publication.
Static inspection cannot establish provider, region, quota, cost, permission,
SKU, or BAMI runtime readiness. Activation needs explicit approval after
candidate-scope, full-fixture/two-pass, concurrency, and capacity review.
No fixture may be silently skipped.

Public IP Address and NAT Gateway remain deferred because their full fixtures
use shared diagnostics with static globally named storage and Event Hubs/Log
Analytics dependencies. Public IP Prefix's `/28`, IPv6, and StandardV2 cases
still need quota and region review. User-assigned identity's known max/WAF
West Europe pins and global placement questions remain outside this batch.
No expensive compute, AVS, HSM, or new Lab qualification is included.

No publisher, resolver, workflow, identity, Terraform configuration, test,
README, or other owner's source was changed. No cloud queries, deployments,
live selector writes, workflow dispatch/retry/cancel/approval, settings or
permission changes, state/lease/import operations, labels, merge, or
auto-merge were performed. Team documentation remains with the parent in
[azure-cloud-native/Azure-Verified-Modules-Docs#52](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/52);
this slice makes no Docs repository edits.
