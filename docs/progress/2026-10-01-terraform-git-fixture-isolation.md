# Terraform Git fixture environment isolation

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Fix the test-only environment leak found by the ordinary Authoring CI run on
the [Bicep test review](https://github.com/Azure/azure-verified-modules-tools/pull/202):
the Terraform repository-initialization component fixture restores originally
absent Git identity overrides as empty strings on macOS. A later real Git
fixture then rejects the blank identity despite its repository-local config.
Restore absent variables to absence while preserving previously set values.
Keep the fix limited to this fixture and its regression tests. Merge the new
`main` commit `64e29a5` to make the existing review mergeable again, retaining
both its Terraform retry guidance and the branch's Bicep e2e help.

## Checklist

- [x] Reproduce the absent-versus-empty environment behavior and inspect the
      affected fixture and existing cleanup patterns.
- [x] Fix the fixture cleanup and test both absent and present values, including
      a subsequent local Git commit without changing user/global Git config.
- [x] Run focused component tests covering both fixtures and the cleanup case.
- [x] After the shared host gate slot is released, run `./build.ps1 pre-commit`
      before committing and pushing the existing branch.
- [x] Confirm the existing review remains open, update its description, and
      distinguish hosted CI results from the local gate.

## Validation

- In an isolated PowerShell process, restoring a null snapshot with
  `[Environment]::SetEnvironmentVariable` left the variable present and empty;
  passing `[NullString]::Value` instead removed it.
- The focused `./build.ps1 component -TestName ...` run passed all 34
  Terraform initialization, cleanup, and downstream pre-commit fixture tests.
  The regression verifies originally absent Git identity variables are truly
  absent, explicit empty and nonempty originals survive restoration, and a
  subsequent local Git commit honors repository-local identity. The same 34
  checks passed again after switching the helper to the typed-null API.
- The new `main` commit changed Terraform e2e retry classification, not this
  fixture. Its help-file conflict was resolved to retain both the expanded
  Terraform retry description and all guarded Bicep test parameters and
  post-hook documentation. No runtime test/deployment logic was changed in
  conflict resolution.
- Focused tests after merging `main`: 30 Terraform e2e unit tests and 157
  Bicep/Terraform component tests passed, with no failures or skips. This
  includes the fixture pair, retry regression, and isolated/scoped Bicep
  fake-process cases. No cloud resources were accessed.
- `./build.ps1 pre-commit` passed: layout and lint clean after one transient
  analyzer retry; 2,273 unit tests passed (nine skipped), 1,093 component
  tests passed (none failed or skipped). The shared host slot was released
  immediately after the command ended. This is local, offline validation,
  not macOS or hosted CI proof.

## Blockers or dependencies

Hosted macOS verification requires the ordinary pull-request CI run after
the branch is pushed. No live Azure or MCR calls or manual workflow dispatch
are part of this slice.
