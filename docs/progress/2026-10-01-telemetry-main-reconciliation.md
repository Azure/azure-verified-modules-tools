# Telemetry main reconciliation

**Status**: in-progress
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
- [ ] Bring in the later E2E region-retry change merged into `main` while this
      reconciliation was running.
- [ ] Run the local pre-commit gate and focused workflow checks, then commit
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
Newer main commits still require reconciliation and another gate before
this slice is complete.

## Blockers or dependencies

[Azure/azure-verified-modules-tools#208](https://github.com/Azure/azure-verified-modules-tools/pull/208)
and [Azure/azure-verified-modules-tools#206](https://github.com/Azure/azure-verified-modules-tools/pull/206)
merged before the `v0.20.0` release, leaving
[Azure/azure-verified-modules-tools#192](https://github.com/Azure/azure-verified-modules-tools/pull/192)
conflicted. This is source reconciliation only: no live Azure feature
registration, repository sync, protected test approval, or pull request merge.
