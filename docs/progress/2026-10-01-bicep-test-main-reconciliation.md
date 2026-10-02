# Bicep test main reconciliation

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Merge `main` at `0e9e166204071a9d12cd4796dcfc96713c8e2225` into the
existing Bicep test branch so
[the open review](https://github.com/Azure/azure-verified-modules-tools/pull/202)
can run ordinary pull-request checks. Preserve main's intended behavior and
the existing once-per-attempt `post.ps1`, typed results, failure and cleanup
guards. The only textual conflict was `CHANGELOG.md`: preserve both the new
Terraform repository-creation entries from main and the Bicep test entries,
and correct the Bicep e2e description to reflect its scoped subset, assertions
and post hook. The dispatcher, module README and implementation spec merged
without conflicts. Do not enable additional deployment scopes or restore the
superseded recovery journal.

## Checklist

- [x] Confirm the review is open and refresh `origin/main` without changing the
      current branch or worktree.
- [x] Merge `origin/main` into the existing branch and resolve each conflict
      without losing either side's intended behavior.
- [x] Run focused offline regressions for touched surfaces and the full
      `./build.ps1 pre-commit` gate.
- [x] Commit and push the reconciliation; verify the review is mergeable and
      report hosted checks without treating the local gate as a remote pass.

## Validation

- Focused `./build.ps1 test,component -TestName ...` passed Bicep e2e post-hook
  unit checks and isolated, scoped and integration fake-process suites.
- `./build.ps1 pre-commit` passed: layout and lint clean; 2,266 unit tests
  passed (nine skipped), 1,090 component tests passed (none skipped or failed).
- `git diff --cached --check` found no whitespace errors; there are no
  unresolved merge paths. Hosted pull-request checks are separate from this
  local gate and require the normal push trigger.

## Blockers or dependencies

No live Azure, MCR, legacy CI cutover, manual workflow dispatch or release is
authorized.
