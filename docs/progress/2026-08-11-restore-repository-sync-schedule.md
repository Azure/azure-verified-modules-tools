# Restore repository sync schedule

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-restore-repository-sync-schedule`

## Outcome

Restore the repository-management sync weekday schedule after the target
plan-only cutover validation and source workflow disablement.

## Checklist

- [x] Verify tooling PR #46 is merged and present on `main`.
- [x] Verify no existing open branch or pull request restores the schedule.
- [x] Verify the source repository sync workflow is disabled.
- [x] Restore the exact `33 */4 * * 1-5` schedule.
- [x] Preserve manual plan-only defaults and `avm` environments.
- [x] Update migration regression coverage and progress wording.
- [x] Run focused and pre-commit validation.
- [x] Commit, push, and open the focused pull request.

## Validation

- GitHub Actions API: source `Repository Sync` workflow state is
  `disabled_manually`.
- `Invoke-Pester` for `MigrationLayout.Tests.ps1`: 6 passed.
- `./build.ps1 pre-commit`: 873 unit tests passed, 7 skipped, and 26 component
  tests passed.

## Blockers or dependencies

The manual plan-only cutover test completed successfully and Avm.Authoring was
released before this follow-up. The source `Repository Sync` workflow is
`disabled_manually`.
