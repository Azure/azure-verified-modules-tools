# Terraform validation performance

**Status**: complete
**Started**: 2026-10-07
**Updated**: 2026-10-07
**Branch**: `jaredfholgate-fix-avm-command-slowdown`

## Outcome

Restore practical `avm pre-commit` and `avm pr-check` runtimes by initializing
each source example at most once and reusing its persistent `.terraform` module
cache for validation. Use one AVM-wide provider cache and one Mapotf provider
schema cache so provider binaries and schemas are not repeatedly downloaded or
resolved. Isolated lint and policy working copies retain one initialization per
copy because they cannot safely consume source-directory initialization.

## Checklist

- [x] Trace composite command timing and the Terraform validate path.
- [x] Add a default AVM-managed Terraform provider cache.
- [x] Coordinate cache access through the existing Terraform init lock.
- [x] Add a central Mapotf provider-schema cache.
- [x] Add an initialize step and reuse prepared example module caches.
- [x] Add focused unit and component regression coverage.
- [x] Run the focused routes and full local gate.
- [x] Commit, push, and open the pull request.

## Validation

- `./build.ps1 layout` passed.
- `./build.ps1 lint` passed after the repository's known transient
  PSScriptAnalyzer retries.
- `./build.ps1 test` passed.
- `./build.ps1 component` passed.
- Final `./build.ps1 pre-commit` passed in 11m 34s: layout, lint, unit,
  and component gates all completed with zero failures.
- Real pinned-binary benchmark against a clean writable copy of
  `tests/fixtures/modules/terraform-azure-avm-res-mock`:

  | Cache state | Command | Result | Duration | Initialize | Validate |
  | --- | --- | --- | ---: | ---: | ---: |
  | Cold | `avm pre-commit` | pass | 45.3s | 40ms | n/a |
  | Cold | `avm pr-check` | pass | 121.5s | 29.8s | 4.2s |
  | Warm | `avm pre-commit` | pass | 8.8s | 14ms | n/a |
  | Warm | `avm pr-check` | pass | 87.5s | 81ms | 3.8s |

  The warm `pr-check` initialize step only checked the three prepared source
  examples and did not invoke Terraform initialization again. Validation reused
  their persistent `.terraform` module manifests. The remaining warm cost is
  primarily the intentionally isolated lint (39.5s) and policy (35.3s) stages.

## Blockers or dependencies

None. This work performs no Azure deployment or production action.
