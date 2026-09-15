# Metadata policy BAMI integration

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-metadata-file-reviewers`

## Outcome

Merge the latest `origin/main` into
[#120](https://github.com/Azure/azure-verified-modules-tools/pull/120), retaining
the BAMI test-tenant selection and Bicep Actions Variables token permission
changes. Preserve the separate engineering-only metadata ownership policy and
both generators' existing behavior. Do not import
[#113](https://github.com/Azure/azure-verified-modules-tools/pull/113).

## Checklist

- [x] Confirm the existing branch and review, clean worktree, and current main.
- [x] Merge `origin/main` without rebasing or force-pushing.
- [x] Verify the BAMI changes and metadata generator/static-rule guards coexist
      without an ambiguous workflow or protection change.
- [x] Run `.\build.ps1 pre-commit` and inspect persisted results.
- [x] Prepare the validated integration for the existing review.

## Validation

- Merged main `ed61c747fa9a1672c8bd18262dde1162ccec604e` into previous policy
  head `5d86baf459a5f1b70d387e412d276277b0a905dd` without conflicts.
- Workflows, token scopes, BAMI configuration and implementation, and incoming
  workflow regressions match `main` exactly. Both CODEOWNERS templates, the
  Bicep static guard, and metadata policy regressions match the prior policy
  head exactly. The remaining diff against `main` is only policy and its
  documentation/tests; the metadata implementation was not imported.
- `.\build.ps1 pre-commit` with `AVM_OFFLINE=1`: 1,477 unit and 117 component
  tests passed, with eight existing unit skips and no failed or unexecuted
  tests. Persisted NUnit results report zero errors, failures, or invalid
  cases. Existing analyzer warnings and expected mocked activation warnings
  remain.
- `git diff --check` passed. No workflow/protection ambiguity required a
  behavioral decision.

Fresh full CI must run on the exact pushed integration head. Record its result
on the existing review, not by reusing earlier heads' checks.

## Rollout dependencies

Keep the coordinated Bicep Sync pause and merge order unchanged: pause before
[#113](https://github.com/Azure/azure-verified-modules-tools/pull/113) merges,
then resume only after both
[Azure/bicep-registry-modules#7349](https://github.com/Azure/bicep-registry-modules/pull/7349)
and [#120](https://github.com/Azure/azure-verified-modules-tools/pull/120) merge
with fresh final-head checks. Workflow state changes are operator actions.

No production workflow, fleet sync, live permission/settings change, remote
merge, new review, or force push is part of this integration.

## Blockers

None identified.
