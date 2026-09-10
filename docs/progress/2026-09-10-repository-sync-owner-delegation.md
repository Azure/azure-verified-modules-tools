# Repository sync Owner delegation

**Status**: complete
**Started**: 2026-09-10
**Updated**: 2026-09-10
**Branch**: `jaredfholgate-repository-sync-delegation`

## Outcome

Added the existing Owner role-definition local to both role-assignment condition
exclusions to prevent repository test identities from delegating Owner. Ordinary
role assignments, resource addresses, deterministic names, condition version,
identity settings, federation, and directory membership remain unchanged.

## Checklist

- [x] Confirm a clean worktree at current `origin/main` and no related open change.
- [x] Demonstrate the missing Owner exclusions with focused Pester coverage.
- [x] Correct both write/request and delete/resource exclusions.
- [x] Run focused tests, Terraform format/validation, and the local commit gate.
- [x] Review the focused diff and confirm no unrelated source changes.

## Validation

- Before the fix, `.\build.ps1 test-repository-management` passed 91 tests and
  failed the four new assertions for the missing Owner GUID and three-role count
  in the write/delete lists. Existing denied roles and ordinary Contributor and
  Reader cases passed.
- After the fix, `.\build.ps1 test-repository-management` passed all 95 tests,
  including 14 new condition-contract cases.
- Azure module `terraform fmt -check -diff` and `terraform validate -no-color`
  passed. Missing providers were restored with
  `terraform init -backend=false -input=false -no-color`; the generated provider
  directory and lock file were removed afterward. No provider declarations or
  directory-membership resources changed.
- `.\build.ps1 pre-commit` passed: 1,103 unit tests and 29 component tests,
  zero failures, eight existing skips. The analyzer's built-in retry recovered
  from two transient exceptions; 175 warnings in unchanged module code remain.
- The only Terraform diff is the two condition-list additions. Changed files
  use LF/UTF-8 without BOM.

## Blockers and dependencies

This is a source prerequisite for enabling the isolated repository-sync
controller. No Azure operation, state change, pipeline execution, permission
grant, or controller enablement is authorized in this slice.
