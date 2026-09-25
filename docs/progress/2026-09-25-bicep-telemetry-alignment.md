# Bicep telemetry alignment

**Status**: complete
**Started**: 2026-09-25
**Updated**: 2026-09-25
**Branch**: `jaredfholgate-bicep-telemetry-alignment`

## Outcome

Share Terraform's seven-character hexadecimal identifier generator with Bicep,
preserve historical prefixes in module metadata and generated catalog JSON
without changing schema versions, and keep Terraform repository creation on
the same implementation.

## Checklist

- [x] Share the seven-character telemetry identifier implementation across
      Terraform and Bicep module creation.
- [x] Extend the version-1 metadata and catalog schemas, validation, and
      generated JSON with optional historical telemetry prefixes.
- [x] Prevent Terraform repository creation from reusing retired identifiers.
- [x] Cover the shared change with focused tests and the local pre-commit gate.

## Validation

`.\build.ps1 pre-commit` passed: layout and lint clean, 1,831 unit tests passed
(9 skipped), and 823 component tests passed.

## Blockers and dependencies

Bicep bootstrap, the telemetry specification, and the fleet backfill belong in
`Azure/bicep-registry-modules` and are tracked separately. Its new metadata
needs this repository's v1 schema on `main`; local bootstrapping also needs an
Avm.Authoring release containing `New-AvmTelemetryIdPrefix` before it can use
the installed module.
