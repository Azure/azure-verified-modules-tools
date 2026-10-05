# Native child publishing and portable approvals

**Status**: blocked
**Started**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Replace the child-publishing family wrapper with native file, configuration and
per-child approval assertions. Read consumer-owned approvals from
`.avm/child-module-publish-allowed-list.json`, not registry utilities.
The registry owner is adding an identical compatibility copy and retaining the
legacy file for existing releases; no live cutover is authorized.

## Requirement map

| Previous requirement | Native destination | Evidence |
| --- | --- | --- |
| Exact-case regular child version file | `ChildPublish.Tests.ps1`, per-child file case | Valid file and mis-cased filename controls |
| Strict canonical approval configuration when children are versioned | Native configuration case and existing strict JSON reader | Missing, malformed, wrong shape/case, escaping, duplicate and invalid UTF-8 controls |
| Explicit approval of each versioned child; pinned registry `module.tests.ps1:130-143` | Independent native membership case per child | Native-only three-case positive and missing-child negative |
| No approval file required for unversioned children | Conditional preparation and native discovery accounting | Missing config with unversioned child passes; omitted native suite still fails |

## Checklist

- [x] Native assertions and removal of the ordinary child checker.
- [x] Portable configuration and fixture/test updates.
- [x] Positive native execution counts, negative diagnostics and completeness.
- [x] Pester 5/6 qualification and full local gate.
- [ ] Commit and push when workflow-authorized authentication is available.

## Validation

- Pester 5.7.1 and 6.2.0 focused runs each passed 13 unit and 120 component
  cases, with one existing platform skip.
- The native-only positive executes three independently reported requirements,
  not an aggregate legacy-validator assertion.
- A legacy-only approval file is rejected; normal positive fixtures now use
  `.avm/` without the utility approval file.
- Pester 6.2.0 `.\build.ps1 pre-commit` passed layout, lint, unit and component
  checks; 1,506 component cases passed, one skipped. Elapsed 9m20.69s is not an
  equivalent-work performance comparison.

## Publication blocker

The coordinator explicitly confirmed no authorization to change credentials,
permissions or authentication overrides. Preserve this qualified work locally
behind `d3fac2a` and `5d8dfdf`; do not route around the workflow-scope rejection.
Source-only migration and qualification continue while publication is blocked.
