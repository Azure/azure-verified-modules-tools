# Tolerate GitHub owners that no longer exist

Status: complete
Started: 2026-09-18
Completed: 2026-09-18
Branch: jaredfholgate-catalog-missing-owner

## Outcome

A deleted GitHub account (`didayal`) returned HTTP 404 during owner-profile collection and aborted the
whole `Module Metadata Catalog Sync` run. Collection now tolerates a 404 for owner profiles and owner
teams, and the modules that name a missing owner hold back only their own source CSV (plus the catalog
JSON), matching the existing per-CSV hold-back behaviour for lost rows.

## Checklist

- [x] `New-AvmCatalogRequest` for `users/<handle>` and `orgs/Azure/teams/<slug>` allows 404 and records a null cache entry.
- [x] `Resolve-AvmCatalogOwnerProfiles` reports a null cache entry through `-Missing` instead of throwing; an absent key still throws.
- [x] `New-AvmCatalogBundle` collects the affected modules and unions their source files into the held-back set.
- [x] `Write-AvmCatalogMissingOwner` logs a readable table and writes `missing-owners.json` / `missing-owners.csv` into the diagnostics artifact.
- [x] `Assert-ModuleCatalogPublication.ps1` reads both diagnostics reports and explains row removals and missing owners in the step summary.
- [x] `-Force` (workflow `force=true`) still publishes everything.

## Validation

- `Invoke-Pester tests/Pester/Component/ModuleCatalog.Component.Tests.ps1` - 87 passed, 0 failed (2 new tests).
- `Invoke-Pester` for the publication and collection component suites - 66 passed, 0 failed.
- `./build.ps1 pre-commit` - green.