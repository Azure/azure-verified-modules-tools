# PR reviewer routing validation

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: `jaredfholgate-pr-reviewer-routing-validation`

## Outcome

Split the PR reviewer-routing workflow and its directly required scripts and
tests from draft PR #171 so it can be merged independently for live
`workflow_dispatch` validation. The schedule remains disabled until that
validation is complete.

## Checklist

- [x] Copy only the reviewer-routing workflow, scripts, libraries, and tests.
- [x] Verify no dependency is introduced from unrelated PR #171 changes.
- [x] Disable the workflow schedule and document why.
- [x] Run the repository validation gate.
- [x] Commit, push, and open a PR against `main`.

## Validation

- Targeted reviewer-routing tests: 38 passed, 0 failed.
- `./build.ps1 pre-commit`: 1,556 unit tests passed, 9 skipped; component
  batches passed 903 tests with 1 skipped; 0 failed.
- No reviewer-routing-specific component test exists.
- Shared `RetryHelpers.ps1` and `RepoTree.ps1` are unchanged from `main` and
  are used without copying or modification.

## Blockers or dependencies

- A human must merge the standalone PR before live `whatIf: true` dispatch
  validation can run.
