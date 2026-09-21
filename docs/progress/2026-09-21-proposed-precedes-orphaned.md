# Proposed status takes precedence over Orphaned; ParentModule uses family root

- Status: complete
- Date: 2026-09-21
- Branch: jaredfholgate-probable-chainsaw

## Outcome

Two related bugs in the module catalog sync tool (`repository-management/module-catalog/scripts/ModuleCatalog.ps1`),
both found while reviewing the 2026-09 Module Metadata Catalog Sync diff.

### 1. `Orphaned` was taking precedence over `Proposed`

`New-AvmCatalogBundle` classified a scaffolded module (`SourcePending`, no `main.bicep`/
source yet) with no `owners` entries as `Orphaned` instead of `Proposed`, because the
`owners.Count -eq 0` check ran before the `SourcePending` check. Reordered the
`moduleStatus` decision so `SourcePending` modules are always `Proposed` (after
`Deprecated`, before `Orphaned`).

### 2. `ParentModule` CSV column used the immediate parent instead of the family root

For nested Bicep child modules more than one level deep (e.g.
`avm/res/api-management/service/workspace/api/operation/policy`), the generated CSV's
`ParentModule` column was populated from `record.parentModule` (the *immediate* parent
directory), while the historic/legacy catalog CSVs always recorded the top-level
"family" root module (e.g. `avm/res/api-management/service`) for every descendant,
regardless of nesting depth. The tool already computed a `familyModule` field correctly
(and used it elsewhere, e.g. to inherit `owners`/`alternativeNames` from the family
root), but the CSV output line never used it. Changed the CSV projection to use
`record.familyModule` instead of `record.parentModule`.

## Checklist

- [x] Move the `SourcePending -> 'Proposed'` branch ahead of the `owners.Count -eq 0 ->
      'Orphaned'` branch in `New-AvmCatalogBundle`.
- [x] Change the `ParentModule` CSV column projection to use `record.familyModule`
      instead of `record.parentModule` for Bicep records.
- [x] Add a regression test asserting a grandchild Bicep module's CSV `ParentModule`
      cell resolves to the family root, not its immediate parent
      (`tests/Pester/Component/ModuleCatalog.Component.Tests.ps1`, "inherits family
      owners while keeping immediate Bicep and Terraform parent identities").
- [x] Confirm existing coverage for status precedence:
      `tests/Pester/Component/ModuleCatalog.Component.Tests.ps1` ("adopts scaffolded
      modules that have metadata but no source yet") already asserts `Proposed` for
      scaffolds with owners present; no test asserted the no-owners scaffold case, so
      behavior is now consistent without changing any expected outcomes.

## Validation

- `./build.ps1 test` (unit, excludes Component/Integration): 1617 passed, 0 failed, 9 skipped.
- `Invoke-Pester -Path tests/Pester/Component/ModuleCatalog.Component.Tests.ps1`: 104 passed,
  0 failed (both before and after adding the new regression test).
- `./build.ps1 pre-commit`: 0 errors (only pre-existing, unrelated warnings).

## Context

Raised while reviewing the catalog metadata drift from the 2026-09 Module Metadata Catalog
Sync run (https://github.com/Azure/azure-verified-modules-tools/actions/runs/35609242740).
Related, separately-tracked fixes from the same review:
- Azure/bicep-registry-modules#7375 (scaffold `telemetryIdPrefix` restoration)
- Azure/bicep-registry-modules#7376 (rg-scope/sub-scope duplicate telemetry ID)
- 37-repo Terraform `alternativeNames` backfill (34 merged, 1 pending review, 2 skipped
  because the repos are archived/read-only)

