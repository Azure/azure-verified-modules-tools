# Managed-files cache recovery

**Status**: complete
**Started**: 2026-09-04
**Updated**: 2026-09-04
**Branch**: `jaredfholgate-managed-cache-recovery`

## Outcome

Recover automatically when a cached managed-files checkout is no longer a
valid Git repository by deleting that ref-specific cache entry and cloning it
again once.

## Checklist

- [x] Detect the Git exit 128 "not a git repository" failure from a cached fetch.
- [x] Clear only the affected managed-files cache entry and retry with a clone.
- [x] Preserve existing failure behavior for unrelated Git errors.
- [x] Cover recovery and non-recovery paths with unit tests.
- [x] Update directly related documentation.
- [x] Run the pre-commit gate.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 pre-commit`: layout, lint, unit, and 29 component tests passed.
- `git diff --check`: passed.

## Blockers or dependencies

None.
