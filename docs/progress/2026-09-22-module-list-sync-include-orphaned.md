# Include Orphaned modules and restore top-level-only filtering in module-list-sync

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: jaredfholgate-module-list-sync-include-orphaned

## Outcome

Jared approved two combined policy changes to
`Get-AvmModuleListSyncCatalogModulePaths`, the function that builds the
"Module Name" dropdown in `avm_module_issue.yml`:

1. **Status inclusion**: include modules whose `moduleStatus` is `Available`
   **or** `Orphaned`, not `Available` only. `Proposed` and `Deprecated`
   remain excluded. This preserves the ability for users to file module
   issues against published-but-orphaned modules, and lets
   issue-owner-routing's orphan fallback route issues against those same
   orphaned-but-published modules.
2. **Top-level-only filtering**: exclude any catalog entry whose
   `parentModule` field is non-empty (a child module). This was found to be
   a **latent defect in the new module-list-sync workflow**, discovered
   during review: the current live `avm_module_issue.yml` dropdown has 211
   entries, all of them top-level modules, matching the pre-existing
   convention used by bicep-registry-modules' own `Get-ModuleList.ps1`
   (which defines "top level" at a fixed path depth). The initial
   implementation of `Get-AvmModuleListSyncCatalogModulePaths` filtered only
   on `moduleStatus` and a category-prefix regex, with **no depth/child
   filter at all** — an earlier progress-doc note in this same file
   incorrectly asserted this was intentional pre-existing behavior; that
   assumption was disproven during review and has been corrected here. Left
   unfixed, either status policy would have proposed roughly 325 additional
   child-module entries into a deliberately top-level-only, user-facing
   issue form. The fix restores the existing top-level convention using the
   catalog's semantic `parentModule` field (an empty/absent value marks a
   top-level module) rather than path-depth arithmetic.

This slice is intentionally independent of draft PR #176 (pagination-only
fix); it branches from `main` and does not touch that branch.

## Scope

- `repository-management/module-list-sync/scripts/lib/ModuleListSync.ps1`:
  `Get-AvmModuleListSyncCatalogModulePaths` now:
  - filters `moduleStatus` against a script-scoped
    `$script:AvmModuleListSyncIncludedStatuses = @('Available', 'Orphaned')`
    constant using a case-sensitive `-cnotin` membership check, instead of a
    single `-cne 'Available'` comparison; and
  - additionally skips any entry whose `parentModule` is non-empty, via
    `if (-not [string]::IsNullOrWhiteSpace([string]$entry.parentModule)) { continue }`.
- `tests/Pester/Unit/RepositoryManagement/ModuleListSync.Tests.ps1`: added a
  synthetic-catalog regression test pinning the full independent matrix
  (top-level Available/Orphaned/Proposed/Deprecated, plus child
  Available/Orphaned), asserting only top-level Available and Orphaned
  entries survive. No live-catalog counts or real module paths are used
  anywhere in the test fixtures.
- No other module-list-sync behavior (sorting, PR body generation, workflow
  triggers) changed.

## Checklist

- [x] Read `AGENTS.md`, `docs/progress.md`, active/blocked progress slices,
      `docs/avm-implementation-spec.md`, `docs/avm-consolidation-plan.md`,
      `docs/quality-standards.md`.
- [x] Update `Get-AvmModuleListSyncCatalogModulePaths` filter (status +
      top-level-only).
- [x] Add synthetic-fixture regression coverage for the full status × depth
      matrix.
- [x] Run targeted Pester tests for `ModuleListSync.Tests.ps1`.
- [x] Run full `./build.ps1 pre-commit`.
- [x] Commit, push branch, open draft PR against `main`.

## Validation

- Targeted: `./build.ps1 test -TestName '*ModuleListSync*'` — Tests Passed: 11, Failed: 0, Skipped: 0, Inconclusive: 0.
- Full: `./build.ps1 pre-commit` — layout OK; lint completed (0 errors; PSScriptAnalyzer's known transient `NullReferenceException` self-retried per docs/quality-standards.md); unit tests Tests Passed: 1727, Failed: 0, Skipped: 9; component suites all passed (158/14/257/137/198/143 with 1 skip, all Failed: 0). Build succeeded with warnings, 5 tasks, 0 errors, 55 warnings.

## Blockers / dependencies

None. Independent from PR #176 (draft, pagination-only fix) — not touched by
this slice.
