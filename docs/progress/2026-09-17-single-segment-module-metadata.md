# Single-segment pattern and utility metadata

**Status**: complete
**Started**: 2026-09-17
**Updated**: 2026-09-17
**Branch**: `jaredfholgate-single-segment-module-metadata`

## Outcome

Support single-segment pattern and utility canonical types in metadata
validation, lossless Terraform backfill, and catalog generation. In particular,
`avm-utl-naming` must produce `canonicalType: naming` without inventing telemetry,
changing owners, or generating Terraform source. Preserve resource validation,
existing multi-segment identities, grouped Bicep paths, and all ordinary
repository sync controls. Only the two schemas and Terraform inference require
production code changes; existing consumers already distinguish ARM-only fields.

## Checklist

- [x] Trace schemas, inference, root/child classification, catalog conversion,
      and repository creation.
- [x] Implement the narrow non-resource changes with regression coverage.
- [x] Exercise real isolated worker preparation and backfill-to-catalog output.
- [x] Update current contract and rollout documentation.
- [x] Run focused build entrypoints and the full pre-commit gate.
- [x] Complete independent review and record the release prerequisite.

## Validation

This branch starts at `ddedb042cb8860f5cd0bbec195a3b2e0c6223c7d`.

- Focused `build.ps1 test,component -TestName ...` selectors exercised the new
  inference, schema, initializer, worker, identity, and catalog cases. The three
  round-trip fixtures were corrected to include the catalog's required CSV
  headers and passed the focused `build.ps1 component` rerun.
- `build.ps1 pre-commit`: passed layout, lint, 1,517 unit tests and 589 component
  tests; eight unit and one macOS-only component tests skipped on Windows.
  The existing analyzer retry recovered its transient failure. No test failed.
- The real preparation hook and isolated worker preserve `jaredfholgate`,
  omit telemetry for `avm-utl-naming`, and generate no `main.metadata.tf`.
  Current-code authoring and catalog round trips also cover a generic utility,
  an illustrative pattern, and reduced children without mocking validation.
- Independent Opus review: no findings. Grouped Bicep paths, resource
  constraints, explicit values, existing two-part mappings, and ordinary sync
  controls are unchanged.

Fresh hosted checks are required on the published head before merge; their
results belong to that review, not an earlier head's successful run. The public
guide update is coordinated in
[Azure/Azure-Verified-Modules#2936](https://github.com/Azure/Azure-Verified-Modules/pull/2936).

## Blockers and dependencies

The isolated backfill worker uses the tools checkout, but ordinary full-sync
pre-commit uses the installed/released `Avm.Authoring`. A supporting authoring
release is required before full sync can validate the new canonical shape.
This change must not bypass that release boundary. No live sync, deployment,
target repository edit, release, or permission change is authorized.
