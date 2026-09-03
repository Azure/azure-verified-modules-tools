# Override warnings

**Status**: complete
**Started**: 2026-09-03
**Updated**: 2026-09-03
**Branch**: `jaredfholgate-complete-override-warnings`

## Outcome

Warn when Terraform checks detect TFLint rule overrides, inline TFLint ignore
comments, or Conftest policy exception overrides. Each warning identifies the
source file and rule or rules being overridden.

## Checklist

- [x] Add TFLint override and inline ignore warning detection.
- [x] Add Conftest exception override warning detection.
- [x] Cover warning behavior with focused unit tests.
- [x] Run targeted tests and the pre-commit gate.
- [x] Run code review and CodeQL checks.

## Validation

- PASS: `Invoke-Pester -Path ./tests/Pester/Unit/Private/Engines/Invoke-AvmTerraformLint.Tests.ps1,./tests/Pester/Unit/Private/Engines/Invoke-AvmTerraformCheckPolicy.Tests.ps1 -CI`
  (60 passed; focused fallback after the build dependency could not be
  installed).
- PASS: `./build.ps1 pre-commit` (1,025 unit tests passed, 8 skipped; 29
  component tests passed; 5 tasks, 0 errors).
- PASS: Code review completed after the production changes; its actionable
  feedback was addressed. The final test-only review retry timed out.
- PASS: CodeQL checker reported no analyzable code changes for CodeQL languages,
  so no analysis was performed.

## Blockers

- None.
