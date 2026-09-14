# Bicep app permission preflight

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-bicep-app-permissions`

## Outcome

Fix the shared sync preflight rejecting an installation token because
repository collaborator-role metadata reports `permissions.push = false` or
is unavailable. Preserve repository ID, target-only scope, expected bot,
candidate validation, and API/Git error propagation. Terraform defaults and
the Bicep workflow remain unchanged.

The workflow explicitly requests target-only Contents and Pull requests write.
[GitHub's token action](https://github.com/actions/create-github-app-token/tree/bcd2ba49218906704ab6c1aa796996da409d3eb1#create-a-token-with-specific-permissions)
rejects requested permissions that the installation does not have; repository
role flags are not the installation token's permission grants.

## Checklist

- [x] Confirm clean default-main base and existing branch/work status.
- [x] Inspect the workflow grants and shared-core identity checks.
- [x] Cover false/unavailable role metadata and identity/scope/actor failures.
- [x] Remove only the invalid role predicate and clarify the identity error.
- [x] Run local mocked validation with Pester 6.2.0.
- [x] Attempt the full build gate and record its local environment blocker.

## Validation

Before the fix, `.\build.ps1 component` with Pester 6.2.0 reproduced the
reported failure for `push = false` and strict-mode failures for null/omitted
permissions. The identity-message regression also failed as expected; the
other 72 component cases passed.

After the fix, `.\build.ps1 test-repository-management` passed all 204 unit
tests and `.\build.ps1 component` passed all 76 component tests. Layout and
lint completed with warnings but no errors.

Full local gates remain unverified: `.\build.ps1 ci` stops before coverage
because analyzer-created runspaces prepend the workstation module paths,
causing Pester 5.7.1 to reload over the already-loaded 6.2.0 assembly. The
combined invocation did not reach `pre-commit`. No build code or global module
installations were changed. The requester authorized publication with this
limitation; clean hosted CI must pass before the fix is considered merge-ready.

## Dependencies

Live verification requires separate user approval. No workflows, app tokens,
target repositories, permissions, or settings are changed by this slice.
Known named-owner CODEOWNERS diagnostics remain a separate operational issue.
