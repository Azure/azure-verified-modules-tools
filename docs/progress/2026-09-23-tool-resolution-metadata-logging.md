# Tool resolution and metadata logging

**Status**: complete
**Started**: 2026-09-23
**Updated**: 2026-09-23
**Branch**: `jaredfholgate-tool-resolution-order`

## Outcome

Resolve the managed tools before validating module metadata in both authoring
chains, while keeping metadata validation ahead of the mutating and drift-check
steps. Provide useful verbose diagnostics for metadata discovery and validation.

## Checklist

- [x] Restore tool resolution before the metadata step in pre-commit and pr-check.
- [x] Log metadata discovery, checked paths, and validation results at verbose level.
- [x] Cover ordering, failure behavior, and verbose output with regression tests.
- [x] Update authoring documentation to reflect the ordering.
- [x] Run the local gate.

## Validation

`.\build.ps1 -Tasks test,component -TestName 'Invoke-AvmPreCommit*',
'Invoke-AvmPrCheck*','Component: metadata in authoring checks*'` passed
37 unit and 89 component tests.

`.\build.ps1 pre-commit` passed after rebasing onto current main: layout,
lint, 1,774 unit tests (9 skipped), and 799 component tests, with no failures.
Before the rebase, the initial gate encountered an intermittent module-catalog
schema parsing failure in an unrelated component test; its 54-test lifecycle
group and the full retry passed unchanged.

## Blockers or dependencies

None.
