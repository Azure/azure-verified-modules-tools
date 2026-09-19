# Independent Bicep display names

**Status**: complete
**Started**: 2026-09-19
**Updated**: 2026-09-19
**Branch**: `jaredfholgate-review-pipeline-diff`

## Outcome

Allow `metadata.json` `moduleDisplayName` to differ from the Bicep
`metadata name` declaration during metadata validation and source updates.
Description and telemetry source validation remain unchanged.

## Checklist

- [x] Remove display-name equality validation from read-only metadata checks.
- [x] Remove display-name equality validation from Bicep source update planning.
- [x] Add regression coverage for independently authored display names.
- [x] Update the implementation contract.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit and push the slice.
- [x] Open a pull request targeting `main`.

## Validation

`./build.ps1 pre-commit` green: 5 tasks, 0 errors, 11m52s. Component tier
reported 832 passed, 1 skipped. Catalog coverage now asserts that a
`moduleDisplayName` differing from the Bicep `metadata name` literal is
accepted end-to-end, while a mismatched description still fails collection.

## Context

The catalog sync run 35467915533 aborted with `Invalid present metadata for
bicep:azure/bicep-registry-modules:avm/ptn/aca-lza/hosting-environment` after
`Azure/bicep-registry-modules#7371` restored 576 canonical display names. The
two values are independent by design, so the equality rule was removed rather
than the data being changed again.

## Blockers or dependencies

None.
