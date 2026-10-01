# Bicep isolated end-to-end deployment

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Run eligible Bicep `tests/e2e` examples against a real Azure resource group
through `avm test e2e`, using a uniquely named, tagged, disposable group per
example. Validate and inspect what-if before deployment, then verify ownership
and ARM's succeeded deployment response before deleting the group even on a
failed deployment. Never touch an existing group or report an incomplete
cleanup as a pass.

## Checklist

- [x] Reuse integration example discovery, selectors, tokens and temporary
      compiled templates; support offline `-List` and opt-out markers.
- [x] Require an explicit subscription, location and group-name prefix; reject
      non-resource-group, linked, scripted, authorization and cross-scope
      resources before creating any group.
- [x] Refuse unsafe or incomplete what-if previews, guard state-changing
      operations with ShouldProcess, and verify group ownership on cleanup.
- [x] Report deployment failures and any unremoved group explicitly, with
      mocked-process coverage of success, denial, partial failure and cleanup.
- [x] Preserve Terraform e2e behavior, update help and run pre-commit.

## Validation

`./build.ps1 pre-commit`: layout and lint passed, 1,940 unit tests passed
(9 skipped), and 968 component tests passed. `./build.ps1 coverage`: 73.5%,
above the 70% floor. All Azure-facing tests used mocked processes; no live
Azure deployment was authorized or run.

## Blockers or dependencies

The user was unavailable to decide a cleanup policy. Restrict this tier to a
new disposable resource group with ownership tagging and reject other scopes
explicitly. Subscription, management-group and tenant templates remain
available in the validation/what-if tier but cannot be deployed safely here
without a separately designed ownership and cleanup strategy. This slice
checks ARM's deployment provisioning state but does not run authored
post-deployment Pester assertions or replace the registry's e2e lifecycle.
The existing registry CI and local-testing guidance remain in place; policy
and convention parity are separate work.
