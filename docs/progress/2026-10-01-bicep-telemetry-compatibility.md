# Bicep telemetry convention compatibility

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Completed**: 2026-10-01
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Close the telemetry-literal convention coverage gap while keeping both
approved authored forms: the registry's `telemetryIdPrefix` loaded with
`'telemetryIdPrefix'` and the previously shipped Tools
`avmTelemetryIdPrefix` loaded with `'$.telemetryIdPrefix'`. Retain their
exact `enableTelemetry` descriptions, metadata-prefix agreement, and
deployment/condition/output checks on compiled root and child modules.
Do not change the metadata writer or registry workflow. README parity and
resource-folder singularization remain fail-closed.

## Checklist

- [x] Compare current source/compiled telemetry checks to pinned registry
      assertions M:872, M:1240-1313 and D:75; identify any genuine gaps.
- [x] Add positive and negative fixtures for both exact source forms,
      descriptions, compiler aliases, and telemetry deployment names.
- [x] Independently review the slice and update the per-assertion ledger.
- [x] Run the unfiltered `./build.ps1 pre-commit`, commit and push the
      existing feature branch, then update its review body.

## Validation

Focused `./build.ps1 component -TestName 'Bicep static convention checks*'`:
101 passed, one Windows-only skipped, before the final two focused
fixtures (both passed). Independent review identified crossed
source/description pairs, a conditional deployment name with an
unprefixed fallback, and the absence of versioned-child fixtures.
All three are now covered by paired-form checks, a first-argument
prefix requirement, and positive/negative child tests. A read-only
scan of the current registry checkout at
`5c123604fa1da88e3d98e2acb01f4b8a8ea5b4c2` found 544 compiled
top-level telemetry deployment names; all place the canonical prefix
as the first `format` argument. This scan does not qualify README
parity. The unfiltered `./build.ps1 pre-commit` passed layout, clean lint,
1,974 unit tests (nine skipped) and 1,033 component tests (one Windows-only
skip). Its 49 warnings come from existing negative-path tests. No live
MCR/Azure request, registry CI change or release occurred.

## Blockers or dependencies

The separate metadata source writer change remains open in
[tools #201](https://github.com/Azure/azure-verified-modules-tools/pull/201).
Both source forms remain accepted during transition; no registry-wide
backfill or migration has approved rejecting authored legacy modules.
