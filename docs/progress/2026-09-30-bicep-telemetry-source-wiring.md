# Bicep telemetry source wiring

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-metadata-independence`

## Outcome

Generate the registry's canonical `telemetryIdPrefix` variable and
`loadJsonContent('metadata.json', 'telemetryIdPrefix')` lookup for new Bicep
source wiring and root scaffolds. Preserve existing authored source that
already uses either this form or the earlier `avmTelemetryIdPrefix` form,
including independent Bicep and JSON descriptions.

## Checklist

- [x] Align new source wiring and the root scaffold with the registry form.
- [x] Recognize both existing forms without rewriting them; reject variable
  collisions before writes.
- [x] Add focused tests for generation, existing-source preservation, and
  invalid source.
- [x] Update the implementation spec and pass the pre-commit gate.
- [x] Commit and push this follow-up slice to the existing feature branch.

## Validation

`.\build.ps1 pre-commit` passed layout and lint, 1,908 unit tests
(9 skipped), and 934 component tests across six groups. The build reported
49 warnings from unrelated test fixtures and no errors. A focused
`.\build.ps1 pre-commit -TestName ...` run passed six unit and 66 component
tests without warnings. The first full run caught a CRLF line ending in the
new helper; it was normalized to LF before the successful full rerun.
`git diff --check` found no whitespace errors. The native integration tier
was not run because this slice is restricted to code and mocked tests.

## Blockers or dependencies

No registry or Azure operations are part of this slice. Source already using
either recognized form stays unchanged; a conflicting variable declaration
requires an explicit error rather than an automatic migration.
