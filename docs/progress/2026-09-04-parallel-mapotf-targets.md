# Parallel Mapotf targets

**Status**: complete
**Started**: 2026-09-04
**Updated**: 2026-09-04
**Branch**: `jaredfholgate-mapotf-transform-regression`

## Outcome

Run independent root, module, and example Mapotf transforms with bounded
parallelism while preserving deterministic results, retries, drift rollback,
and safe behavior when Terraform uses a shared provider plugin cache.

## Checklist

- [x] Add a reusable single-target Mapotf transform worker.
- [x] Run independent transform targets through `Invoke-AvmParallel`.
- [x] Forward the existing throttle through transform, pre-commit, and pr-check.
- [x] Preserve serial execution when a shared Terraform plugin cache is active.
- [x] Cover parallel scheduling, throttle forwarding, and cache safety.
- [x] Update directly related documentation.
- [x] Run the pre-commit gate.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 test`: 1,032 passed, 0 failed, 8 skipped.
- `./build.ps1 pre-commit`: layout, lint, unit, and 29 component tests passed.
- Real six-target canary benchmark against
  `Azure/terraform-azurerm-avm-ptn-example-repo`:
  - throttle 1: 186.14 seconds
  - throttle 4: 65.59 seconds
  - both drift runs restored a clean working tree
- `git diff --check`: passed.

## Blockers or dependencies

None.
