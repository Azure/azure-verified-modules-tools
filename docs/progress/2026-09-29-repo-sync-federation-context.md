# Repository-sync federation context

**Status**: complete
**Started**: 2026-09-29
**Updated**: 2026-09-29
**Branch**: `jaredfholgate-repo-sync-identity-federation`

## Outcome

Source the tools repository's immutable GitHub ID from its Actions context,
verify it against GitHub before planning, and pass it to both existing
per-module test-identity Terraform roots. Use the module's existing GitHub
organization ID in the validation federation subject instead of a literal.
Keep the BAMI main-only guard, plan allowlist, and plan-only apply boundary.

## Checklist

- [x] Trace the workflow, existing GitHub API helper, and both Terraform roots.
- [x] Fail closed when the tools repository context or GitHub ID is absent or mismatched.
- [x] Pass the validated ID through ordinary and BAMI plans without adding identities.
- [x] Test dynamic federation, context rejection, plan outputs, and existing safeguards.
- [x] Run the local gate and prepare the existing review update.

## Validation

GitHub supplies `GITHUB_REPOSITORY_ID` to every workflow step; the sync driver
reads it by default without changing the workflow definition. Before any
existing identity work, the driver requires the exact tools repository
context, a positive numeric ID, and a matching ID from GitHub's repository
API. Direct BAMI candidate preparation checks the same context and trusted
main. Repository creation mode still creates no test identity and does not
require a federation ID.

The shared Azure submodule builds the validation subject from its existing
organization ID and the verified repository ID; neither numeric ID is pinned
in the resource. Both Terraform roots validate and forward the new input.
The BAMI plan allowlist, the existing three module credentials, and the root
`test_settings` output remain intact. The retired-layout guard exempts only
the required Terraform variable name.

`./build.ps1 pre-commit` passed with 1,847 unit and 830 component tests (50
expected negative-test warnings). Backend-disabled `terraform validate` passed
for the ordinary, shared Azure, and BAMI roots. Mocked `terraform test` passed
10 ordinary, 6 shared Azure, and 4 BAMI cases. The changed HCL passed
`terraform fmt -check`, and the diff passed `git diff --check`. No Azure
resource operation was run.

## Dependencies

This changes the planned credential subject only. Provisioning still requires
a separately approved apply to existing non-production test identities before
the first plan-only branch preview. No Azure apply, scheduled sync, or
protected-environment approval is part of this slice.
