# Workflow module import fix

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: `jaredfholgate-workflow-module-import-fix`

## Outcome

Fix the production failure observed in
https://github.com/Azure/azure-verified-modules-tools/actions/runs/35764799563
after pull request https://github.com/Azure/azure-verified-modules-tools/pull/171
merged. Each GitHub Actions `run:` step starts a new PowerShell process, so the
module import performed by the install step was not available to the later work
step that invokes the repository-management entry point.

## Checklist

- [x] Import `Avm.Authoring` in each affected work step before script invocation.
- [x] Add same-run-block regression guards for all four workflows.
- [x] Run the four targeted workflow safety contexts.
- [x] Run `./build.ps1 pre-commit`.
- [x] Record exact validation counts and complete the slice.
- [x] Commit and push the slice.
- [x] Open a focused draft pull request against `main`.

## Validation

- Four targeted workflow safety contexts: 24 passed, 0 failed, 0 skipped.
- `./build.ps1 pre-commit`: 1,617 unit tests passed, 9 skipped, 0 failed;
  903 component tests passed, 1 skipped, 0 failed.
- The pre-commit gate completed with 57 existing warnings and no errors.
- No workflow dispatch was performed; Jared and the reviewer will coordinate
  the production rerun.

## Blockers or dependencies

None.
