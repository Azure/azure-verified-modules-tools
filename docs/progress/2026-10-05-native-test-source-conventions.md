# Native Bicep test-source conventions

**Status**: blocked
**Started**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Move test-source requirements into native Pester and reuse the source inventory
already collected for batched compilation. Preserve literal metadata,
deployment declarations, service-short uniqueness/suffixes and scope references.

## Checklist

- [x] Native source assertions and removal of the ordinary test-file checker.
- [x] Reuse collected sources and compiled test data without another recursive scan.
- [x] Independent positive counts, negative diagnostics and completeness controls.
- [x] Pester 5/6 focused qualification and full local gate.
- [x] Preserve the qualified commit locally while publication is unauthorized.

## Requirement map

Pinned registry `module.tests.ps1` at
`ca00e89a931f637f628503a3a625e7d487157496`; native destination is
`Resources/bicep/conventions/TestSource.Tests.ps1`.

| Requirement | Native evidence |
| --- | --- |
| Scope-specific direct test references, line 2127 | Existing multi-scope mismatch negative |
| Literal serviceShort and min/max/waf suffixes, lines 2150-2203 | Native positive, absent serviceShort and existing suffix failures |
| Literal metadata name/description, lines 2204-2219 | Separate native requirements and both missing-name/description negatives |
| Exact namePrefix and relative testDeployment, lines 2220-2268 | Existing placeholder, relative module and deployment-name negatives |
| Repository-wide serviceShort uniqueness, line 2269 onward | Existing duplicates inside another module and outside avm/ |
| Strict source reading and mandatory suite registration | Invalid UTF-8 error and missing-registration unit negative |

## Validation

- Native-only positive: 27 independently reported requirements across three
  representative sources.
- Pester 5.7.1 and 6.2.0 focused runs each passed 15 unit and 139 component
  tests, one existing platform skip.
- Pester 6.2.0 full `.\build.ps1 pre-commit` passed layout, lint, unit and
  component checks; 1,542 component tests passed, one skipped.
  Elapsed 8m54.94s is not an equivalent-work performance comparison.
- Preparation reuses the exact source inventory already collected for
  compilation, including sources whose compilation failed, without re-scanning
  each tests tree. It does not compile again.

## Publication blocker

The workflow-scope authorization hold remains. No authentication change, remote
update, release or live registry cutover was attempted.
