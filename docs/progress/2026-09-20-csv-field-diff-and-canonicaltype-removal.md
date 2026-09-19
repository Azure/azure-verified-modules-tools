# Field-level CSV diff and CanonicalType column removal

Status: complete
Started: 2026-09-20
Updated: 2026-09-20
Branch: jaredfholgate-csv-diff-column-level

## Outcome

The plan-only module catalog CSV diff (from the prior slice) rendered
noisy, line-based churn: a single-column change rewrote an entire ~800
character CSV row. Reviewing a real run
(https://github.com/Azure/azure-verified-modules-tools/actions/runs/35462875427)
showed most "changed" rows only differed in 3-6 of 19 columns. That same
run's diff also exposed a `CanonicalType` column on all six generated CSVs.
Investigation traced it to PR #113 (2026-09-16); it was a deliberate,
documented decision unrelated to the diff-reporting feature, but the user
decided the CSV structure must not change at this time and asked for the
column to be removed.

This slice adds a field-level (column-aware) diff view on top of the
existing raw diff, and removes the `CanonicalType` column from all
generated CSV output.

## Checklist

- [x] Add field-level CSV diff computation (`Get-AvmCatalogCsvFieldDiff`,
      `Get-AvmCatalogCsvRowDiffKey`) to `New-ModuleCatalogCsvDiff.ps1`, keyed
      by `ModuleName` (falling back to `RepoURL`).
- [x] Render field-level markdown (`ConvertTo-AvmCatalogCsvFieldDiffMarkdown`):
      added/removed row counts plus a `Module | Field | Before | After` table
      for genuinely changed columns.
- [x] Restructure the summary table and per-file blocks so the field-level
      view is the default-visible content; nest the full unified line diff in
      a collapsed "Raw line diff" `<details>` block. Still write the raw
      `.diff` files and `all-csv.diff` unchanged; add a new `.fields.md`
      artifact per changed file.
- [x] Change inline-size gating (`-MaxInlineDiffBytes`) to measure the
      rendered summary block (field markdown + nested raw diff) instead of
      raw diff bytes alone.
- [x] Remove `CanonicalType` from CSV generation in `ModuleCatalog.ps1`
      (`Get-AvmCatalogInventory`'s legacy-table column force-add, and the
      `$values` row-population hashtable). The internal `$record.canonicalType`
      field and JSON catalog module grouping are untouched — this is a
      CSV-column-only removal.
- [x] Update `ModuleCatalog.Component.Tests.ps1`,
      `ModuleCatalog.Publication.Tests.ps1`, and
      `MetadataBackfill.Component.Tests.ps1` to stop asserting on the removed
      CSV column (reconstructing `ProviderNamespace/ResourceType` where a
      test needed the canonical key).
- [x] Rewrite `ModuleCatalog.CsvDiff.Tests.ps1` for the new field-level
      behavior: `.fields.md` artifact presence, field-table/added-row
      markdown content, new `RowsChangedCount`/`RowsAddedCount`/
      `RowsRemovedCount` result fields, and the nested raw-diff `<details>`
      wrapper.
- [x] Update `repository-management/module-catalog/README.md` and
      `docs/metadata-rollout.md` to remove `CanonicalType` CSV-column
      references and document the new field-level diff view.
- [x] Run `./build.ps1 pre-commit`.

## Validation

- `./build.ps1 pre-commit`
  - Build succeeded with warnings: 5 tasks, 0 errors, 84 warnings (expected
    negative-path test log noise).
  - Unit: 1659 passed, 0 failed, 8 skipped.
  - Component: 831 passed, 0 failed, 1 skipped.

## Blockers or dependencies

None.
