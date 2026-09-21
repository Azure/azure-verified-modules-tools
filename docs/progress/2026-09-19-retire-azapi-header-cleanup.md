# Retire AzAPI header cleanup

**Status**: complete
**Started**: 2026-09-19
**Updated**: 2026-09-19
**Branch**: `jaredfholgate-improve-mapotf-performance`

## Outcome

Remove the completed AzAPI telemetry-header migration from the Mapotf common
profile so every root, local-module, and example transform does less work.

## Checklist

- [x] Capture a warm-cache transform baseline.
- [x] Remove the retired cleanup rule and dependency edges.
- [x] Remove obsolete tests and update directly related documentation.
- [x] Measure the updated transform.
- [x] Run the pre-commit gate.
- [x] Commit and push the slice.

## Validation

- Before change, three local warm-cache transforms of the
  `terraform-azure-avm-res-mock` fixture took 55.56, 48.45, and 51.33 seconds.
- After change, three local warm-cache transforms of the same fixture took
  50.32, 41.09, and 42.96 seconds.
- Mean runtime fell from 51.78 seconds to 44.79 seconds, a 13.5% improvement.
- Every benchmark run completed with `Status=pass` and zero changed files.
- `./build.ps1 pre-commit`: passed in 12m 06s with layout, lint, unit, and
  component tasks green.

## Blockers or dependencies

None.
