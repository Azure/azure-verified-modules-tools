# Guarded Bicep test tenant propagation

**Status**: in-progress
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
- [ ] Add the separate target-scoped Variables-write token and guarded job.
- [ ] Implement plan-only, no-op, readback, partial/lost-response handling,
  active-bundle retarget protection, and outside-edit detection.
- [ ] Add mocked API tests and preserve CODEOWNERS regressions.
- [ ] Document operator prerequisites and publication limitations.
- [ ] Complete the final local gate and publish on the same feature review.

## Validation

Pending integration. All API tests must be mocked. Successful tuple/selector
publication is not authentication readiness.

## Blockers and dependencies

- Publication stays disabled until explicit operator approval/setup.
- Bicep execution federation and runtime login are unproved. The intended
  subject is
  `repository_owner_id:6844498:repository_id:447791597:environment:avm-validation`;
  never reuse the Tools-controller identity or credential.
- No live variable, secret, federation, role, Azure-resource, or state
  operations are authorized. The parent owns the Bicep consumer and team docs.
