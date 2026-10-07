# Report safe nested Azure error codes from Bicep e2e

- Status: complete
- Started: 2026-10-04
- Branch: jaredfholgate-avm-authoring-refactor

## Outcome

Upstream parity slice E, kept separate from the refactor commits. The registry workflow shows nested Azure error codes when a deployment fails. Our native `native-execution-failed` issue only said that preparation, validation or submission failed. It now also lists up to ten distinct nested Azure error codes. Messages, targets and parameters are still never surfaced, because they can contain secrets.

## Decisions

- `Get-AvmBicepErrorResponse` gives one place to read the structured Azure response from an error record: the validation error objects for native validation failures, or the `ErrorDetails` JSON for Az failures. The regional relocation classifier now uses it as well.
- `Get-AvmBicepSafeErrorCode` walks `error`, `details` and `innererror` breadth-first, matching keys without regard to case. It accepts only identifier-shaped codes, removes duplicates without regard to case, and stops after ten codes or 1,000 nodes.
- Configuration errors keep their own messages. Cancellation and context-restore failures still propagate.

## Checklist

- [x] Helpers and wiring in `Invoke-AvmBicepNativeTestCase`.
- [x] Unit tests: SDK and JSON shapes, case, duplicates, non-code text, limit and cycles.
- [x] Component test: a validation failure reports the codes and never the secret messages.
- [x] CHANGELOG.
- [x] `./build.ps1 pre-commit` green; commit and push.

## Validation

- Safe-code, native execution, workflow input and native deployment suites: 101 passed. Bicep e2e component suite: passed.
- `./build.ps1 pre-commit`: green in 11m41s (2,916 unit tests; no failed containers).
