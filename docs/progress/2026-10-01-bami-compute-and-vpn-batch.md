# Source-only compute and VPN Bicep BAMI batch

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bami-compute-and-vpn-batch`

## Outcome

Prepared only the four requested additions listed below in the
[central Bicep configuration](../../repository-management/bicep-test-tenant-config/config.json).
All twelve existing selections, group order, and the `legacy` default are
preserved. Configuration remains the only operational roster; no membership
list is copied into a README or permanent test.

This slice is source-only, not activation or test approval. Sixteen selected
paths do not mean sixteen qualified modules. Lab remains selected but
unqualified and is not authorized for testing. The active Bicep publisher
can activate merged source at its next scheduled or manual run; publication
must therefore stay draft and unmerged, without labels or auto-merge.
Terraform's global BAMI default is outside this slice and must not change.

Inherited context, reported by the parent rather than re-audited here: the
preceding broader cohort finished with 24 first-pass and 24 final successful
existing-workflow fixture outcomes. Two original request failures remain
history after separately approved successful retries. Eleven modules have
deployment/cleanup coverage in both workflow families, not the whole inventory.
None of that evidence qualifies these four additions.

## Checklist

- [x] Read the repository contract and active or blocked progress records.
- [x] Confirm a clean Tools baseline and check existing related reviews.
- [x] Recheck all twelve fixtures and the full helper/module dependency closure.
- [x] Record sharing, identity, scope, location, zonal intent, and cost constraints.
- [x] Add exactly the four canonical paths in existing sorted group style.
- [x] Prove the production resolver adds only four paths and preserves the baseline.
- [x] Run existing focused configuration, selector, bundle, and publisher gates.
- [x] Check encoding, whitespace, and the two-file ownership boundary.
- [x] Record the draft-only handoff and remaining live-approval boundaries.

## Source assessment

Tools baseline: `4852c41dfbc548c8d2b7472d36465e95a46086bb`.
Frozen [Bicep source `74a906828e3e42f6c8fed17f7323e999c78cbf78`](https://github.com/Azure/bicep-registry-modules/tree/74a906828e3e42f6c8fed17f7323e999c78cbf78).
The upstream pure `Get-ModuleWorkflowMatrix` confirms all twelve fixture
entries with zero `.e2eignore` exclusions:

| Added canonical path | Fixtures under `tests/e2e/` | Count |
| --- | --- | --- |
| `avm/res/compute/availability-set` | `defaults`, `max`, `waf-aligned` | 3 |
| `avm/res/compute/gallery` | `defaults`, `max`, `waf-aligned` | 3 |
| `avm/res/compute/proximity-placement-group` | `defaults`, `max`, `waf-aligned` | 3 |
| `avm/res/network/vpn-site` | `defaults`, `max`, `waf-aligned` | 3 |

Read every fixture, recursively followed all local module/type/data references,
and verified the downloaded files against frozen Git blob hashes. The reachable
closure is 25 Bicep files and six loaded metadata files: twelve entry points,
seven dependency helpers, four root modules, and two gallery children. Also
inspected all six checked-in compiled module templates recursively, including
defaults, role scopes, child parameters, and embedded imported type definitions.
No external deployment module or linked template is present. The only external
imports are `avm-common-types` lock/role types at `0.5.1`, `0.6.0`, `0.6.1`,
and `0.7.0`; they add no deployment resources.

All twelve entry points are subscription-scoped, create their own resource
group, and default `resourceLocation` to `deployment().location`. Modules and
helpers use that location explicitly or inherit it from the created group.
All twelve retain serial `init`/`idem` loops. No hardcoded tenant/subscription
ID, enforced region, shared diagnostic resource, or global DNS-name dependency
was found in the reachable fixture closure. Built-in role-definition IDs and
fixed role-assignment names are not tenant/subscription pins.

### Availability set

`defaults` creates the availability set. All fixtures use `Aligned` SKU
(explicit in `max`, otherwise the root default), two fault domains, and five
update domains. `max` creates a user-assigned managed identity and a bare
proximity placement group dependency, then resource-scoped Owner, Contributor,
and Reader assignments plus a `CanNotDelete` lock on the availability set.
`waf-aligned` creates a proximity placement group and the lock, but no identity
or role assignments. The helper placement groups request neither zones nor VM
size intent. No VM, scale set, disk, or capacity reservation is declared.
Availability-set and placement support in the approved region remains a live
readiness gate, not a capacity-neutral or zero-cost claim.

### Proximity placement group

`defaults` explicitly uses `availabilityZone: -1`, resulting in no zone.
`max` and `waf-aligned` use type `Standard`, zone `1`, colocation status,
and intent VM sizes `Standard_B1ms` and `Standard_B4ms`. `max` additionally
creates a managed identity, resource-scoped Owner/Contributor/Reader
assignments, and a `CanNotDelete` lock. No VM or scale set is created by these
fixtures, but the declared zone and SKU intents are real region, placement,
and capacity constraints that must not be skipped or replaced to obtain a pass.

### Compute gallery

`defaults` creates only the gallery. `max` creates two application definitions
and six image definitions, plus a managed identity, a gallery lock, and
Owner/Contributor/Reader assignments scoped to the gallery and the second
application definition. `waf-aligned` creates one application definition and
one image definition. Its on-disk `dependencies.bicep` contains a managed
identity but is never called; it does not count as a deployed WAF dependency.

Followed both `application/main.bicep` and `image/main.bicep` and their embedded
compiled templates. Their existing-parent declarations refer to the created
gallery, not another gallery. No image/application version, disk/VM, replication
payload, package URI download, custom-action execution, or marketplace purchase
is declared. Image `purchasePlan` values, OS identifiers, resource
recommendations, feature flags, and example policy URIs are definition metadata.
Image definitions use API `2024-03-03`; the child chooses an omitted Hyper-V
generation from the supplied security type, otherwise `V1`. No version is
created to test image boot or application installation.

All gallery fixtures omit `sharingProfile` and `softDeletePolicy`. The root
parameters are nullable, have no explicit `Private` or deletion-policy default,
and pass through to the gallery resource. The children add no sharing action.
Source requests neither direct/community sharing nor a sharing update, but
this is not proof of private access, absent inherited role-based access, or
cleanup behavior. Later approved checks must inspect the created resources'
effective sharing/soft-delete behavior and cleanup outcome. This is a scoped
runtime gate, not a new tenant-wide permission audit or fixture change.

### VPN site

Every fixture creates a bare Virtual WAN dependency; `max` and `waf-aligned`
also create a managed identity. These helpers declare the WAN resource
directly, without `properties.type`, at API `2023-04-01` (`max`) or
`2024-10-01` (`defaults`/`waf-aligned`). Its type is an unpinned API/service
default, not the separate AVM Virtual WAN module's `Standard` default.
Confirm the resulting WAN type within later scoped runtime approval.

`defaults` supplies an address prefix and sample site IP; `max`/`waf-aligned`
configure two site links with sample IP/BGP metadata, device properties, and
an Office 365 breakout policy. `max` also adds resource-scoped
Owner/Contributor/Reader assignments and a lock on the VPN site.
`isSecuritySite` remains false. No virtual hub, gateway, connection, public IP,
appliance, or data-plane deployment exists in the closure. These fixtures do
not test network connectivity or authorize use of the sample addresses.

### Shared limits and source drift

Fixture role assignments target the newly created managed identities and
individual resources, not new tenant-wide or subscription-wide grants.
Existing root telemetry defaults stay enabled through empty nested deployment
templates; gallery child telemetry is disabled by the parent module.
No additional identity or permission configuration is introduced here.

The initial source-head check found Bicep `main` one commit ahead at
`a3601457bd01a77411bcda068ea1deba4dfb6535`. The comparison changes only
`avm/res/kubernetes/connected-cluster/`, outside this complete dependency
closure. Assessment remains pinned to the supplied frozen head. The parent
reviewed the nullable gallery fields, bare WAN default, reachable-only
dependency counts, and PPG constraints before the central configuration edit.

## Validation

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

Passed: layout, lint, 156 unit tests, and 17 component tests, with zero
failures or skips. PSScriptAnalyzer hit its known transient
`NullReferenceException` three times; the existing build wrapper retried and
lint then passed with no findings. The build finished with zero errors and
warnings. Publication tests use mocked GitHub calls and local process
fixtures, not live services. No test, dependency, or build changes were needed;
the full suite and integration tests were not run for this focused slice.

The actual baseline and edited configurations passed through the production
`ConvertTo-AvmBicepModulePaths` and `Resolve-AvmGroupTestTenant` functions:
twelve paths become sixteen, with exactly the four additions and zero removals.
Removing just those additions from an in-memory copy reproduces the entire
baseline configuration, including group order and every other setting.
All existing selections, including Lab, still resolve to BAMI. Default,
synthetic unselected, and deferred paths remain `legacy`; canonical group
selectors stay sorted. No permanent membership test or live publication
command is added.

`git diff --check`, explicit UTF-8 without BOM/LF/trailing-newline checks,
and the two-file ownership guard passed. The new progress record was
normalized to LF. The diff is empty outside the central Bicep configuration
and this record: no workflow, publisher, shared helper, identity, role, tenant,
backend, Terraform configuration, README, or test was changed.

Tools `main` remained at the baseline, and a fresh check of all open Tools
reviews found none changing the central Bicep configuration. Source preparation
is complete. Publication is draft-only on the recorded feature branch, and
source freezes after that publication; merge, labels, and auto-merge are not
authorized.

## Blockers or dependencies

No live work is authorized. Explicit approval for this exact four-module,
twelve-fixture batch, full-fixture qualification, two-pass deployment/cleanup
evidence in both workflow families, concurrency, provider/API support,
resource-scoped permissions and lock cleanup, regional/SKU/zone readiness,
capacity, and cost review remain separate gates. Gallery sharing/soft-delete
behavior and the bare WAN type require scoped runtime confirmation.
The existing `init`/`idem` loops are not a substitute for two approved complete
workflow passes. No fixture substitutions or skips are permitted.

SSH public key, VPN server configuration, diagnostic-heavy or global resources,
public IP, NAT, HSM, VM, and AVS scenarios remain outside this batch. No Azure
or Entra queries, deployments, workflow dispatch/retry/cancel/approval,
settings/identity/role/key/secret/provider changes, or cleanup/state/lease
operations are permitted. Other owners' source and reviews are untouched.
The parent coordinates team documentation through
[azure-cloud-native/Azure-Verified-Modules-Docs#52](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/52).
