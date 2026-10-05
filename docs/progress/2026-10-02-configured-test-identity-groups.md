# Configured test identity groups

**Status**: complete
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-test-identity-group-access`

## Outcome

Correct the configuration design on the existing
[review](https://github.com/Azure/azure-verified-modules-tools/pull/218).
Repository configuration supplies arbitrary Entra group display names;
matching default and repository-specific settings accumulate memberships.
Terraform resolves names in the target tenant and owns only individual UAMI
membership edges, including refresh when a configured group is recreated.

Remove the fixed three-group object-ID interface and bespoke Fabric capability.
Retain the original eight-field staging/five-field Bicep projections, published
identity settings, provider/backend isolation, and four federation subjects.
The user confirmed that the legacy tenant no longer exists. Normal sync is
BAMI-only: its ordinary root no longer executes a legacy Azure module or reads
old provider variables. A narrowly scoped, source-approved `removed` block
retires only that old ordinary-root module without refresh or destruction.
Live BAMI Owner assignments and membership edges must still be genuinely
deleted or reconciled, never forgotten.

## Checklist

- [x] Verify the existing open review and clean feature branch.
- [x] Inspect configuration merge behavior and retained legacy provider.
- [x] Confirm the exact flat name-list field and retired-tenant boundary.
- [x] Replace fixed interfaces with config-driven lookups and membership edges.
- [x] Cover group recreation, accumulation, isolation, and federation offline.
- [x] Update the runbook and prepare the verified append-only publication.

## Validation

`.\build.ps1 pre-commit -TestName` passed layout, lint, 74 unit tests and
92 component tests, with zero failures or skips. The focused selectors cover
configuration accumulation, the original settings bundle, tenant/controller
boundaries, membership creation/replacement/removal, federation, summaries,
and the BAMI-only driver. Eleven expected negative-path warnings remain.

`.\build.ps1 test-tenant-terraform` passed format, backend-disabled init,
validate, and 31 fully mocked Terraform cases: ordinary root 13, BAMI identity
root 4, and shared identity module 14. The actual candidate plan is checked
against names resolved from the central configuration and observed provider
and group evidence.

The specifically approved mocked seed creates only disposable test-run state.
Its retirement plan forgets exactly seven old-module objects, preserves every
original before-value, and has zero destruction. The bounded trace proves no
retired resource refresh or data-source read; old data-source state is removed
without re-reading it. Local state decoding is not a provider read. No
`terraform apply` CLI, real provider operation, remote state/backend operation,
workflow dispatch, variable publication, permission grant, or tenant access
occurred.

## Blockers or dependencies

Fresh `origin/main` is `c724bcaf967308b14fbd3a9975cbb015d29e8719`, already an
ancestor of this branch; no newer change removes the stale Azure execution.
The implemented flat `repositoryGroups[].entraGroups` string array accumulates
and deduplicates names from ordered matching groups. The default declares
`avm-test-entra-readers` and `avm-test-identity-owners`; `fabric` adds only
`avm-test-fabric-admins` for `avm-ptn-unified-data-platform`. No tenant-profile
map, fixed group-ID staging values, or Fabric-capability flag remains.

The coordinating session approved a strictly mocked Terraform-test seed apply
followed by a retirement plan, using only mock providers and disposable test
state. No Terraform apply CLI, real provider, backend/state, or tenant operation
is authorized. Live BAMI Owner cleanup and group membership reconciliation still
require real delete/replace actions in a separately approved saved plan.

Bootstrap defaults and the original eight-field producer are corrected in
[azure-cloud-native/Azure-Verified-Modules-Tooling-BAMI#43](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Tooling-BAMI/pull/43),
commit `23dbc4e`. Operating guidance is corrected in
[azure-cloud-native/Azure-Verified-Modules-Docs#52](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/52),
commit `46f783f`. Source publication grants no live activation approval; Graph
read/membership readiness and effective permissions remain unproved offline.
