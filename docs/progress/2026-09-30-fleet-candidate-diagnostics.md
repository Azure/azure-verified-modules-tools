# Fleet candidate diagnostics

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Show the structured reasons for failed candidate pull-request checks and unit
tests in repository-sync logs. Preserve the rule that only two passing checks
produce a validation receipt and permit publication.

## Checklist

- [x] Render failing check steps, source locations, rule codes, and test
      diagnostics from their returned results.
- [x] Distinguish failed tests from absent or skipped unit tests.
- [x] Cover failure reporting and unchanged validation behavior with tests.
- [x] Pass the local pre-commit gate, commit, and push the change.

## Validation

The eight focused candidate-diagnostic and receipt-gating tests passed.
`./build.ps1 pre-commit` passed: 1,954 unit tests, nine platform skips,
937 component tests, no failures; the analyzer retried transient engine
errors and the gate completed with existing test warnings. No live sync or
Azure operation was started.

## Blockers or dependencies

The cancelled all-repository plan-only run
[36749306675](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36749306675)
exposed 18 failed candidate validations. Nine contained a lint failure; five
had failed unit tests and 13 reported skipped unit tests. The current validator
prints only step statuses instead of the structured findings. No further live
run or Azure operation is authorized by this slice.
