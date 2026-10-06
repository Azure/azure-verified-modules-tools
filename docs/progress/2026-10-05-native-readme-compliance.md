# Native README compliance

**Status**: blocked
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Move README existence and generated-content comparison into packaged native
Pester requirements. Preserve compiler/render diagnostics, nonwriting drift
checks, and the existing narrowly verified grouping-comment warning.

## Checklist

- [x] Package native README assertions for docs drift and compliance reuse.
- [x] Preserve rendering, writing, source-less scopes and warning semantics.
- [x] Positive native counts and missing/stale/comment/setup negatives.
- [x] Focused Pester 5/6 and full local gate.
- [x] Commit locally; publication remains explicitly unauthorized.

## Requirement map

The registry README regeneration requirement now maps to
`Resources/bicep/conventions/Readme.Tests.ps1`. Each successfully rendered README
has its own existence and byte-comparison assertions. Verified omitted generated
grouping comments have a separate warning requirement. The existing provenance
parser remains preparation code; it does not report validation findings.

Renderer/compiler and provenance failures remain explicit errors. Writing docs
does not start Pester; drift checks batch the selected scopes in one native run.
An empty tracked README is stale, not missing. Preparation diagnostics now
precede the batched assertion diagnostics; codes and target files are retained.

## Validation

- Pester 6.2.0 full `.\build.ps1 pre-commit`: layout, lint and units passed;
  1,554 component cases passed with one existing skip.
- Pester 5.7.1 focused unit/component checks and
  `Integration: Bicep docs scoped examples*` passed. All five real compiler-only
  integration cases passed, including Graph/Key Vault existing references.
- Root/child positives prove four executed native requirements. Missing files,
  empty files, stale content, selective grouping-comment omissions and source
  failures retain useful diagnostics. Three mocked runner regressions reject
  unregistered, missing or unmapped-failure checks.
- Initial test failures identified message/order expectations and a source LF
  violation. These are fixed. One full-gate attempt hit an analyzer-engine
  command-resolution failure after repeated NullReferenceException retries;
  the fresh-process full gate passed without weakening lint.

## Remaining work

Default unit compliance still needs to consume the prepared native checks.
No capability marker, release or registry cutover is claimed. Publication
remains blocked by the explicit authentication hold.
