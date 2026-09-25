# Automatic Bicep variable sync

**Status**: complete
**Started**: 2026-09-24
**Updated**: 2026-09-24
**Branch**: `jaredfholgate-automatic-bicep-variable-sync`

## Outcome

Restore the previous Bicep Sync schedule, `33 2-23/4 * * *`, for nonsecret
variable publication. Scheduled and input-free manual runs on trusted Tools
`main` call the existing entry point with `-Apply`, without an activation or
preview flag. The retired CODEOWNERS job stays removed.

The central selection remains `avm/res/dev-test-lab/lab` for BAMI, with
`legacy` as the default. Target-only App permissions, the `avm` environment,
serialized writers, validation, selector-last publication and readback remain
unchanged. Standalone script previews remain available.

An acknowledged write may wait for visibility only while the entire managed
snapshot still exactly matches its pre-write state: one initial GET and at
most three additional GETs after 5/10/15 seconds. No write is retried.
Unexpected changes, failed reads and unacknowledged writes still fail.

## Checklist

- [x] Verify clean current main, existing reviews, prior schedule and selection.
- [x] Restore schedule and remove both workflow inputs and their bindings.
- [x] Update current documentation without rewriting historical progress.
- [x] Cover bounded acknowledged-write visibility without weakening readback.
- [x] Cover workflow publication and standalone previews with offline tests.
- [x] Run focused tests and the required local gate.
- [x] Prepare the validated slice for commit, push and review.

## Validation

- Focused `.\build.ps1 test -TestName ...`: 132 Bicep publication tests passed,
  plus 20 central-selection and input-validation tests.
- Focused `.\build.ps1 component -TestName ...`: 24 tests passed, including
  actual workflow commands and byte-exact 28-object JSON through real child
  processes for POST and PATCH with delayed collection visibility, plus the
  catalog workflow's schedule contract.
- The first full gate identified the catalog workflow's obsolete assertion
  that Bicep has no schedule. Updated that existing contract to preserve the
  distinct Terraform, catalog and restored Bicep start times.
- `.\build.ps1 pre-commit`: passed layout and lint, 1,826 unit tests passed
  (9 skipped), and all 810 component tests passed.
- Protected selection, validation, entry-point and process-transport files are
  unchanged. Whitespace and LF/UTF-8-without-BOM checks passed.

## Blockers and dependencies

None for source changes. Live publication and consumer readback belong to the
coordinating session; this slice does not dispatch workflows, change variables
or permissions, perform Azure operations, or merge changes. Internal team
documentation is also handled by the coordinating session.

The coordinating session's
[one-time publication](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36009533957)
failed subscription-pool readback before writing the selector. Later readback
matched all five execution values, including valid byte-identical subscription
JSON. The failing response was not captured, so the live cause remains unproven.
The bounded wait handles only the justified stale-snapshot case, not every
mismatch; process argument serialization is unchanged.
