# Native version and changelog conventions

**Status**: blocked
**Started**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Replace the version family wrapper with independent native version and changelog
requirements. Ordinary preparation only reads JSON and extracts source lines,
headings and sections. Preserve semantic ordering, module major-version
exemptions, diagnostic codes and source lines.

## Checklist

- [x] Native version format/major and changelog structure assertions.
- [x] Remove the ordinary version checker and wire strict discovery accounting.
- [x] Native positive execution and negative requirement mapping.
- [x] Pester 5/6 focused checks and full local gate.
- [ ] Preserve the qualified commit locally while publication remains unauthorized.

## Requirement map

Pinned registry source is `module.tests.ps1` at
`ca00e89a931f637f628503a3a625e7d487157496`. Native assertions are in
`Resources/bicep/conventions/Version.Tests.ps1`.

| Existing requirement | Native evidence |
| --- | --- |
| Major/minor format and zero-major policy, lines 1990-2021 | Invalid JSON/root/value/version and nonzero-major failures; approved-module exemption passes |
| Required changelog, line 147 | Existing versioned-child missing-file negative |
| Nonempty file and canonical header/link, lines 1684-1721 | Empty/header negative controls and existing incorrect-link public-command test |
| Semantic release headings and descending unique order, lines 1757-1772 | Malformed heading and duplicate release negatives with exact line locations |
| One Changes and Breaking Changes section, lines 1773-1846 | Missing-section native negative and public-command malformed-section control |
| Section content and order, lines 1847-1927 | Empty-content and reversed-section negatives with exact source lines |
| Published/target releases and parent-version propagation, lines 1722-1756 and 1928-1989/2022 onward | Remain in the separately tracked publication family pending its native migration |

## Validation

- Native-only positive executes 14 independent requirements; the approved
  major-version exemption executes 13. No legacy version validator is retained.
- Thirteen native negative cases assert diagnostic code, source file, line,
  severity, complete execution counts and absence of generic Pester failures.
- Pester 5.7.1 and 6.2.0 focused runs each passed 13 unit and 135 component
  cases, one existing platform skip.
- Pester 6.2.0 full `.\build.ps1 pre-commit` passed layout, lint, unit and
  component checks; 1,521 component tests passed, one skipped.
  Elapsed 9m37.92s is not a performance comparison.
- Linked version/changelog files are not dereferenced during preparation.
  Missing native discovery registration fails even when no version files exist.

## Publication blocker

The existing workflow-scope authorization hold remains. No authentication,
remote update, release or caller cutover was attempted.
