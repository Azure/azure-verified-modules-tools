# Bicep CODEOWNERS sourced from module metadata.json

**Status**: complete
**Started**: 2026-09-21
**Updated**: 2026-09-21
**Branch**: `jaredfholgate-codeowners-sync-metadata-json`

## Outcome

Replace the legacy AVM index-CSV source for the Bicep CODEOWNERS sync with each
root module's `metadata.json`, discovered directly from the
`Azure/bicep-registry-modules` git tree, and remove the historical two-owner
(Primary/Secondary) cap: a module row now lists every handle in its
`metadata.json` `owners` array, in file order, deduplicated case-insensitively,
followed by the shared fallback team.

`Get-AvmBicepCodeownersSnapshot` (`CodeownersSync.ps1`) fetches the recursive
git tree for the resolved source commit, filters top-level
`avm/{res,ptn,utl}/{provider}/{module}/metadata.json` blobs, and validates each
one with `Test-AvmModuleMetadata -InputObject` before building the module list.
It returns `MetadataShas` (module name → blob sha) instead of the retired
`IndexShas`. `ConvertTo-AvmBicepCodeowners` (`Codeowners.ps1`) now takes
`-Modules` (an array of `{ Name; Owners }`) instead of `-Indexes`, still
enforces exactly two lowercase path segments per kind, rejects invalid or
duplicate paths and invalid owner handles, and still requires at least one
module of each kind (res/ptn/utl) to guard against a truncated snapshot.
`ConvertTo-AvmCodeownerHandle` accepts both plain usernames and
`@org/team-slug` handles.

`Export-BicepCodeowners.ps1`, `Invoke-BicepCodeownersSync.ps1`'s step summary,
and `docs/bicep-codeowners-sync.md` were updated to describe the
metadata.json/`bicep-registry-modules`-sourced model. The `CODEOWNERS.template`
automation header comment was reworded to stop referencing the retired
"AVM module indexes" (kept byte-identical between the template and the
`AllowLegacyDefault` migration path in `Codeowners.ps1`).

## Checklist

- [x] Confirm design with the user: drop CSVs entirely; enumerate modules from
      the `bicep-registry-modules` repo tree + `metadata.json`; unlimited owners.
- [x] Rewrite `Codeowners.ps1`: `-Modules`-based `ConvertTo-AvmBicepCodeowners`,
      unlimited-owner rendering, `@org/team-slug` handle support.
- [x] Rewrite `CodeownersSync.ps1`: `Get-AvmBicepCodeownersSnapshot` sourced from
      `bicep-registry-modules`'s git tree and per-module `metadata.json`.
- [x] Update `Export-BicepCodeowners.ps1` and `Invoke-BicepCodeownersSync.ps1`
      for the renamed `MetadataShas` snapshot field.
- [x] Update `docs/bicep-codeowners-sync.md` for the new sourcing model.
- [x] Update `CODEOWNERS.template`'s automation header wording (kept in sync
      with the `AllowLegacyDefault` literal in `Codeowners.ps1`).
- [x] Rewrite dependent Pester suites (`CodeownersGeneration`, `MetadataCodeowners`,
      `RepositoryFileSync`) for the new `-Modules` API and schema-valid fixtures.
- [x] Fix bugs surfaced by the new tests (see Validation).
- [x] Run the full `./build.ps1 pre-commit` gate.

## Validation

`Invoke-Pester` against the four affected files
(`CodeownersGeneration.Tests.ps1`, `MetadataCodeowners.Tests.ps1`,
`RepositoryFileSync.Tests.ps1`, `CodeownersWorkflow.Tests.ps1`) passed all 153
tests once three real bugs uncovered by the rewrite were fixed:

1. `ConvertTo-AvmBicepCodeowners` reassigned a local hashtable to `$modules`,
   which is the same PowerShell variable as the `$Modules` parameter
   (variable names are case-insensitive), silently emptying it before the
   render loop ran. Renamed the local to `$moduleOwnersByName`.
2. `Get-AvmBicepCodeownersSnapshot` built the tree-fetch endpoint as
   `"...git/trees/$SourceSha?recursive=1"`; PowerShell treats `?` as a legal
   bare variable-name character, so the whole `$SourceSha?recursive` token was
   parsed as one (unset) variable. Fixed with `${SourceSha}?recursive=1`.
3. `Assert-AvmCodeownersContent`'s per-row owner-duplicate loop excluded the
   final token (the required trailing fallback team) but never checked that
   *other* tokens weren't also the fallback, so a row with the fallback
   listed twice passed validation. Added an explicit `-ceq $fallback` check
   inside the loop.

Also added `[AllowEmptyCollection()]` to the `-Modules` parameter: PowerShell's
built-in mandatory-array-parameter binding rejects an empty array before the
function body's own `'At least one Bicep root module is required...'` check
ever runs, so the friendlier message was previously dead code.

`./build.ps1 pre-commit` (layout + lint + unit + component) passed:
unit `Tests Passed: 1634, Failed: 0, Skipped: 8`; component
`Tests Passed: 832, Failed: 0, Skipped: 1`. Build reported `0 errors` (84
pre-existing PSScriptAnalyzer/style warnings, unrelated to this change).

## Blockers and dependencies

None. No target repository writes were made; this slice only touches sync
tooling, tests, and documentation in this repository.
