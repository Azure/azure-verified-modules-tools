# Canonical catalog CSV publishing

**Status**: complete
**Started**: 2026-09-21
**Updated**: 2026-09-21
**Branch**: `jaredfholgate-catalog-csv-publishing`

## Outcome

Publish the six canonical CSV indexes instead of `test-` outputs through the
existing catalog workflow. Schedule collection every four hours without matching
other scheduled start times. No production dispatch, publication, or merge is
authorized by this slice.

## Checklist

- [x] Verify the tools worktree starts at current remote main and has no existing
  catalog change to reuse.
- [x] Inspect all tracked workflow schedules and recent catalog durations.
- [x] Update manifest, schedule, coupled documentation, and regression tests.
- [x] Trace scheduled events through `-Publish`, candidate creation/update,
  squash merge, and merged-head verification; preserve manual plan-only defaults.
- [x] Verify canonical output paths, artifact-only reports, and unchanged safety.
- [x] Run focused catalog tests and the full pre-commit gate.

## Validation

- `.\build.ps1 component -TestName 'Component: module catalog*'` initially
  passed 218 tests and exposed one collection fixture assuming distinct input
  and output names. Updated it to cover both canonical and custom preview paths.
- `.\build.ps1 component -TestName 'Component: module catalog publication inputs*','Component: module catalog workflow safety*'`:
  10 passed.
- `.\build.ps1 pre-commit`: passed layout, lint, 1,620 unit tests (9 skipped),
  and 850 component tests (1 skipped), including all final catalog tests.
  The existing analyzer retry handled transient null-reference failures.
  The gate reported 54 warnings, including lint findings in unchanged source.
- `git diff --check`: passed.
- Local-Git publication tests verify all six canonical file contents, candidate
  creation/update, squash merge and head verification, no published migration
  report, and retained failure cases. GitHub calls are mocked; no production
  publication, dispatch, or merge was performed.

Scheduled events enter the publish job independently of the manual `plan_only`
default (`module-metadata-sync.yml:131-137`). The write step passes `-Publish`
and `-Confirm:$false` (`:189-198`). The existing publisher's default-only
validation return is at `Publish-ModuleCatalog.ps1:23-26`; the apply path
overwrites allowed files (`:133`), creates/updates the candidate (`:166-179`),
then squash-merges and checks the merged head (`:181-191`). No apply-path code
change was needed.

Schedule: `33 1-23/4 * * *` gives 01:33, 05:33, 09:33, 13:33, 17:33, and
21:33 UTC daily. Terraform sync starts at 00:33 + four hours on weekdays;
Bicep sync starts at 02:33 + four hours daily. Dependabot checks are Monday
06:00 UTC. None shares a catalog start. The supplied public destination
schedules also have no matching start.

Recent completed catalog runs took approximately 5-9 minutes. Collection can
take up to 360 minutes, publication 45 minutes, and reporting 10 minutes;
workflow delays or long runs can still overlap other workflows. The existing
`module-metadata-sync` concurrency group with `cancel-in-progress: false` remains.

## Blockers and dependencies

No implementation blockers. No ADO pipeline YAML is tracked in this repository.
The externally hosted `release-avm-authoring.yml` schedule could not be inspected:
Azure CLI lacks a signed-in session and ADO MCP fails API location discovery.
The schedule comparison covers verified GitHub schedules, not unverified external
pipeline settings. No login or production run was attempted.

A fresh snapshot is required after the manifest changes; old artifact
bundles remain invalid. Existing preview files are not deleted. Recommend updating
the internal team catalog operations runbook for canonical publication and cadence,
without modifying the internal documentation repository in this slice.
Separate preview-file cleanup:
[Azure/Azure-Verified-Modules#2952](https://github.com/Azure/Azure-Verified-Modules/pull/2952),
to follow this tools cutover.
