# Bicep scoped nested deployment safety

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Reject destructive or uninspectable nested deployment options before any
Azure call in subscription-, management-group- or tenant-scoped Bicep e2e.
Keep the existing resource-group path and the higher-scope cleanup boundary
unchanged.

## Checklist

- [x] Require a literal Incremental mode and inspectable inline template
      for each nested deployment.
- [x] Reject linked parameters, rollback and unreviewed nested properties.
- [x] Add positive and refusal tests proving rejected cases never call Azure.
- [x] Update public help, run the full local gate and coverage, then publish
      the fix on the existing review.

## Validation

`./build.ps1 pre-commit`: layout and lint passed, 1,976 unit tests passed
(9 skipped), and 1,015 component tests passed. `./build.ps1 coverage`:
72.17% (5,455/7,559 commands), above the 70% floor. Unsafe nested
deployments were rejected before mocked Azure commands were invoked.
No live Azure command or deployment was run.

## Blockers or dependencies

This guard does not establish broader resource-type, cross-scope, identity
or unattended-recovery parity. No live Azure deployment or CI cutover is
authorized.
