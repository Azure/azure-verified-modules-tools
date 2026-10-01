# Bicep unit and compliance test separation

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Run module-authored Bicep `tests/unit` by default through `avm test unit`.
Keep registry compliance as an explicit temporary option instead of running
the same suite by default in both `avm test unit` and `avm check convention`.
The existing registry CI continues to run compliance until convention parity
is complete and its cutover is separately approved.

## Checklist

- [x] Make `tests/unit` the default Bicep unit selection, including monorepo
      roots with no compliance suite.
- [x] Preserve explicit `-IncludeCompliance` and `-CompliancePath` options,
      including a clear failure if a requested suite cannot be found.
- [x] Update help, changelog and mocked/unit/component tests; preserve
      Terraform behavior.
- [x] Run coverage and the full pre-commit gate, then commit and push.

## Validation

`./build.ps1 pre-commit`: layout and lint passed; 1,941 unit tests passed
(9 skipped) and 970 component tests passed. `./build.ps1 coverage`:
73.55% (5,117 of 6,957 commands), above the 70% floor.

## Blockers or dependencies

The separate Bicep static-checks work owns `avm check convention`; it may
initially cover only a subset of registry compliance. Do not remove the
optional compliance bridge or change legacy CI until coverage and cutover
are confirmed. No live Azure operation is needed for this slice.
