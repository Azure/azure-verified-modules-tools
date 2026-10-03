# Bicep metadata and Terraform telemetry merge

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Bring the latest `main` branch into the Terraform telemetry and
repository-sync validation branch without dropping the newly merged Bicep
metadata initialization behavior or changing the agreed telemetry contract.

## Checklist

- [x] Reconcile the implementation-spec, transform, and unit-test conflicts
      while retaining both upstream and branch behavior.
- [x] Run the local pre-commit gate on the combined branch.
- [x] Commit and push the non-rewriting merge.

## Validation

Kept upstream local Bicep initialization, transform confirmation, and
source-free proposed-module behavior alongside Terraform telemetry and its
public `-WhatIf` test. Updated three incoming Terraform-initialization
fixtures to use the current seven-hex metadata prefix; the production schema
was not loosened. `./build.ps1 pre-commit` passed with 1,946 unit tests,
936 component tests, 9 platform skips, and no errors. No live sync or Azure
operation was started for this merge.

## Blockers or dependencies

The manual branch plan-only BAMI canary is authorized for one module but
must wait for the currently running main-branch sync and the new head's
GitHub checks to finish.
