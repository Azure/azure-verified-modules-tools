# Catalog preview publication

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Publish all six generated CSVs as `test-` files in the existing index folder
without replacing the current CSVs. Continue publishing the new JSON catalog
at its normal path. CSV replacement is a separate later change.

The user chose to remove both the metadata catalog enable gate and the
Terraform sync pause variable. Keep the unrelated CI Azure credential check.
Confirm metadata backfill remains an explicit workflow_dispatch operation,
never part of scheduled or repository_dispatch sync.

## Checklist

- [x] Separate legacy CSV input names from preview output names in the manifest.
- [x] Preserve collection hashes, publication allowlists, and stale-input checks.
- [x] Remove both selected variable gates and their script-level equivalents.
- [x] Verify manual-only backfill and preserve other safety/approval boundaries.
- [x] Update tests and rollout/removal documentation.
- [x] Review, run the local gate, and commit/push the change.

## Validation

Focused component checks passed: 115 cases, including original-input reads,
preview-only publication paths, hashes for both input/output bases, stale-source
rejection, manifest safety, and manual-only backfill. CI's credential condition
is the only remaining variable-based workflow condition.

The backfill reader explicitly uses the manifest's canonical source path, never
its preview publication path. Snapshot/publication command resolution also
selects the first matching executable when PATH contains duplicate entries.

Full `.\build.ps1 pre-commit` passed: 1,301 unit tests, 8 existing skips, and
358 component tests, with zero errors. Claude Opus 5 reported no findings
after checking preview write paths, canonical inputs, stale bases, manifest
validation, variable removal, and manual-only backfill.

## Dependencies

This changes workflow definitions only. No live workflow state, variables,
permissions, production runs, or merges are changed by this work.
Fresh exact-head hosted checks are required before merging.
