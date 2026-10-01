# Bicep workflow and ownership checks

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Completed**: 2026-09-30
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Cover the pinned registry's local workflow and CODEOWNERS assertions in
`avm check convention`, without modifying or dispatching the registry's
workflows. Validate exact-case top-level module workflow paths, dispatch
defaults, module/workflow environment paths, canonical push triggers and
ordered filters, and the fork-safe initialization condition. Validate
CODEOWNERS precedence, the ownerless module tree, absence of per-module
entries, and unique ownership patterns. Additional ownership rules are
accepted only when anchored outside `/avm/`; unanchored rules could silently
take module ownership. Missing, unreadable, or unparseable files and
dependencies must fail with named diagnostics.

Use the registry's existing PowerShell YAML parser as an optional,
exact-version Bicep-only dependency; install it in this repository's build
prerequisites so component tests exercise real parsing on every CI platform.
Do not make it an import-time or Terraform dependency.

## Pinned assertions in this slice

| Source | Required check |
| --- | --- |
| M:415-452 | Top-level workflow exists, declares `workflowPath` and `modulePath`, and uses their exact canonical values |
| M:469-519 | Four dispatch inputs exist; static/deployment defaults are true and `customLocation` has no default |
| M:534-565 | Only `main` pushes without tag/other triggers; four exact path filters in canonical order and no extras |
| M:585 | Canonical initialization guard only runs automatically for upstream changes and honors cancellation, with no weakening alternatives |
| M:2062 | CODEOWNERS default, ownerless `/avm/`, tooling and metadata overrides, no effective module overrides, unique patterns |

## Checklist

- [x] Implement real YAML parsing, fail-closed preflight, and named workflow
      diagnostics for each top-level Bicep module.
- [x] Validate CODEOWNERS rules once per repository without traversing
      symlinked files or directories.
- [x] Add passing and failing unit/component fixtures for workflow, parser,
      and ownership rules, including a monorepo with multiple modules and
      regression cases from independent review.
- [x] Update direct help, build prerequisites, and the pinned coverage ledger.
- [x] Independently review and address issues, run `./build.ps1 pre-commit`,
      commit and push, then update the existing review.

## Validation

Focused `./build.ps1 pre-commit -TestName ...` passed layout, lint, five unit
tests and 65 convention component fixtures. The unfiltered
`./build.ps1 pre-commit` passed layout, lint, 1,930 unit tests (nine skipped)
and 995 component tests; its 49 warnings are exercised negative paths.
Independent review found six bypasses/failure paths: tag triggers, a weakened
fork guard, reordered path filters, unanchored ownership overrides,
mis-cased parent directories, and unreadable CODEOWNERS. All are covered by
new negative fixtures; a safely anchored non-module ownership rule has a
positive fixture. No registry CI or Azure operation was run.

## Blockers or dependencies

Publication-aware versions/changelogs, child publishing and singularization,
README equivalence and advisory API versions, and the registry-literal
telemetry distinction remain fail-closed separately. No registry CI switch,
release, Azure/MCR call, or action on any other branch is authorized here.
