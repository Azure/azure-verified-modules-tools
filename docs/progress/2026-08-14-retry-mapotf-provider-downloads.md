# Retry transient mapotf provider downloads

**Status**: complete
**Started**: 2026-08-14
**Updated**: 2026-08-14
**Branch**: `jaredfholgate-retry-intermittent-x509-failures`

## Outcome

Retry `mapotf transform` when its internal Terraform provider schema setup fails
with a recognized transient network or provider-download error, while preserving
immediate failure for deterministic transform errors.

## Checklist

- [x] Add bounded, signature-specific retries around `mapotf transform`.
- [x] Keep `mapotf clean-backup` outside the retry loop.
- [x] Cover recovery, exhaustion, and deterministic failure behavior.
- [x] Run the pre-commit gate.
- [x] Commit and update the existing pull request.

## Validation

`./build.ps1 pre-commit` passed: layout and lint succeeded, 958 unit
tests passed with 8 skipped, and 28 component tests passed.

## Blockers or dependencies

None.
