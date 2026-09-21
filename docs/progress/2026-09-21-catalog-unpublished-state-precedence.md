# Catalog unpublished state precedence

**Status**: complete
**Started**: 2026-09-21
**Updated**: 2026-09-21
**Branch**: `jaredfholgate-module-state-determination`

## Outcome

Classify unpublished metadata-backed modules as Proposed even when source files
exist and the family has no owners. Keep Deprecated highest priority, and reserve
Orphaned for published modules without owners. Apply the same rule to Terraform
and Bicep JSON and CSV outputs.

The earlier scaffold correction covered only `SourcePending`. A Terraform
repository with any direct `.tf` or `.tf.json` file no longer matches that
condition, so an empty owner list could still override an unpublished registry
result.

## Checklist

- [x] Trace workflow collection, source detection, and catalog status selection.
- [x] Cover published and unpublished modules, ownership, prior CSV status, and
      metadata-only scaffolds.
- [x] Evaluate registry publication before ownership and preserve deprecation.
- [x] Update the implementation contract and catalog/rollout documentation.
- [x] Run focused component coverage and the repository pre-commit gate.
- [x] Commit and push the completed slice.

## Validation

- Before the fix, the focused component run executed 22 cases: 16 passed and
  six failed because unpublished, unowned modules with source files became
  Orphaned instead of Proposed. Both ecosystems reproduced the defect with prior
  Proposed, Orphaned, and Available CSV values.
- Post-fix `./build.ps1 component` with `-TestName` filters for the CSV/JSON
  status matrix and scaffold adoption: 22 passed, 0 failed.
- `./build.ps1 pre-commit`: 1,620 unit tests passed (9 skipped), 869 component
  tests passed (1 skipped), 0 errors. The build completed with 53 warnings.
- `git diff --check`: passed.

## Blockers and dependencies

None. Do not run or change the production catalog workflow as part of this slice.
The internal Azure-Verified-Modules-Docs catalog how-to should describe the same
status precedence; generated catalogs remain in the public documentation repo.
