# Include Orphaned modules in module-list-sync dropdown

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: jaredfholgate-module-list-sync-include-orphaned

## Outcome

Jared approved policy: the generated `avm_module_issue.yml` "Module Name"
dropdown must include modules whose `moduleStatus` is `Available` **or**
`Orphaned`, not `Available` only. `Proposed` and `Deprecated` remain excluded.

This preserves the ability for users to file module issues against
published-but-orphaned modules, and lets issue-owner-routing's orphan
fallback route issues against those same orphaned-but-published modules.

This slice is intentionally independent of draft PR #176 (pagination-only
fix); it branches from `main` and does not touch that branch.

## Scope

- `repository-management/module-list-sync/scripts/lib/ModuleListSync.ps1`:
  `Get-AvmModuleListSyncCatalogModulePaths` now filters against a
  script-scoped `$script:AvmModuleListSyncIncludedStatuses = @('Available', 'Orphaned')`
  constant using a case-sensitive `-cnotin` membership check, instead of a
  single `-cne 'Available'` comparison.
- `tests/Pester/Unit/RepositoryManagement/ModuleListSync.Tests.ps1`: added
  regression coverage for an `Orphaned` catalog entry being retained while
  `Proposed`/`Deprecated` entries stay excluded.
- No other module-list-sync behavior (sorting, PR body generation, workflow
  triggers) changed.

## Observed pre-existing convention (unchanged by this slice)

`Get-AvmModuleListSyncCatalogModulePaths` filters purely on `moduleStatus`
plus an `avm/(res|ptn|utl)/...` category-prefix regex match on `modulePath`;
it has no top-level-vs-child-module distinction, and
`Get-AvmReviewerRoutingCatalogIndex` (which supplies the flattened catalog
index) likewise does not filter by module depth — it just maps every
`bicep` entry under `catalog.modules` for the target repository into
`modulePath -> entry`. So the dropdown already admits any catalog entry
matching the category prefix and included status, whether that entry
represents a top-level or a child module; this slice's status-inclusion
change (`Available` + `Orphaned`) does not alter that existing behavior in
either direction and this remains a separate, unaddressed question left for
a future explicit decision if a top-level-only filter is ever wanted.

## Checklist

- [x] Read `AGENTS.md`, `docs/progress.md`, active/blocked progress slices,
      `docs/avm-implementation-spec.md`, `docs/avm-consolidation-plan.md`,
      `docs/quality-standards.md`.
- [x] Update `Get-AvmModuleListSyncCatalogModulePaths` filter.
- [x] Add regression test coverage for `Orphaned` inclusion.
- [x] Run targeted Pester tests for `ModuleListSync.Tests.ps1`.
- [x] Run full `./build.ps1 pre-commit`.
- [x] Commit, push branch, open draft PR against `main`.

## Validation

- Targeted: `./build.ps1 test -TestName '*ModuleListSync*'` — Tests Passed: 10, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 1725.
- Full: `./build.ps1 pre-commit` — layout OK; lint completed (0 errors, PSScriptAnalyzer's known transient `NullReferenceException` self-retried per docs/quality-standards.md); unit tests Tests Passed: 1726, Failed: 0, Skipped: 9; component suites all passed (158/278/88/169/111 with 1 skip/103, all Failed: 0). Build succeeded with warnings, 5 tasks, 0 errors, 55 warnings.

## Blockers / dependencies

None. Independent from PR #176 (draft, pagination-only fix) — not touched by
this slice.
