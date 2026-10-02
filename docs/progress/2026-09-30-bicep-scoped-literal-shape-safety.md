# Bicep scoped nested literal shape safety

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Reject array- or boolean-shaped nested mode and expression scope values
before contacting Azure. PowerShell comparisons alone may accept a
single-element array as equal to a string.

## Checklist

- [x] Require scalar strings for literal nested mode and expression scope.
- [x] Test malformed values in unit and mocked component cases.
- [x] Run the local gate and coverage, then publish on the existing review.

## Validation

`./build.ps1 pre-commit`: layout and lint passed, 1,978 unit tests passed
(9 skipped), and 1,016 component tests passed. `./build.ps1 coverage`:
72.17% (5,455/7,559 commands), above the 70% floor. The new component
refusal uses a mocked Azure process and asserts that no Azure call occurs.
No live Azure run was performed.

## Blockers or dependencies

This guard does not broaden supported targets, resource types or CI parity.
