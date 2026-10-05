# Native API version conventions

**Status**: blocked
**Started**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Replace the API-version family wrapper with native resource, catalog and recency
assertions. Preserve extension mappings, recursive resource inspection,
case-insensitive catalog lookup, stable/preview recency windows and advisory
severity. Catalog download remains batched preparation.

## Checklist

- [x] Native assertions and preparation-only resource enumeration.
- [x] Remove the ordinary API checker and migrate its six regression cases.
- [x] Native positive counts, malformed/ambiguous catalog and advisory controls.
- [x] Pester 5/6 qualification and full local gate.
- [x] Preserve qualified work locally under the publication authorization hold (`3f45d6c`).

## Requirement map

Pinned registry `module.tests.ps1:2296-2475`, commit
`ca00e89a931f637f628503a3a625e7d487157496`, defines recursive API inspection,
the four extension mappings, catalog lookup, approved API windows and advisories.
`Resources/bicep/conventions/ApiVersion.Tests.ps1` now owns the actual assertions.

| Requirement | Native evidence |
| --- | --- |
| Catalog availability, resource object/type and API-date shape | Unavailable source and malformed resources fail with specific error diagnostics |
| Recursive symbolic resources; omit deployments/existing resources | Migrated positive cases cover nested deployments and all four extension mappings |
| Case-insensitive provider/type lookup without ambiguity | Positive mixed-case lookup and two case-ambiguous dictionary negatives |
| Nonempty catalog arrays of valid unique API dates | Empty, impossible date, non-string, trailing newline and duplicate controls |
| Five latest overall plus five latest non-preview releases | Stable/preview positives; outdated and oldest-approved warning controls |
| Ordinal API identity and duplicate resource suppression | Case-changed suffix warns; repeated type/API pair still executes exactly 16 native checks |
| Missing provider/type remain advisory; malformed catalog remains error | Explicit severity assertions; no skipped or generic Pester failures |

## Validation

- All six old ordinary-checker unit cases now run the actual native suite in
  `NativeApiVersion.Component.Tests.ps1`, with eleven additional controls.
- Native positive count: 16 independently reported requirements.
- Pester 5.7.1 and 6.2.0 focused runs passed the adapter unit cases and 152
  component cases, one existing platform skip.
- Pester 6.2.0 full `.\build.ps1 pre-commit` passed layout, lint, unit and
  component checks; 1,538 component tests passed, one skipped.
  Elapsed 10m38.92s is not an equivalent-work performance comparison.
- A compiled run without native API discovery is rejected even if every
  remaining reported test passed.

## Publication blocker

The coordinator's explicit authentication hold remains. Preserve the qualified
commit locally; do not change credentials, route around the rejected push,
release a package or update caller pins.
