# Telemetry main reconciliation

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Bring the telemetry and candidate-validation branch onto current `main`
without reviving the retired repository-creation scripts or discarding the
feature-registration command shipped in `Avm.Authoring` 0.20.0.

## Checklist

- [x] Keep pending telemetry notes and released initialization notes in the
      changelog, and resolve initialization tests against canonical Terraform
      telemetry identifiers.
- [x] Retain the new `avm init` implementation and remove old creation files
      and tests superseded on `main`.
- [x] Verify feature registration remains isolated to protected test jobs and
      both review workflows still preserve their original safety gates.
- [x] Bring in the later E2E region-retry change merged into `main` while this
      reconciliation was running.
- [x] Preserve the newer Bicep publisher's retired selector configuration,
      Terraform reviewer routing, and clearer feature preflight logging from
      current `main`.
- [x] Run the local pre-commit gate and focused workflow checks, then commit
      and push the existing branch without force.

## Validation

Focused initialization tests: 3 passed. Focused version-forwarding and
repository-creation layout tests: 2 passed after forwarding
`-SkipModuleVersionCheck` through `Register-AvmFeature` and removing the empty
retired directory. Focused managed-file staging tests: 3 passed with an
intentionally blank inherited Git identity after giving their temporary Git
commit an isolated identity. `actionlint` passed for the Terraform test
workflow and both repository-sync workflows. The first full gate passed
2,104 unit tests but found an empty Git identity leaking between component
fixtures: PowerShell converted an absent saved environment variable to an
empty override on restore. Both affected fixture restorations now use
`[NullString]::Value` for absent values; the three focused Git fixture
checks pass. The full gate against the first merged main revision passed:
layout, lint, 2,104 unit tests (9 existing skips), and 965 component tests.
Newer main commits required another reconciliation and gate. The latest
`main` at `a0e6d19` merged without
conflicts; the resulting tree matches it exactly for the Bicep publisher,
reviewer routing, Terraform E2E region-retry implementation, and reusable
feature workflow. The retired Bicep selector configuration remains absent,
and the changelog and migration guide retain the ineligible-region retry.
`actionlint` passed for the protected Terraform, repository-sync, routing,
and Bicep configuration workflows. The final pre-commit gate passed layout,
lint, 2,200 unit tests (9 existing skips), and 969 component tests with no
failures. The diff against current `main` contains only telemetry-branch
changes; the newer Bicep, routing, E2E retry, and feature-registration
implementations are unchanged.

## Blockers or dependencies

[Azure/azure-verified-modules-tools#192](https://github.com/Azure/azure-verified-modules-tools/pull/192)
still requires its normal CI and review before merge and release. This was
source reconciliation only: no live Azure feature registration, repository
sync, protected test approval, or pull request merge.
