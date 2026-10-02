# Key Vault telemetry candidate validation

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Use the exact staged Key Vault candidate to identify and repair shared
telemetry transformation defects without changing authored module behavior or
weakening candidate validation.

## Checklist

- [x] Reproduce the child-variable second-pass drift and identify its source.
- [x] Determine whether retired random-provider mocks are safe to remove
      automatically or require a module-owned repair.
- [x] Add focused regression coverage for any shared transform change.
- [x] Run the pre-commit gate, commit, and push the existing branch without
      force.
- [x] Confirm the result with an approved, plan-only candidate preview.

## Validation

The exact [Key Vault plan-only candidate](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36922413450)
passed Prepare but failed Validate on second-pass changes to
`modules/key/variables.tf` and `modules/secret/variables.tf` and on three
obsolete empty random mocks in its unit tests. Its only variable drift was
moving the newly generated required `location` after the authored required
`key_vault_resource_id`. Moving `sort_variables` from `module` to the
already-required later `module-call` pass made an isolated replay
byte-idempotent. The new real-MaPoTF regression passed, the profile inventory
test passed, and all 21 telemetry integration cases passed offline.
The full `./build.ps1 pre-commit` gate passed layout, lint, 2,590 unit
tests (9 existing skips), and 1,287 component tests (1 existing skip).

The updated shared transform removed those three empty random mocks from
the exact staged candidate without touching examples, kept the next drift
check clean, and passed all 34 existing provider-mocked unit runs. It leaves
mocks in place when a module, local child, or test setup still uses random,
and rejects custom mocks or test references for manual review. All 21
real-MaPoTF telemetry integration cases passed. The full gate on the
isolated central cleanup passed layout, lint, 2,597 unit tests (9 existing
skips), and 1,287 component tests (1 existing skip).

Central cleanup was committed and pushed as `b4fd7d3`. The subsequent
[Key Vault plan-only retest](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36983140005)
passed Prepare and Validate on that exact commit; Publish was skipped.
Project synchronization was also disabled. The source-based candidate
therefore passed without a direct Key Vault module repair. Advisory lint
warnings remain and were not suppressed to obtain this result.
Validation executed all 34 existing unit runs: 34 passed, none failed or
skipped. The receipt records base
`42e230776874d00448a98857a86ba0bff9ea3801` and candidate tree
`266d5a6be246517c6a84e560d39591cc90c1bac7`.

## Blockers or dependencies

No Key Vault module change is needed for its standard empty random mocks.
The prior candidate did not publish. Any non-standard test that still uses
random must be reviewed by its module owner; this slice does not authorize
production deployment, module publication, or protected-job approval.
