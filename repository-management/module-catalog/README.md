# Module catalog sync

The tools repository owns both v1 schemas and the daily workflow. Public outputs
belong in `Azure/Azure-Verified-Modules/docs/static/module-indexes`, not the
internal team documentation repository.

`module-metadata-sync.yml` is disabled for scheduled collection/publication until
the repository variable `AVM_METADATA_SYNC_ENABLED` is exactly `true`. Manual
runs default to artifacts only. Publication additionally requires `main`, the protected `avm` environment,
and an explicit non-plan run (or the enabled schedule). The existing app needs
read access for collection, organization members read for owner-team validation,
and contents/pull-requests write restricted to the public docs and tools
repositories for publication. Nothing applies repository settings or cloud state.

## Offline generation

```powershell
.\repository-management\module-catalog\scripts\Invoke-ModuleCatalog.ps1 `
    -InputPath .\snapshot -OutputPath .\out\catalog
```

Use a new output directory. The snapshot contains `legacy/` (all six CSVs and the
approved `BicepMARModules.json` mirror), `sources/bicep/`, source-bearing
`sources/terraform/terraform-{azurerm,azapi,azure}-avm-*/` repositories,
`registry.json`, `github.json`, and `repository-config.json`.
`Get-ModuleCatalogSnapshot.ps1` collects these read-only; `GH_TOKEN` is its
authentication boundary. Only trusted local code is imported. Fetched module
files are data, never scripts, builds, Terraform plans, or Bicep compilations.
The standalone API client handles live JSON data rather than executable tool
downloads, whose separate module helper requires a pinned SHA256.

`-BicepMode metadata-only` and `-TerraformMode metadata-only` independently reject
missing metadata and unresolved legacy entries. Dual-source is the default:
present metadata must pass the packaged validator, including Bicep literals;
invalid present metadata never falls back. Reduced children require family-root
metadata and inherit owners, tier, alternative names, and comments.

The six CSVs retain their existing columns and unmigrated values, then append
`Tier,CanonicalType`. Only existing columns are projected for adopted rows; full
owners and child identity remain available in `v1/modules.json`. Its canonical
keys contain arrays per ecosystem: repository plus module path distinguishes
provider variants. `v1/migration-report.json` records missing metadata, unresolved
legacy identities/taxonomy, and cross-ecosystem parity. Terraform hyphenated names
are not guessed into taxonomy paths.

Registry errors, rate limiting, authentication failures, truncated GitHub
discovery, and incomplete output data stop generation. Registry 404s mean
not-published only at the module lookup boundary; a missing listed release is an
error. First-published months use the earliest actual release timestamp, not the
lowest version number. Terraform child availability/dates come from releases
containing that submodule; per-child download counts are unavailable and remain
null. The approved MAR string-array mirror is preserved, not replaced with an
MCR-only list that would lose approved but unpublished modules.

Only adopted Terraform root IDs move between tier lists. Other groups/settings
and unadopted memberships remain unchanged. Conflicting provider-variant tiers,
or a tier move affecting an unadopted variant sharing the same ID, fail explicitly.

Publication checks output hashes, exact allowed paths, schema, unchanged input
file hashes on current `main`, and tier-only configuration changes. Both targets
are prepared before any push. Existing app-owned review branches are updated
without force; human commits or unrelated branch changes stop publication.
Cross-repository pushes are not transactional: an interrupted publication may
leave one reviewable update and must be retried after inspection. No automatic
merge, direct `main` push, permission edit, or obsolete-source deletion is used.

Fleet metadata/backfill review, Bicep sync delivery, Terraform telemetry transport,
refreshing the private-source MAR mirror, and the approved per-ecosystem cutover
remain rollout dependencies. Update the internal Azure-Verified-Modules-Docs
team how-to when enabling the workflow; generated catalogs do not belong there.
