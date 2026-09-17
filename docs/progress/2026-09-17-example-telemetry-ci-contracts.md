# Example telemetry CI contracts

**Status**: in-progress
**Started**: 2026-09-17
**Updated**: 2026-09-17
**Branch**: `jaredfholgate-example-telemetry-variable`

## Outcome

Repair integration assertions affected by the new example telemetry variable
files in [#132](https://github.com/Azure/azure-verified-modules-tools/pull/132).
The AzAPI fixture now has ten direct example configuration files, not seven.
The legacy-header regression must preserve the existing telemetry variables
file while still proving unrelated input/output declarations remain in main.tf.
No production behavior changes are required.

## Checklist

- [x] Inspect the two failures and their fixture contracts.
- [x] Update exact file-count and byte-preservation assertions.
- [x] Add a safe focused regression for the existing variable-file layout.
- [x] Run focused integration tests and the full local pre-commit gate.
- [ ] Commit and push to the existing feature branch.
- [ ] Wait for the complete GitHub CI matrix and resolve any remaining failures.

## Validation

Local validation:

- `.\build.ps1 integration -TestName` selecting the AzAPI deprecated-interface
  fixture and the new example-layout regression: two passed, zero failed or
  skipped. Pinned Terraform and MaPoTF ran without changing OS settings.
- `.\build.ps1 pre-commit`: 1,551 unit tests passed with eight skips;
  597 component tests passed with one skip. Zero failures or build errors,
  30 warnings from existing scenarios. Runtime: 12m 50s.
- Logs and NUnit reports are retained in the session artifact directory.

Remote validation is pending. Original CI
[run 35258875072](https://github.com/Azure/azure-verified-modules-tools/actions/runs/35258875072)
passed all three build jobs but failed all six integration jobs: six stale
file-count assertions and three stale variables.tf-absence assertions.

## Blockers and dependencies

Do not run the broad real-binary chain suite locally: its Windows setup changes
Defender exclusions. Use safe focused tests locally and ordinary GitHub CI for
the complete integration cases. No production or OS-setting changes are allowed.
