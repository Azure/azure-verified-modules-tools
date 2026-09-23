# Remove unused Terraform metadata backfill

**Status**: complete
**Started**: 2026-09-23
**Updated**: 2026-09-23
**Branch**: `jaredfholgate-terraform-metadata-cleanup`

## Outcome

Remove the unused, optional Terraform `metadata.json` backfill path and its
workflow input. Keep normal repository sync, metadata validation, new-repository
initialization, and the module catalog unchanged.

## Checklist

- [x] Remove the temporary backfill adapter and its dedicated tests.
- [x] Remove the workflow flag, sync forwarding, and backfill-only guards.
- [x] Update surviving tests and current documentation without rewriting the
      historical progress or changelog records.
- [x] Run `./build.ps1 pre-commit` and review the final diff.

## Validation

`./build.ps1 pre-commit` passed (layout, lint, unit, and component tests).
`git diff --check` passed. The repository-sync input contract and component
tests reject the retired metadata options while preserving ordinary sync.

## Blockers or dependencies

None.
