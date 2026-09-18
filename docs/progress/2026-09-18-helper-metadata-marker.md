# Child helper metadata marker

**Status**: complete
**Started**: 2026-09-18
**Updated**: 2026-09-18
**Branch**: `jaredfholgate-helper-metadata-marker`

## Outcome

Support exact lowercase `canonicalType: "helper"` for Bicep and Terraform
children of resource, pattern, and utility families. Helpers retain normal
child metadata and inherited root ownership, with optional validated telemetry.
Catalog JSON includes helpers with stable identities and null ARM fields;
every CSV output excludes them without weakening source-row removal guards.

## Checklist

- [x] Read repository contracts and active slices; confirm the clean feature
      branch starts at current `main` and no overlapping open change exists.
- [x] Inspect validation, initialization, discovery, authoring, schemas,
      catalog generation/publication, and temporary backfill.
- [x] Implement child-only helper handling and update directly related docs.
- [x] Cover both ecosystems and all family kinds, invalid roots/telemetry,
      ownership inheritance, mixed inventories, JSON/CSV behavior, and guards.
- [x] Run targeted `build.ps1` selectors and the full pre-commit gate.
- [x] Finalize the scoped code, tests, and documentation for one tools review.

## Validation

The targeted child-helper component tests first reproduced 18 failures against
the unchanged implementation.

- Targeted metadata classification/identity unit tests: 50 passed.
- Child validation/initialization and both authoring chains passed their focused
  matrices. The publication test's non-enumerated collection assertion was
  corrected; the helper catalog/backfill follow-up passed all 37 tests.
- Final review found that a renamed checkout could infer the family kind from
  the helper's own prefix, or fail when that optional prefix was absent. An
  additional 18 failing authoring cases reproduced this; fallback now reads
  the containing context root's metadata without changing path conventions or
  walking ancestors. The follow-up passed 29 identity unit tests and 30
  authoring component tests.
- `.\build.ps1 pre-commit`: passed layout, lint, 1,616 unit tests, and 797
  component tests; zero errors/failures. Eight unit and one component tests
  were skipped for platform-specific behavior on Windows. Existing analyzer
  findings/retries and expected warning-path fixtures remain; no unrelated
  lint cleanup was included. The full gate used the documented process-local
  `DOTNET_MultiCoreJitMinNumCpus=7fffffff` runtime workaround.
- `git diff --check`: passed. Implementation, schema, test, and documentation
  diffs were reviewed before publication.

## Dependencies and boundaries

Base: `d865064712e94f5f185dae3c13f05a103555f3e3`.
Actual helper rollout requires compatible released/installed tooling; this
slice does not release or adopt it. Existing valid metadata stays preserved.
No target repositories, rollout workbook/manifests/helpers/targets, application
credentials, production jobs, Terraform execution, or permission changes are
in scope. The excluded `test-repo5` root and archived/missing/private repository
restrictions remain unchanged. Ordinary missing-metadata warnings remain.
Companion public documentation is in
[Azure/Azure-Verified-Modules#2936](https://github.com/Azure/Azure-Verified-Modules/pull/2936)
at `0b615aa8ec468d63dc64efd14675052c54f3f391`; it does not claim helper support in
the existing `0.15.1` release.
Update the internal Azure-Verified-Modules-Docs metadata how-to alongside the
approved rollout, reusing its existing open review where applicable; no
cross-repository documentation change is made by this slice.
