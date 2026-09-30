# Repository-sync validation identity federation

**Status**: complete
**Started**: 2026-09-29
**Updated**: 2026-09-29
**Branch**: `jaredfholgate-repo-sync-identity-federation`

## Outcome

Federate the existing per-module non-production test identities for the tools
repository's `avm-validation` environment, without changing their existing
trusts, provisioning a new identity, or adding validation jobs or publishing
behavior. Expose the effective test identity and subscriptions in root
Terraform plan outputs for a later repository-sync validation slice.

## Checklist

- [x] Verify the existing identity, BAMI plan allowlist, and current subject.
- [x] Add scoped federation to the existing ordinary and BAMI test identities.
- [x] Expose plan-readable root identity and test-subscription outputs.
- [x] Cover both Terraform layouts, outputs, and safety invariants with tests.
- [x] Run the local gate and prepare the deployment handoff.

## Validation

GitHub's tools-repository OIDC customization was verified as
`repository_owner_id`, `repository_id`, `context` (no reusable-workflow claim).
The immutable Azure organization and tools repository IDs were verified as
`6844498` and `1239632211`.

`./build.ps1 pre-commit` passed: 1,835 unit tests and 824 component tests;
the 50 warnings came from existing negative-test fixtures. All three Terraform
roots passed `terraform validate` after backend-disabled initialization.
Mocked `terraform test` passed 10 repository-sync, 2 shared identity, and 2
BAMI cases. The changed HCL passed `terraform fmt -check`, and the diff passed
`git diff --check`. No Azure resource operation was run.

The root `test_settings` output exposes `client_id`, `tenant_id`, and the
configured `{name, id}` subscription list from the effective legacy or BAMI
settings, including the 28 BAMI ephemeral subscriptions. It is available in
the planned outputs when the existing identity is known.

## Dependencies

The new federated credential cannot be provisioned by a plan-only preview.
A separately approved apply to the existing non-production test identities is
required before the first plan-only branch preview can authenticate through
`avm-validation`. BAMI plan-only returns a pending candidate instead of
publishing settings while the credential still has a planned change. The
`avm-validation` environment and its jobs belong to a later slice; this slice
does not run an apply, a scheduled repository sync, or a protected-environment
approval.
