# Guarded Bicep test tenant propagation

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-legacy-and-bami-canaries`

## Outcome

Add a separate nonsecret variable-sync job and adapter to Bicep Sync, without
changing the CODEOWNERS writer or its token. Use the
[central selection contract](2026-09-15-legacy-and-bami-canaries.md), validate
all eight source values, publish only the five execution values, and publish
derived selector metadata last after complete consumer readback.

## Checklist

- [x] Agree the exact source, projection, and resolver contract.
- [x] Add the separate target-scoped Variables-write token and guarded job.
- [x] Implement plan-only, no-op, readback, partial/lost-response handling,
  active-bundle retarget protection, and outside-edit detection.
- [x] Add mocked API tests and preserve CODEOWNERS regressions.
- [x] Document operator prerequisites and publication limitations.
- [x] Complete the final local gate for publication on the same feature review.

## Validation

Final `.\build.ps1 pre-commit` passed 1,423 unit tests (8 skipped) and
120 component tests, including 114 variable-sync unit tests and five mocked
entry-point component tests. `.\build.ps1 test-repository-management` passed
377 tests. Reserved-subscription regressions assert exactly zero snapshot,
API, and process calls; other no-write assertions also use exact counts.

The unchanged analyzer required its documented transient retries and completed
with warnings. A temporary local `NO_COLOR` override broke an existing color
test; removing that override restored the normal test environment for the
successful final run. No checks were disabled. All API tests are mocked.
Successful tuple/selector publication is not authentication readiness.

The corrected core resolver is published at
`c70eaed1f330c3b2e51de9db0b56a10205f38a03` in
[the shared draft review](https://github.com/Azure/azure-verified-modules-tools/pull/122).
Its action and shared-library GitHub blobs were verified against the local
commit. The Bicep consumer owner has received this literal pin.

## Blockers and dependencies

- Publication stays disabled until explicit operator approval/setup.
- `AVM_BAMI_TEST_TENANT_SYNC_ENABLED` is a repository variable, not an `avm`
  environment variable, so it is available to the Bicep job-admission condition.
  The eight source values remain in the `avm` environment.
- Bicep execution federation and runtime login are unproved. The intended
  subject is
  `repository_owner_id:6844498:repository_id:447791597:environment:avm-validation`;
  never reuse the Tools-controller identity or credential.
- No live variable, secret, federation, role, Azure-resource, or state
  operations are authorized. The parent owns the Bicep consumer and team docs.
