# Key Vault telemetry candidate validation

**Status**: in-progress
**Started**: 2026-10-01
**Updated**: 2026-10-01
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
- [ ] Run the pre-commit gate, commit, and push the existing branch without
      force.
- [ ] Confirm the result with an approved, plan-only candidate preview.

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

An isolated copy of that candidate, with only the three empty random mocks
removed, passed all 34 existing provider-mocked unit runs. Examples still
use random resources, so automatic removal of author-owned test mocks is not
safe for every module; a separate Key Vault test-only repair owns them.
The branch plan-only retest is pending.

## Blockers or dependencies

The Key Vault test-only repair must reach its module's `main` branch before
repository sync can validate that unit suite. Publish was skipped by
plan-only. No production deployment, module publication, or protected-job
approval is authorized by this slice.
