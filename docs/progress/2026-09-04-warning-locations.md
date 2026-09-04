# Warning locations

**Status**: complete
**Started**: 2026-09-04
**Updated**: 2026-09-04
**Branch**: `jaredfholgate-mapotf-transform-regression`

## Outcome

Preserve diagnostic file, line, and column information in ordinary terminal
warnings and errors, and emit native Azure DevOps task issues when running
inside an Azure Pipelines job.

## Checklist

- [x] Format positioned diagnostics for ordinary terminal output.
- [x] Emit Azure DevOps warning and error task issues with source positions.
- [x] Preserve existing GitHub Actions annotation behavior.
- [x] Cover terminal, Azure DevOps, and escaping behavior.
- [x] Update directly related documentation.
- [x] Run the pre-commit gate.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 test`: 1,035 passed, 0 failed, 8 skipped.
- `./build.ps1 pre-commit`: layout, lint, unit, and 29 component tests passed.
- The canary repository's real inline-ignore scan rendered:
  - `main.telemetry.tf:59`
  - `variables.tf:168`
- Azure DevOps task issue tests cover file, line, column, and command escaping.
- Existing GitHub Actions annotation tests remained green.
- `git diff --check`: passed.

## Blockers or dependencies

None.
