# Held Bicep half-library source proposal

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-half-library-proposal`

## Outcome

**Historical, superseded on 2026-10-01.** The user replaced this held
half-library proposal with BAMI-only execution for all current and future
Bicep modules. The original roster was never published by this slice.
See [Bicep BAMI-only publisher](2026-10-01-bicep-bami-only-publisher.md);
the original preparation and validation record below is retained for audit.

Prepared exactly 97 new source candidates in the
[then-current configuration](https://github.com/Azure/azure-verified-modules-tools/blob/1b729b59da832c80d394c1536c3a6706c01c30f8/repository-management/bicep-test-tenant-config/config.json).
All 16 existing selections, group order/semantics, and the `legacy` Bicep
default remain. Terraform configuration is unchanged.

**HOLD BEFORE MERGE.** The publisher is active: merging this roster can
activate the entire list on schedule. Keep the proposal draft, unmerged, and
without auto-merge. The user authorized source preparation only, not live
deployment, cost, retention, networking, permission, or cleanup changes.

The current inventory is 224 source modules, excluding 43 metadata-only
catalog entries. Half is 112; 15 are qualified per parent evidence, leaving
97 new source candidates. Retaining unqualified Lab produces 113 selected
paths, but only 112 could count toward potential 50% coverage if every new
candidate later qualifies. None of the 97 is runtime-qualified. Retired,
all-ignored, and static-only modules, Lab, and duplicates do not fill the
target.

The bounded initial pool was 76, with 14 validated static-source candidates
first. Before configuration changes, the parent clarified that the existing
source-only request includes retained-data and higher-capacity managed
services. The final selection is 72 retained + 23 expanded + 2 analytical/
isolated-hosting candidates. It is not an ordinary, low-cost, or ready-to-run
cohort. Four provisional paths were removed: Host Pool has automated
management and a VM template; Connected Cluster includes Arc agentry and
cluster identity; NAT Gateway has actual gateway capacity; Log Analytics
Workspace's max fixture explicitly onboards Sentinel.

Tools worktree baseline: `77344a48ef03a34e1b97c493c9df6a73c9c1aed0`.
Tools `main` later moved to `c7003e81537398f319dd9b9e6742da072d06a92f`;
the two Terraform commits do not change the Bicep selector, publisher,
shared resolver, or focused suites. No rebase or unrelated import was made.
Bicep assessed source is `a3601457bd01a77411bcda068ea1deba4dfb6535`;
current source is `82bab0404566557b9fb5efdc9780bb5ce438030b`.
The deltas are hybrid-compute License/Gateway API/version artifacts and
the shared diagnostic naming fix plus its source-only test. No module-root
or fixture/ignore inventory changed. The excluded License and selected
Gateway retain their fixture counts; Gateway's new `2026-07-15` API remains
a runtime acceptance prerequisite.

## Checklist

- [x] Read the repository contract and active or blocked work records.
- [x] Check the initial Tools/Bicep source heads and overlapping open work.
- [x] Verify the existing assessment and next-wave SHA256 receipts.
- [x] Compare current Bicep changes with the assessed source.
- [x] Report the bounded candidate count, shortfall, and higher-impact classes before editing configuration.
- [x] Record all 97 candidates, provenance, full fixtures/ignores, readiness, dependencies, and known footprints in session JSON.
- [x] Preserve all existing selections, defaults, group semantics, and protected files.
- [x] Resolve the scope decision and the exact 97-candidate list.
- [x] Run the existing focused local gates and exact production-resolver comparison.
- [x] Prepare the single-slice commit and held-draft handoff; publication receipt stays in session artifacts.

## Validation

The reused assessment's two supplied SHA256 hashes match; its receipt
records 755 assertions over 224 source modules, 943 fixtures and 41 ignores.
The initial screening ledger records 2,007 consistency assertions and is
preserved separately. The final ledger passed 1,536 source/count/hash
assertions, preserves the original 14 strongest static candidates, and
contains an explicit readiness label and full inventory for every addition.

The 97 additions cover 382 fixtures: 371 nonignored and 11 existing ignored.
All 113 selections cover 439 fixtures: 428 nonignored and 11 existing ignored.
No ignore is newly added, removed, bypassed, or counted as successful.
Forty-four new candidates reach shared diagnostics through 93 callers;
43 candidates have 45 distinct published deployment references. Their exact
versions and caller bounds remain visible; current-main templates are not
substituted for published dependencies.

The ledger records 2,580 local resource-declaration occurrences across full
candidate closure unions. That is not an evaluated resource-instance total:
conditions, loops, ignored cases, repeated shared files, published modules,
and provider-managed resources prevent an honest single deployed total.
Concrete fixture quantities and their limits are recorded, not replaced
with a zero-cost or immediate-cleanup assumption.

Final session artifact: `bicep-half-library-97-source-ledger.json` under
session `56521aba-aabd-4422-8efe-5040c8dd3138`.
SHA256: `EAD57D007DB986113CB423FD3721A0F2777366E552F09AC75E96B18E19A63E1E`.
The configuration remains the only operational roster; no membership README
or roster-only test is introduced.

The existing local gate passed: layout, lint, 156 unit tests and 17 component
tests; zero failures or skips, no new dependencies or tests. The component
tests use mocked GitHub publication and local process fixtures, not live
services.

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

A pure comparison of the actual baseline and edited configuration through
the production resolver passed 288 assertions over 270 catalog/synthetic
items. Exactly 97 paths change from `legacy` to `bami`, with zero removals
or other routing changes. Subtracting those additions reproduces the entire
baseline configuration, not just its membership. Defaults, group order,
unselected paths, Terraform configuration and all protected files remain
unchanged. UTF-8 without BOM, LF, trailing whitespace and `git diff --check`
checks passed. Only the configuration and this progress record are changed.

Source preparation is complete, not live qualification or merge approval.
The final draft URL and verified remote-head receipt are recorded in this
session's publication artifact rather than adding a second operational roster.

## Blockers or dependencies

Separate live-wave approval must cover the actual full footprint, budget,
concurrency, region/provider/SKU entitlement, named CI/service identity
bindings, resource-scoped permissions, retained data and normal cleanup.
All fixtures remain intact; no protection may be weakened to make a wave fit.

| Source footprint | Required hold |
| --- | --- |
| Search max/WAF: `standard3`, 2 partitions x 3 replicas each; Service Bus includes 16 units; Event Hubs max/WAF use Standard capacity 2 and encryption uses Premium | Approve complete units and concurrency, not a defaults-only cost estimate |
| Fabric WAF `F64`, other two fixtures inherit `F2`; Power BI `A1` capacity 1; Analysis Services `S0` capacity 1 | Approve analytical-service capacity and target-tenant administrator inputs |
| Elastic SAN max: 2 TiB base + 1 TiB extended; NetApp max/NFS3 each have two 1 TiB Premium pools and two 100 GiB volumes | Approve storage, snapshot/backup, region and retained-key footprint |
| Backup Vault WAF: immutability `Locked`, soft delete `On` for 14 days; customer-managed-key fixtures retain purge-protected seven-day keys | Resolve protected-data lifecycle without promising immediate purge/full cleanup |
| App Service Environment: isolated managed compute, zone redundancy, VNet/NSG, certificate/Key Vault/UAMI dependencies and `P1D` scripts | No literal VM declaration is not proof of zero compute; approve capacity, scoped certificate role and normal script/certificate cleanup |
| Private DNS pattern: 246 zone instances and 88 VNet links across four fixtures; Edge subscription/RG cases; Resource Group max creates two groups | Include all resources and non-RG cleanup in the approved wave |
| Email Service global resource with regional identity and Germany/United States/Europe data locations; Health Bot `F0`; Arc Gateway `Public` with `features *` | Preserve legitimate global placement; no price/entitlement or private-network assumption |

Batch account fixtures contain no pool/job/VM deployments despite
`poolAllocationMode: BatchService`. Data Factory supplied fixtures do not
configure SSIS nodes, and Cognitive Services fixtures do not supply the
root's optional commitment plans. These narrow source facts do not clear
their other managed-service/retention prerequisites.

[Azure/bicep-registry-modules#7436](https://github.com/Azure/bicep-registry-modules/pull/7436)
merged during source preparation at
`82bab0404566557b9fb5efdc9780bb5ce438030b` from head
`7ad2566665c7c1a6269a37987413250c65f827b4`. Its shared Storage and Event Hubs
names now use resource-group-specific truncated/hash suffixes. The 44
proposed consumers and 93 callers still need separate runtime qualification.
The fix does not solve all global-name, location, input, published-version,
or service-readiness risks. This branch did not modify or inject that source.

No cloud queries, deployments, selector publication, workflow controls,
permissions, state, cleanup, cost changes, or other-owner edits are in scope.
Terraform configuration and managed-file groups remain untouched.
Team-documentation follow-up stays parent-coordinated in
[azure-cloud-native/Azure-Verified-Modules-Docs#52](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/52);
this slice makes no Docs repository edits or other-owner contacts.
