# Bicep PSRule subscription token from the test pool

- Status: complete
- Started: 2026-10-04
- Branch: jaredfholgate-avm-authoring-refactor

## Outcome

Upstream parity behaviour change, separate from the refactor commits. The
Bicep PSRule `subscriptionId` token comes from the first authored entry of
`TEST_SUBSCRIPTION_IDS` when that pool is configured, and from
`VALIDATE_SUBSCRIPTION_ID` otherwise. Previously a workflow that only set the
pool left the token empty.

## Decisions

- The pool is validated by the same `Select-AvmBicepWorkflowSubscription` rules used by e2e, so a malformed pool fails with `AvmConfigurationException` instead of being ignored.
- The first authored entry is used, not the e2e seeded selection, so policy checks are stable between runs.
- `localToken_subscriptionId` still wins.

## Checklist

- [x] `Get-AvmBicepPolicyToken` pool support.
- [x] Unit tests: pool-first, fallback, invalid pools, local override.
- [x] CHANGELOG.
- [x] `./build.ps1 pre-commit` green; commit and push.

## Validation

- `BicepPolicy.Tests.ps1`: 15 passed.