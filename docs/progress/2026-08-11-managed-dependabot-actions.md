# Remove managed Dependabot GitHub Actions updates

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-remove-managed-dependabot-actions`

## Outcome

Stop distributing GitHub Actions version-update configuration through the
managed-files bundle because those workflow dependencies are maintained
centrally. Keep Terraform provider version updates in the managed Dependabot
configuration.

## Checklist

- [x] Verify the branch starts from current `origin/main`.
- [x] Verify no existing branch or pull request overlaps this change.
- [x] Remove the managed GitHub Actions Dependabot update block.
- [x] Run pre-commit validation.
- [x] Commit, push, and open the focused pull request.

## Validation

- `./build.ps1 pre-commit`: layout and lint passed, unit tests passed, and 28
  component tests passed.

## Blockers or dependencies

None.
