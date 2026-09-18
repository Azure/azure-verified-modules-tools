# Isolate CSV row-removal failures per output

- Status: in-progress
- Started: 2026-09-18
- Branch: `jaredfholgate-catalog-csv-removal-isolation`

## Outcome

The `Module Metadata Catalog Sync` workflow stopped mid-run whenever any source CSV row lost its
module source, so clean catalogs never reached review. Generation now keeps going: every clean CSV
publishes, only the affected CSVs (and the catalog JSON) are held back, and the workflow fails at the
end with the reason for each blocked row.

## Changes

- [x] Record why each row was dropped (`metadata-not-present`, `module-source-not-found`,
      `unresolved-identity`) in `Get-AvmCatalogInventory` and surface it in the diagnostics artifact
      (`csv-row-removals.json` and `.csv`) and the progress log table.
- [x] Adopt Terraform repository moves between provider prefixes as renames. A row whose repository
      is absent is matched to the single metadata-bearing source with the same repository id and
      module path, and the row is updated in place instead of being deleted and re-added.
- [x] Hold back outputs rather than throwing. `New-AvmCatalogBundle` returns `HeldBack` (bundle
      paths) and `HeldBackSourceFiles`; the bundle still contains every configured file so
      publication validation stays strict.
- [x] Hold back the catalog JSON whenever any CSV is held back, unless `force` is set.
- [x] Skip held-back targets in `Publish-ModuleCatalog.ps1` (copy and `git add` allow-list) and
      tolerate their removals in `Assert-AvmCatalogCsvRowRetention` /
      `Get-AvmCatalogPublicationRowRemovals`.
- [x] Add a final `report` job to the workflow that runs after `collect` and `publish` and fails with
      a step summary table of held-back outputs and removal reasons.

## Validation

- `./build.ps1 pre-commit`
- New component tests: rename adoption across provider prefixes, and removal reasons in the
  diagnostics report.

## Notes

- Removal detection compares row identity keys, and a rename changes the key, so renames are
  filtered out of the removal list by `Select-AvmCatalogCsvRowRemoval`. Publication applies the same
  filter using `csvRowRenames` from the migration report, so both sides agree.
- Renames only apply when the old repository is absent entirely. A repository that still exists but
  has no `metadata.json` stays a removal, which keeps distinct provider implementations separate.
