# Deprecated module exclusion

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: `jaredfholgate-deprecated-module-exclusion`

## Outcome

Exclude metadata-backed modules from generated CSV indexes and `v1/modules.json`
when they are both deprecated and unpublished. Emit an actionable warning naming
each repository and module path, recommending removal of unused source without
deleting anything. Preserve published deprecated modules, other lifecycle states,
the approved MAR mirror, and unrelated row-removal/publication safeguards.

## Checklist

- [x] Read repository contracts and active progress records.
- [x] Confirm the new worktree matches current main and the prior correction is
      merged; check existing branches and open changes.
- [x] Trace source collection, inventory/row construction, status selection,
      schema validation, migration diagnostics, and publication-base checks.
- [x] Implement validated exclusion and identity-scoped removal permission.
- [x] Cover both ecosystems, inherited deprecation, warnings, and safeguards.
- [x] Update the directly related catalog and rollout documentation.
- [x] Run focused component checks and the unfiltered pre-commit gate.
- [x] Prepare the verified slice for commit and publication against main.

## Validation

- Focused lifecycle/status and publication selectors: 65 passed, no failures.
- The new exclusion context: 33 passed, no failures. Explicit discovery counts
  caught an initially misplaced test block; it was moved into a discoverable
  context and all 33 cases executed.
- Coverage includes an empty CSV and sole canonical key in all six indexes,
  published descendants, metadata-only scaffolds, unchanged MAR registration,
  invalid snapshots and evidence, unrelated held-back removals, and local-only
  publication with mocked GitHub calls.
- Unfiltered `.\build.ps1 pre-commit`: passed in 8m53s. Layout and lint
  completed; 1,620 unit tests passed (9 skipped), and 926 component tests passed
  (1 skipped). No errors; existing and expected diagnostic warnings remain.

All validation uses `.\build.ps1`; no production collection, publication,
workflow dispatch, deletion, merge, or release is authorized.

## Blockers and dependencies

None identified. Base commit: `ce63330f317636c4d193d874a7212593cd7d8747`.
The corresponding internal Azure-Verified-Modules-Docs catalog how-to should
describe the automatic exclusion and deletion recommendation; that separate
repository is outside this implementation slice.
