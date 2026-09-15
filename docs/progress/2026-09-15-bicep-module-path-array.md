# Bicep module-path array

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-legacy-and-bami-canaries`

## Outcome

Replace the Bicep runtime object projection with the repository variable
`TEST_BAMI_MODULE_PATHS`, a JSON array of canonical BAMI-selected module paths.
The initial array is `["avm/res/dev-test-lab/lab"]`. Keep the authoritative
Tools module groups, eight staging values, five execution values, publication
guards, and Terraform identity/state/secret behavior.

## Checklist

- [x] Confirm the existing review is open and the worktree is clean.
- [x] Coordinate the array and execution-variable contract with the Bicep owner.
- [x] Adapt central projection, array validation, snapshots and activation checks.
- [x] Remove the superseded runtime action and its unused helpers/tests.
- [x] Update existing tests and current operator documentation.
- [x] Run the local gate for publication on the existing review.

## Validation

- `.\build.ps1 test-repository-management`: 378 passed.
- `.\build.ps1 pre-commit`: 1,424 unit tests passed (8 skipped), 117 component
  tests passed; existing analyzer warnings remain.
- `.\build.ps1 test-tenant-terraform`: both roots pass format/validation and
  10 mocked-provider tests pass. The delegation guard still correctly blocks
  the unsafe pre-fix candidate role condition.
- Terraform configuration, identity/state/secret machinery, disabled-gate
  handling, and its workflow have no changes in this slice.
- Current code/docs/tests contain no old object-projection or front-door
  references; completed progress files remain historical audit records.

## Remaining gates

No live settings, flags, Azure, credentials, or state operations are authorized.
Publication stays manual/default-plan and Variables-only. Gate-off Terraform
canaries remain pending rather than reverting credentials; this behavior is
unchanged and still pauses their normal repository synchronization.
