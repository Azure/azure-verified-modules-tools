# Catalog owner display names

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: `jaredfholgate-owner-display-names-catalog`

## Outcome

Replace the unused v1 catalog owner string shape with structured owner objects
containing the GitHub handle, explicit user/team type, and nullable display
name. User display names come from GitHub profile names; Azure team display
names come from GitHub team descriptions. Keep metadata owner inputs, catalog
version/path, CSV projections, inheritance, and publication safeguards intact.

## Checklist

- [x] Read repository contracts and active progress records.
- [x] Confirm the branch and pull-request state.
- [x] Trace schema, inventory, GitHub enrichment, bundle generation, fixtures,
      publication validation, and consumer documentation.
- [x] Update the catalog schema and GitHub owner/team enrichment.
- [x] Emit ordered owner objects while preserving CSV and lifecycle behavior.
- [x] Update component tests, fixtures, documentation, and changelog.
- [x] Run `.\build.ps1 pre-commit`.
- [x] Prepare the verified slice for commit, push, and pull-request creation.

## Validation

- Focused `.\build.ps1 component`: passed after updating catalog and backfill
  assertions for structured owners.
- Unfiltered `.\build.ps1 pre-commit`: passed in 9m02s. Layout and lint
  completed; 1,518 unit tests passed (9 skipped), and every component group
  passed, including 158 module-catalog tests. PSScriptAnalyzer encountered its
  known transient null-reference race and succeeded through the repository's
  retry wrapper.
- `git diff --check`: passed.

No production collection, publication, workflow dispatch, merge, or release is
authorized as part of local validation.

## Blockers and dependencies

None identified. The coordinating Azure/Azure-Verified-Modules session is
migrating module index consumers to the combined catalog JSON.
