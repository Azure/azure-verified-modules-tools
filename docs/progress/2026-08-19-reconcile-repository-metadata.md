# Reconcile repository metadata

**Status**: complete
**Started**: 2026-08-19
**Updated**: 2026-08-19
**Branch**: `jaredfholgate-reconcile-repository-metadata`

## Outcome

Reconcile `repository-metadata.csv` with the live Azure GitHub repositories
whose names match the supported Terraform AVM naming convention.

## Checklist

- [x] Enumerate Azure repositories for the `azure`, `azurerm`, and `azapi`
      Terraform providers.
- [x] Compare unique module IDs and module-level archive state with the CSV.
- [x] Add missing module metadata and remove stale or duplicate entries.
- [x] Validate the reconciled CSV and repository-management tests.
- [x] Commit, push, and open a pull request.

## Validation

- Live GitHub reconciliation: 225 repositories, 223 unique module IDs,
  223 CSV rows, no missing or stale IDs, no duplicates, no archive mismatches,
  and module IDs sorted.
- `./build.ps1 pre-commit`: 5 tasks, 0 errors; 28 component tests passed.

## Blockers or dependencies

None.
