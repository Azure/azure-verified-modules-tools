# BAMI selection safety

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-legacy-and-bami-canaries`

## Outcome

Reject a shape-valid disposable test pool that contains the Persistent
subscription. Full source validation also excludes Admin from the pool and
requires Admin and Persistent to be different subscriptions. Keep the exact
eight source variables and five Bicep execution variables.
Also keep disabled BAMI selections pending without reverting an already-active
consumer to legacy. Only a configuration selection of `legacy` may roll back.

## Checklist

- [x] Inspect the reported cross-field validation gap.
- [x] Reproduce it with a shape-valid, unique 28-subscription regression.
- [x] Enforce the shared guard in resolver and candidate/consumer boundaries.
- [x] Enforce the same isolation on the internal Terraform override object.
- [x] Block disabled BAMI selections before cleanup or repository mutations.
- [x] Exercise initially legacy and already-BAMI consumers through the driver,
  with absent/false gates and both plan-only and scheduled-apply behavior.
- [x] Cover action outputs and candidate adapter input preflight.
- [x] Complete local checks for the superseding resolver commit.

## Validation

Reserved-subscription regressions failed before the fix and now pass.
`.\build.ps1 test-repository-management` passed 374 tests; both Terraform
roots pass format/validation and ten mocked-provider tests pass.
`.\build.ps1 pre-commit` is green: 1,420 unit tests passed (8 skipped) and
120 component tests passed, including the integrated Bicep propagation tests.

The first final gate exhausted the existing analyzer's transient exception
retries. A fresh PowerShell process with the documented CI startup workaround
completed the unchanged gate, with analyzer warnings. No checks were disabled.
All calls remain mocked; no live changes are authorized.

## Dependencies

The Bicep consumer must replace its
`6d240a4fb9fd3ae587bf667b536e47b9967537fb` resolver pin after this fix is
published. The interface and five-variable projection are unchanged.
