# Bicep metadata sync

**Status**: complete
**Started**: 2026-10-06
**Updated**: 2026-10-06
**Branch**: `jaredfholgate-bicep-metadata-sync`

## Outcome

Allow generated Bicep CSVs to remove submodule records without requiring
`Force`, while preserving the removal guard for root modules. Derive a
multi-scope Bicep root's published status from its scoped modules: at least
one published scope makes the root published.

Lifecycle status uses direct `rg-scope`, `sub-scope`, and `mg-scope` releases.
The parent's registry record remains specific to its own path; no version
or publication date is invented. Ordinary children remain independent.
Published scoped families also remain indexed when deprecated.

## Checklist

- [x] Read repository guidance and check the current branch and related reviews.
- [x] Trace source-row protection and multi-scope publication evidence.
- [x] Update the shared generation and publication paths with regression tests.
- [x] Update the directly related catalog documentation.
- [x] Run the prescribed local gate.
- [x] Prepare the completed slice for commit and review.

## Validation

Regression tests reproduced 16 expected failures before the implementation,
with nine controls passing. Coverage includes removed children across all
three Bicep module kinds, root and malformed identity protection, unchanged
Terraform helper guards, each supported scope, ownership/deprecation, and
incomplete publication evidence.

The failed [catalog run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37505620872)
reported the removed `advanced-threat-protection` and `consumergroup`
submodules. Replaying the shared guard against the subsequent
[run's artifact](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37524568355)
recognizes exactly those two removals and zero protected removals.
The same artifact shows published authorization scope modules beneath
Proposed parents; the checked-in regression fixture reproduces that shape.

Pester 5.7.1 qualification:

- `.\build.ps1 component -TestName 'Component: module catalog*'`: 331 passed,
  zero failed or skipped. Expected negative-case warnings remain visible.
- `.\build.ps1 pre-commit`: layout and lint passed; 3,028 unit tests passed
  with nine existing skips; 1,408 component tests passed with one existing
  skip. Five tasks completed with zero errors or warnings.
- `git diff --check` passed.

Tests use local snapshots, local Git fixtures, and mocked external services.
No live workflow was dispatched and no catalog was published.

## Blockers or dependencies

None. No live catalog publication or workflow dispatch is authorized or
required for this slice.
