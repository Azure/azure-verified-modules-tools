# Restore repository sync schedule

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-restore-repository-sync-schedule`

## Outcome

Restore the repository-management sync weekday schedule after the target
plan-only cutover validation and source workflow disablement. Permanently
exclude the retired governance and Terraform template repositories from
repository discovery without relying on caller defaults. Preserve the
executable Git mode of the managed root `avm` launcher so scheduled sync does
not change it from `100755` to `100644` in
`Azure/terraform-azurerm-avm-ptn-example-repo`.

## Checklist

- [x] Verify tooling PR #46 is merged and present on `main`.
- [x] Verify no existing open branch or pull request restores the schedule.
- [x] Verify the source repository sync workflow is disabled.
- [x] Restore the exact `33 */4 * * 1-5` schedule.
- [x] Preserve manual plan-only defaults and `avm` environments.
- [x] Update migration regression coverage and progress wording.
- [x] Run focused and pre-commit validation.
- [x] Commit, push, and open the focused pull request.
- [x] Move cutover exclusions into an internal permanent exclusion list.
- [x] Make caller-supplied repository exclusions additive.
- [x] Add focused permanent-exclusion behavior tests.
- [x] Narrow the retired-repository guard to the inert exclusion and its tests.
- [x] Re-run focused and pre-commit validation.
- [x] Update and push the focused pull request.
- [x] Restore the managed root `avm` launcher to Git mode `100755`.
- [x] Add a cross-platform index-mode regression.
- [x] Re-run focused and pre-commit validation.
- [x] Update and push the focused pull request.

## Validation

- GitHub Actions API: source `Repository Sync` workflow state is
  `disabled_manually`.
- Focused repository discovery and migration regression tests: 11 passed.
- Focused executable-mode migration regression tests: 7 passed.
- `./build.ps1 pre-commit`: 879 unit tests passed, 7 skipped, and 26 component
  tests passed.

## Blockers or dependencies

The manual plan-only cutover test completed successfully and Avm.Authoring was
released before this follow-up. The source `Repository Sync` workflow is
`disabled_manually`.
