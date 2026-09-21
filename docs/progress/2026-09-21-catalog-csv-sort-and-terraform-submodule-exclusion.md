# Catalog CSV alphabetical sort & Terraform submodule exclusion

- Status: complete
- Date: 2026-09-21
- Branch: jaredfholgate-probable-chainsaw

## Outcome

`ModuleCatalog.ps1` (`New-AvmCatalogBundle`/`Get-AvmCatalogInventory`) now:

1. Sorts every generated CSV output alphabetically (ordinal compare on `ModuleName`)
   before writing it, instead of preserving legacy row order and appending new rows
   at the end.
2. Excludes Terraform submodule rows (`ModulePath -ne '.'`) from CSV output entirely,
   so the Bicep and Terraform CSVs share the same dataset shape (root/family modules
   only). The Terraform submodule catalog *entries* are unaffected — they still appear
   in the JSON catalog (`docs/v1/modules.json`) with full owner/alias/comment
   inheritance; only the CSV row is dropped.

## Checklist

- [x] Sort CSV rows ordinally by `ModuleName` in `New-AvmCatalogBundle`.
- [x] Exclude Terraform submodule rows from CSV output at both row-inclusion call
      sites in `Get-AvmCatalogInventory` (legacy-matched rows and newly-discovered
      rows).
- [x] Update `ModuleCatalog.Component.Tests.ps1` tests that previously asserted a
      Terraform submodule CSV row's presence/fields to assert absence instead
      (Bicep assertions unchanged).
- [x] Add regression test: CSV output is alphabetically ordered regardless of
      discovery order.
- [x] Add regression test: a Terraform submodule row present in the legacy/source
      CSV is excluded from the generated CSV even under `-Force`, while the JSON
      catalog entry is retained.
- [x] `./build.ps1 pre-commit` green (0 errors).

## Operational note for the next real workflow run

Removing Terraform submodule rows from the CSV will trip the existing CSV
row-removal safety net (`Get-AvmCatalogCsvRowRemovals`/`Assert-AvmCatalogCsvRowRetention`
in `ModuleCatalog.CsvRows.ps1`): every currently-existing Terraform submodule row in
`docs/TerraformResourceModules.csv` will look like a "removed" row. The **next**
`module-metadata-sync` workflow run must be triggered with the `force: true`
`workflow_dispatch` input (`FORCE_CSV_ROW_REMOVALS=true`) to actually publish the
removal; otherwise the whole Terraform CSV (and the JSON catalog, which depends on
it) will be held back. Subsequent runs do not need `force` once the removal has been
published.

## Validation

- `Invoke-Pester -Path tests/Pester/Component/ModuleCatalog.Component.Tests.ps1`:
  106 passed, 0 failed.
- `./build.ps1 pre-commit`: 5 tasks, 0 errors (51 pre-existing style warnings).
