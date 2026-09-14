# CODEOWNERS CI compatibility

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-terraform-code-owners`

## Outcome

Fix the two test failures reported by
[the ownership change CI run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/34893397682)
without changing shipped behavior.

- The CODEOWNERS reparse-point test mocked only the target file. Pester 6.2.0
  rejects the preceding `.github` lookup because it has no matching mock;
  Pester 5.7.1 fell back to the real command.
- A Terraform validation test declared an `It` block inside another `It`.
  Registering that test during execution mutated Pester's test collection,
  causing `Collection was modified; enumeration operation may not execute`
  and leaving the inner regression unexecuted.

## Checklist

- [x] Restore the worktree exactly to the last pushed commit before starting.
- [x] Verify both failures in the hosted Windows, Linux, and macOS logs.
- [x] Mock both expected filesystem lookups explicitly.
- [x] Make the nested validation case a sibling test.
- [x] Run the local gate and the CI task using Pester 6.2.0.
- [x] Prepare the focused, validated fixes for the existing review.

## Validation

- `.\build.ps1 ci` with Pester 6.2.0: 1,275 unit tests and 93 component tests
  passed; 86.34% coverage against the unchanged 70% floor.
- `.\build.ps1 pre-commit` with Pester 5.7.1: 1,275 unit tests and 93 component
  tests passed.
- Both runs have zero failed or unexecuted tests and no container/teardown
  failures. The eight existing platform-specific unit skips remain.
- The previously nested directory-creation failure regression now executes,
  increasing the passing unit count by one.

Both commands completed with existing analyzer warnings but no errors. CI's
missing Pester 6.2.0 was downloaded from PowerShell Gallery into the ignored
`out/ci-modules` directory, not installed into the user's module catalog. The
existing Pester 5.7.1 installation remains unchanged.

## Blockers and dependencies

None. No live synchronization, permissions, workflow changes, or merges are in
scope.
