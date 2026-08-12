# Retry intermittent x509 failures

**Status**: complete
**Started**: 2026-08-12
**Updated**: 2026-08-12
**Branch**: `jaredfholgate-retry-intermittent-x509-failures`

## Outcome

Repository management GitHub CLI operations retry transient TLS certificate
validation failures with bounded incremental backoff instead of failing an
otherwise healthy repository sync.

## Checklist

- [x] Classify the failed jobs and affected GitHub CLI operations.
- [x] Add shared retry patterns for transient x509 and TLS failures.
- [x] Route direct repository-sync GitHub CLI operations through the retry helper.
- [x] Cover transient retry and deterministic failure behavior with tests.
- [x] Run the pre-commit gate.
- [x] Commit, push, and open the pull request.

## Validation

`./build.ps1 pre-commit` passed: layout and lint succeeded, 896 unit
tests passed with 8 skipped, and 28 component tests passed.

## Blockers or dependencies

None.
