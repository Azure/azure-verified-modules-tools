# Process failure diagnostics

**Status**: complete
**Started**: 2026-09-01
**Updated**: 2026-09-01
**Branch**: `jaredfholgate-fix-tflint-error-reasons`

## Outcome

Ensure every terminating subprocess failure reports the captured tool diagnostic
outside verbose mode, preferring standard error and falling back to standard
output. This includes TFLint configuration failures caused by invalid rules in
repository override files.

## Checklist

- [x] Centralize terminating process-message construction.
- [x] Apply the shared diagnostic path to every manual exit-code handler.
- [x] Cover stdout-only TFLint failures and shared message behavior with tests.
- [x] Validate the complete pre-commit gate.

## Validation

- Real TFLint 0.64.0 regression probe: an unknown override rule exits 1 with
  empty stderr and the failure reason in stdout; the engine exception now
  includes `Failed to check rule config; Rule not found: made_up_rule`.
- `./build.ps1 pre-commit` - 1022 unit tests passed, 8 skipped; 29 component
  tests passed; 0 failures.

## Dependencies

None.
