# Warning locations

**Status**: complete
**Started**: 2026-09-04
**Updated**: 2026-09-04
**Branch**: `jaredfholgate-mapotf-transform-regression`

## Outcome

Append readable file, line, and column information to ordinary terminal
warnings and errors while retaining existing GitHub Actions annotations.

## Checklist

- [x] Format positioned diagnostics for ordinary terminal output.
- [x] Preserve existing GitHub Actions annotation behavior.
- [x] Cover positioned terminal output.
- [x] Update directly related documentation.
- [x] Run the pre-commit gate.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 pre-commit`: layout, lint, 1,034 unit tests, and 29 component
  tests passed.
- `$env:AVM_INTEGRATION_FIXTURE = 'terraform-azure-avm-res-mock';
  ./build.ps1 integration`: 19 passed, 1 skipped.
- The canary repository's real inline-ignore scan rendered:
  - `TFLint inline ignore comment found for rule(s):
    terraform_unused_declarations. (main.telemetry.tf, line 59)`
  - `TFLint inline ignore comment found for rule(s):
    terraform_unused_declarations. (variables.tf, line 168)`
- Existing GitHub Actions annotation tests remained green.
- `git diff --check`: passed.

## Blockers or dependencies

None.
