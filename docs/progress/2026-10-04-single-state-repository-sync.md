# Single-state repository sync

**Status**: in-progress
**Started**: 2026-10-04
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-single-state-repository-sync`

## Outcome

Implemented one ordinary Terraform root, state, and plan/apply per repository for
GitHub configuration and BAMI test identity, federation, and membership edges.
Removed the separate identity provisioning apply without restoring retired
tenant resources or broadening permissions. Also removed the redundant GitHub
template block while ignoring its historic state, and folded full workflow
diagnostics while keeping useful context, outcomes, and failures visible.

This slice is source/offline preparation only, based on
`a55f79c63e45fd0f141ffb2cd43eea5cad3522f0`. The existing production sync must remain
untouched. No backend, cloud, directory, or live-state access is authorized.
State consolidation and resumption require separate operator approval after
all writers have stopped. The user's correction is: "Use a coordinated cutover
without adding a setting." The configuration gate is removed; keep the writer
freeze through ownership transfer, verification, and the coordinated code
change before resumption.

## Checklist

- [x] Read repository guidance and confirm the clean current-main baseline.
- [x] Trace settings and file-generation dependencies before Terraform.
- [x] Wire the unified root and preserve authentication and permission guards.
- [x] Remove the split provisioning stage.
- [x] Prove the proposed state transfer with native local-only synthetic states.
- [x] Cover fresh, split, legacy, partial, and rejected ownership cases.
- [x] Remove and ignore the nested repository template without recreation.
- [x] Correct matrix context and fold native Terraform, discovery, file, and project logs.
- [x] Update the existing directly related documentation.
- [x] Run focused controls and the ordinary development gate.
- [x] Prepare the draft description and concrete operator approval procedure.
- [x] Remove the cutover setting from the workflow, PowerShell, and Terraform.
- [x] Update regressions and documentation for the no-setting decision.
- [x] Avoid secondary project-permission errors when token setup never ran.
- [x] Rerun affected validation and the full development gate.
- [x] Prepare the follow-up commit and corrected same-draft procedure.
- [x] Reproduce and remove the hosted integration test's global Terraform dependency.
- [x] Validate and prepare the coupled test correction.
- [ ] Verify actual hosted results at the corrected head.

## Validation

- `.\build.ps1 test-tenant-terraform`: 19 ordinary-root cases and 15 Azure-child
  cases passed. Includes a real mocked-provider single apply publishing its
  own identity client ID, native template-state preservation, and seven
  unchanged old-tenant forget actions with no refresh/read/destroy.
- `.\build.ps1 integration -TestName 'Integration: local repository state consolidation*'`:
  four native local-only cases passed with Terraform 1.16.4. Whole-module moves
  preserve IDs, provider bindings, private data, sensitive paths, root outputs,
  and separate lineages. Tests cover legacy dependencies, destination
  collision refusal, source-first cutover, and stale/foreign push rejection.
  The final inspector was rerun against these native transfers.
- Focused unit and component controls cover the actual matrix action, driver
  ordering, trusted-source and WhatIf boundaries, saved-plan rejection, secret-safe
  output, project failures, and read-only staged-state inspection.
- The 2026-10-05 no-setting correction passed 77 focused unit cases, 38 driver
  component cases, the native Terraform contracts, and all four local transfer
  cases. Normal dispatch, schedule, and plan-only paths run without the removed
  setting; stale environment values are ignored and the old parameter is rejected.
- The expanded logging regression passed 53 component cases, including the
  actual extracted installer script's terminal HTTP 403, workflow token
  prerequisite conditions, and the explicit skip notice without a project API call.
- Final `.\build.ps1 pre-commit` passed layout, lint, 2,897 unit tests and
  1,292 component tests (nine unit and one component platform-dependent skips),
  including the no-setting and installer/missing-token follow-up controls.

The supplied private log shows that an Avm.Authoring installer HTTP 403 exhausted
three existing attempts before token setup or repository Terraform ran. Project
sync then used an empty token and reported a misleading permissions error.
Keep the installer failure intact and explicitly skip project work without its
token prerequisite. The cutover inventory must include repositories that failed
before sync, not assume the latest run reached every repository.

The local gate does not cover the hosted integration tier. At
`96f4e9aadf892561e01e60cabf0447ffaa82b013`, all six integration matrix jobs in
[Authoring CI](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37280529521)
failed only the four state-transfer cases during container setup. The new test used
`Get-Command terraform` even though integration jobs resolve native tools from
the AVM cache rather than a global PATH entry. Logs from both fixtures on Linux,
Windows, and macOS confirm the same cause. Unit/component, lint, workflow, and
Config checks passed. This is a source regression, not an external installer or
provider failure; hosted verification of its correction is still pending.
Removing global Terraform directories from only the reproduction process's PATH
reproduced the same four-case setup failure locally. The suite now resolves the
lock-pinned executable through `Resolve-AvmTool`, matching the other integration
tests without changing CI setup, pins, runtime behavior, or test selection.
The identical missing-PATH reproduction then passed all four cases with zero
skips using cached Terraform 1.15.8; the native binary's version was verified.
This adds the managed version to the earlier Terraform 1.16.4 proof.
The repeated full `.\build.ps1 pre-commit` passed layout, lint, 2,897 unit
and 1,292 component tests after this correction, with the same nine unit
and one component skips. No installer, workflow, pin, or runtime changes
were needed.

## Blockers or dependencies

No live state inventory or approved writer freeze was performed. The existing
production run was left untouched; its status is the coordinator's concern.
Do not claim a finalized live migration inventory or execution readiness.
The proposed cutover uses native state moves on working copies, followed by
separately approved source-first publication under a complete writer freeze.
The coordinator has the proposal; no backend-writing migration tool was added.
The local inspector is read-only and requires original hashes and a frozen
identity record. Native moves retain outputs in the source and clear affected
dependency caches; native local push also advances serial again. Actual backend
persistence/provenance, incomplete or missing states, maintenance authentication,
and all publication/resumption decisions remain operator work. The no-setting
decision makes the coordinated freeze and code-change timing essential: source
CI does not prove cross-state ownership or authorize a merge or live run.
