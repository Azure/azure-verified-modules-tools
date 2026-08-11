# Red check failure output

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-fix-check-failure-output`

## Outcome

Check failures render in red without creating duplicate GitHub Actions error
annotations.

## Checklist

- [x] Add a non-annotating failure log level.
- [x] Colour live gauntlet and subprocess failures red.
- [x] Colour failed result-summary sections red.
- [x] Add regression coverage.
- [x] Run the repository pre-commit gate.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 pre-commit` passed.

## Blockers or dependencies

None.
