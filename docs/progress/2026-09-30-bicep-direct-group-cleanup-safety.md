# Bicep direct resource-group cleanup safety

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Prevent the existing resource-group e2e runner from deleting a tagged group
that contains foreign or unverified children. Reconcile its Create-only
preview, deployment operations, live resource identities and group contents
before deleting individually proven resources. Leave ambiguous objects and
the group as `CleanupPending`, including after deployment failures,
cancelled operations or ownership changes.

## Checklist

- [x] Trace resource-group creation, preview, deployment, assertion and
      cleanup paths and their existing fake-Azure tests.
- [x] Reject unknown or foreign group contents before group deletion without
      weakening the existing ownership and failure-reporting contract.
- [x] Exercise successful cleanup and adversarial tags, foreign children,
      failed/cancelled operations and incomplete history with mocked Azure.
- [x] Run the focused checks and full local gate; commit and push this slice
      on the existing review.

## Validation

- Focused Bicep unit/component checks: 66 unit and 99 component tests passed;
  direct-group component rerun after the final adverse case: 66 passed.
- `./build.ps1 pre-commit`: layout and lint passed; 2,073 unit tests passed,
  9 skipped; 1,046 component tests passed across six batches, none failed.
  The gate reported 49 nonfatal warnings from unrelated mocked repository
  management paths.
- Source helpers use UTF-8 without BOM and LF. No live Azure or MCR call,
  workflow dispatch, selector change or registry CI change was made.

## Blockers or dependencies

This direct-group correction does not enable subscription-to-group Create,
select a BAMI test subscription or establish durable interrupted-run recovery.
The offline cross-group helpers still refuse runtime Create. Real route-table
authorization effects and authored idempotency repeats remain separate typed
obligations for full registry testing parity.
Inventory and final tag checks are not atomic with group deletion; the
availability and completeness of Azure resource listings for every provider
have not been verified live. Do not infer safe live deployment from mocks.
