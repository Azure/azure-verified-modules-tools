# Override warnings

**Status**: in-progress
**Started**: 2026-09-03
**Updated**: 2026-09-03
**Branch**: `copilot/add-warning-output-for-overrides`

## Outcome

Warn when Terraform checks detect TFLint rule overrides, inline TFLint ignore
comments, or Conftest policy exception overrides. Each warning identifies the
source file and rule or rules being overridden.

## Checklist

- [ ] Add TFLint override and inline ignore warning detection.
- [ ] Add Conftest exception override warning detection.
- [ ] Cover warning behavior with focused unit tests.
- [ ] Run targeted tests and the pre-commit gate.
- [ ] Run code review and CodeQL checks.

## Validation

- Pending.

## Blockers

- None.
