# Catalog: Bicep submodule published status is independent of its family

Status: complete
Started: 2026-09-18
Completed: 2026-09-18
Branch: jaredfholgate-bicep-submodule-published-status

## Outcome

Investigated whether a Bicep submodule's published status is resolved independently of
its root module in both the CSV and the catalog JSON. **It already is.** No production
code needed to change. The slice adds a regression test that locks the behaviour in, so a
later refactor cannot quietly make a child inherit its parent's registry state.

## Why

The concern was that Bicep submodules might be taking their published status from their
root module, which would misreport any family where the root and its children are
published at different times. The published CSVs did show rows that look wrong, so the
behaviour needed proving rather than assuming.

## What was verified

1. **Submodules are genuinely published to MCR in their own right**, with their own
   version streams. Probed directly, for example
   `avm/res/api-management/service` is at `0.9.1` while
   `avm/res/api-management/service/api` is at `0.2.2` and
   `avm/res/api-management/service/api/policy` is at `0.1.2`.
2. **`Get-AvmCatalogBicepRegistrySet` already issues one MCR tag-list request per
   identity**, and every Bicep identity — roots and children alike — is passed to it.
   Each child therefore gets its own `status`, `currentVersion` and `firstPublishedIn`.
3. **`moduleStatus` is computed per item** from that per-item registry result, and each
   item writes its own CSV row and its own catalog JSON record.
4. **All 339 Bicep resource submodules were probed against MCR** and compared with the
   published CSV. The tooling's per-module result matches MCR in every case.
5. **All 325 published submodules are present in `BicepMARModules.json`**, so none of
   them trips the "absent from the approved MAR mirror" guard.
6. **No published module is missing a CSV row** (600 MAR entries against 606 CSV rows).

## Stale rows the next successful sync will correct

The published CSVs are simply out of date; the catalog already computes the right answer
and has not been able to publish it because collection was failing.

- **15 submodules are published but still recorded as `Proposed`** — twelve under
  `avm/res/document-db/database-account`, plus `avm/res/edge/site/rg-scope`,
  `avm/res/edge/site/sub-scope` and `avm/res/network/virtual-hub/route-map`.
- **10 submodules recorded as `Orphaned` become `Available`** (under
  `avm/res/healthcare-apis/workspace` and `avm/res/relay/namespace`). Their CSV owner
  columns are blank, but the family root metadata names `krbar`, and children inherit
  owners from the family root.
- **1 submodule recorded as `Available` becomes `Orphaned`** —
  `avm/res/desktop-virtualization/application-group/application`, because its family root
  has no owners. Publication is independent, but the `Orphaned` rule intentionally
  outranks registry state.

`avm/res/edge/site` is a good illustration of independence: the root is unpublished and
stays `Proposed`, while both of its children are published and become `Available`.

## Checklist

- [x] Confirm submodules are published to MCR separately from their root.
- [x] Confirm the registry probe runs per module path, including children.
- [x] Confirm `moduleStatus`, the CSV row and the JSON record are all per item.
- [x] Confirm children are in the MAR mirror so they do not trip the mirror guard.
- [x] Confirm no published module is missing from the CSVs.
- [x] Add a regression test covering root-ahead-of-child, child-ahead-of-root and
      grandchild-only publication.
- [x] `./build.ps1 pre-commit` green.

## Validation

`./build.ps1 pre-commit` — see the commit for the recorded result.

Catalog component tests: 83 passed, 0 failed (80 before this slice, plus the 3 new cases).

## Notes

The new test drives `New-AvmCatalogBundle` with a registry stub it controls per module
path, rather than the shared fixture stub that marks everything `available`. That is what
makes it possible to assert a root and its child holding different statuses at the same
time.

Only Bicep is covered, as intended: Terraform submodules are not represented in the CSVs,
and Terraform children deliberately resolve through their family entry.
