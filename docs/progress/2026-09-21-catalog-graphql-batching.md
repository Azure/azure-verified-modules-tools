# Batch module catalog sync lookups via GitHub GraphQL

**Status**: complete
**Started**: 2026-09-21
**Updated**: 2026-09-21
**Branch**: `jaredfholgate-verbose-potato`

## Outcome

The "Module Metadata Catalog Sync" workflow's collection script
(`repository-management/module-catalog/scripts/ModuleCatalog.Collection.ps1`)
issued one REST call per resource: one `GET /users/{handle}` or
`GET /orgs/Azure/teams/{slug}` per unique owner/team, and one
`GET /repos/{repo}` plus one `GET /repos/{repo}/commits/{branch}` per
Terraform repository (hundreds of repos per run). Repo discovery already
paginated correctly via `search/repositories`, but these per-resource lookups
were the actual source of excessive API calls.

Added GraphQL POST/Body support to the existing request primitives and a new
`Invoke-AvmCatalogGraphQlBatch` helper that batches many aliased field
selections into a single POST to `https://api.github.com/graphql` (chunked at
50 selections per call). Rewrote the two REST-loop call sites to build one
combined batch instead:

- `Get-AvmCatalogEnrichment`: all user + team profile lookups now resolve in
  one GraphQL batch call instead of N REST calls.
- `Save-AvmCatalogTerraformSourceSet`: repo metadata + latest-commit lookup
  merged into a single GraphQL call per repository (was two REST calls),
  using `defaultBranchRef == null` to detect an empty repository instead of
  the old fragile 409-body string match.

Git-tree listing and raw blob content fetches remain REST (unchanged) — they
were judged lower value / higher risk to batch and were kept out of scope for
this slice.

## Checklist

- [x] Added `Method`/`Body` to `New-AvmCatalogRequest` /
  `New-AvmCatalogRequestMessage` / `Invoke-AvmCatalogRequestSet` (backward
  compatible, defaults to GET/no body).
- [x] Added `ConvertTo-AvmCatalogGraphQlString` and
  `Invoke-AvmCatalogGraphQlBatch`.
- [x] Rewrote `Get-AvmCatalogEnrichment` to batch owner/team lookups.
- [x] Rewrote `Save-AvmCatalogTerraformSourceSet` to batch repo metadata +
  commit lookups.
- [x] Updated `tests/Pester/Component/ModuleCatalog.Collection.Tests.ps1` to
  mock GraphQL responses instead of the removed REST endpoints, including a
  new `Get-AvmCatalogGraphQlMockRepositoryData` test helper.
- [x] Ran the full local gate.
- [x] Commit and push the completed slice.

## Validation

- `Invoke-Pester -Path tests/Pester/Component/ModuleCatalog.Collection.Tests.ps1`
  passed: 42/42.
- `./build.ps1 pre-commit` passed (layout + lint + test + component; 0
  errors).

## Blockers or dependencies

- None. No PR opened per standing instruction that PRs are user-driven; will
  open one only if explicitly requested.
