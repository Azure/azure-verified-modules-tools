# Linux tar command resolution

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-12
**Branch**: `copilot/fix-avm-pr-check-linux`

## Outcome

Linux archive extraction selects one `tar` application when duplicate matches
exist on `PATH`.

## Checklist

- [x] Add regression coverage for duplicate `tar` applications on `PATH`.
- [x] Resolve one `tar` application before invoking archive extraction.
- [x] Run targeted and pre-commit validation.
- [x] Commit and push the slice.

## Validation

- PowerShell parser validation passed for both changed `.ps1` files.
- Manual Linux extraction passed with `/usr/bin:/bin` on `PATH`;
  `Get-Command -All` returned `/usr/bin/tar` and `/bin/tar`, the function
  selected `/usr/bin/tar`, and the extracted file content matched.
- `./build.ps1 test` and `./build.ps1 pre-commit` are blocked because
  `InvokeBuild` is not installed.
- `./scripts/Install-AvmBuildPrerequisites.ps1 -MaxAttempts 5
  -InitialDelaySeconds 2` exhausted all retries because PSGallery returned
  `Resource temporarily unavailable`.
- After merging `main`, the focused archive suite passed with 4 tests passing
  and 1 Windows-only test skipped.
- `./build.ps1 pre-commit` passed after loading official InvokeBuild 5.14.23
  from a temporary module path: 5 tasks, 0 errors.

## Blockers or dependencies

None.
