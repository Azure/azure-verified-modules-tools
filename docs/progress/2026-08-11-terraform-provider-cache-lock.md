# Terraform provider cache lock

Status: complete
Started: 2026-08-11
Completed: 2026-08-11
Branch: jaredfholgate-fix-check-failure-output

## Outcome

Terraform operations now coordinate access when `TF_PLUGIN_CACHE_DIR` is shared. Lint initialization is serialized while lint execution remains parallel; policy workers hold the cache lock through `init`, `plan`, and `show`, then release it before parallel Conftest evaluation.

## Checklist

- [x] Coordinate `terraform init` calls that share `TF_PLUGIN_CACHE_DIR`.
- [x] Apply the coordinator to lint and policy initialization.
- [x] Cover lock acquisition, argument forwarding, and lock release on failure.
- [x] Run `./build.ps1 pre-commit`.
- [x] Run the real-binary integration suite.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 pre-commit`
  - Unit: 893 passed, 7 skipped.
  - Component: 27 passed.
- `$env:AVM_INTEGRATION_FIXTURE = 'terraform-azure-avm-res-mock'; ./build.ps1 integration`
  - Integration: 12 passed, 1 skipped.
- `git diff --check`

## Blockers or dependencies

- None.
