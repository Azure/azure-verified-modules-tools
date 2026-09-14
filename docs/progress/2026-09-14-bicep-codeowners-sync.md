# Bicep CODEOWNERS synchronization

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-codeowners-sync`

## Outcome

Add scheduled and manual AVM App automation that generates top-level module ownership
from the official Bicep resource, pattern, and utility indexes and synchronizes
only `Azure/bicep-registry-modules/.github/CODEOWNERS`. Retain tooling ownership
and the final governance-test and e2e-ignore overrides. Use one stable app-owned
branch and pull request, with narrowly validated unattended bypass merging.
Manual plans open or update the candidate without merging; the separate local
export performs no remote mutations. Static ownership and the automation header
come from a reviewed template.

The requested reuse refactor replaces the separate CODEOWNERS orchestration
with the existing repository-sync clone/diff/branch/commit/pull-request/merge
path. Both Terraform preparation and CODEOWNERS rendering must call the same
shared core, preserving the existing Terraform defaults.

The shared core is mechanically separated into `RepositoryFileSync.ps1`,
with the Terraform adapter left in `AvmPreCommit.ps1`. The compatibility pass
also restores the exact return shape, fresh-process module import, five clone
retries, and warning-only cleanup. Bicep-specific strict checks become an
explicit opt-in, and the workflow is renamed to `repository-management-bicep-sync.yml`.
The existing Terraform workflow keeps its filename and runtime configuration;
only its display name becomes `Repository Management - Terraform Sync`.

[Operator documentation](../bicep-codeowners-sync.md) describes setup, modes,
the daily four-hour schedule offset by two hours from repository sync, and the
fail-closed safeguards.

## Checklist

- [x] Inspect repository instructions, existing automation, and current ownership.
- [x] Coordinate the generated rule contract with the Bicep compatibility work.
- [x] Implement deterministic top-level ownership and fail-closed CSV handling.
- [x] Implement app authentication, exact-change guards, and stable synchronization.
- [x] Add the scheduled/manual workflow and operator setup documentation.
- [x] Cover generation, idempotence, failures, and merge guards with offline tests.
- [x] Export the initial template-backed snapshot for the Bicep prerequisite.
- [x] Run the focused repository-management tests and local pre-commit gate.
- [x] Prepare the implementation and validated handoff for feature-branch publication.
- [x] Remove the duplicate CODEOWNERS engine and route both callers through repository sync.
- [x] Prove the shared call path and existing defaults with offline regression tests.
- [x] Revalidate and prepare the reuse refactor for publication on the existing review.
- [x] Complete the separate-library extraction and focused original-contract regression cases.
- [x] Validate and prepare the compatibility corrections and workflow names for publication.
- [x] Fix clean-CI component module discovery and Actions-output assumptions, then validate the actual CI task.

## Validation

After extraction and compatibility corrections,
`.\build.ps1 -Tasks test-repository-management,pre-commit` passed all 204 focused
tests, 1,212 unit tests (8 skipped), and 59 component tests. Focused cases prove
the exact legacy return keys, preparation/upgrade fallback, unchanged no-change
and plan behavior, original publication metadata/flags, five transient clone
retries, and cleanup warnings preserving successful outcomes and primary errors.
A genuinely fresh `pwsh -NoProfile` process starts without `Avm.Authoring`,
loads the shared library without the Terraform adapter, then verifies that the
adapter imports the module before invoking real local Git through the shared
transport. Remote APIs are mocked. The existing module lint reported 176
warnings; there were no build errors.

The three original preparation/result/upgrade helper bodies and all four
Terraform parameter signatures match the pre-task `473d6a6` source exactly.
All five generic validation helpers were extracted without body changes. The
shared command transport, exact-head merge, and disposable-clone configuration
remain documented intentional changes; no live Terraform sync was authorized.

Remote CI at `24d8958` exposed two test-fixture defects on all three operating
systems: module-name imports depended on a locally installed module, and the
cold-process output assertion rejected legitimate Actions debug annotations.
The fixture now isolates `PSModulePath` to the source checkout and built-in
modules, restores it afterward, and runs the real cold-start/local-Git probe in
both local and Actions modes. Production synchronization code is unchanged.
The child resets its module path after PowerShell startup, which otherwise
prepends user/global module locations, and verifies both the sole discoverable
manifest and the loaded module belong to the checkout. Output checks require
exit code zero and one exact terminal success marker while allowing debug
annotations before it.

The correction passed `.\build.ps1 -Tasks component,ci,pre-commit`, followed by
standalone `.\build.ps1 ci` in the exact workflow order: 1,212 unit tests passed
(8 skipped), 61 component tests passed, and coverage was 88.05% against the
70% floor. The required pre-commit gate also passed. No production code,
workflow configuration, template, or generated ownership changed in this fix.

Automatic CI for `99a303c` confirmed the discovery and cold-process cases now
pass on all three operating systems. It exposed two remaining cleanup-fixture
failures: CI's Pester rejects unmatched filtered mock calls instead of invoking
the real command implicitly. Fixture cleanup now invokes a real `Remove-Item`
cmdlet captured before mocking; the production cleanup/error assertions remain
unchanged.
The follow-up passed with CI's exact Pester 6.2.0 version: `component`, then
`ci,pre-commit`, with 1,212 unit tests passed (8 skipped), 61 component tests
passed, and 86.34% coverage against the 70% floor. Pester 6.2.0 was restored
only into the session's test-dependency directory after the exact-version
validation reported it missing; installed user modules were not changed.

The separate CODEOWNERS `GitHubSync.ps1`, API/engine tests, and JSON-body
component suite were removed. `Invoke-RepositorySync.ps1` still calls
`Invoke-AvmPreCommitForRepository`; its preparation adapter and
`Invoke-AvmBicepCodeownersSync` both call `Invoke-RepositoryFileSync` in
`repository-sync/scripts/lib/RepositoryFileSync.ps1`. Both share the existing retry
transport and repository tree/file helpers.

Development used only local mocked tests and live read-only inspection; no
target synchronization, target writes, workflow dispatches, ruleset edits, or
other production configuration changes were performed by this slice.

The local export from official index commit
`6142d822b65db7013818d717519a562e67ce664f` has 267 top-level rows, no child rows,
237 rows with individuals plus the shared team, and 30 team-only rows. Its Git
blob is `e08f89ef2d4fb3b059bafc6ac32eb60c6003f5f3`; the parent session owns adding
it to the Bicep change. No target writes were made by this slice.

## Blockers and dependencies

- [Azure/bicep-registry-modules#7343](https://github.com/Azure/bicep-registry-modules/pull/7343)
  must land before automatic merging; the script enforces this prerequisite.
- Operators must install the existing AVM App on the target repository and
  explicitly approve its bypass in every applicable ruleset. The automation
  must fail rather than change rulesets, self-approve, or use another identity.
- The initial source snapshot includes owners that GitHub reports as unknown or
  lacking write access. Operators must resolve the diagnostics or correct the
  CSVs; both plan and merge modes surface these errors without dropping owners.
