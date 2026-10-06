# Terraform fork checks and generic step exclusions

**Status**: complete
**Started**: 2026-10-06
**Updated**: 2026-10-07
**Completed**: 2026-10-07
**Branch**: `jaredfholgate-terraform-fork-checks`

## Outcome

Add array-valued `-ExcludeSteps` to `avm pr-check` for either ecosystem.
Validate step names, report intentional exclusions, and resolve only the
prerequisites used by remaining steps. Preserve the default command and its
failure, metadata, and clean-worktree guards.

Fork Terraform checks exclude only `check policy` and run unit tests without
Azure credentials, inherited secret/variable payloads, environment approval,
or a subscription-selection dependency. Normal branch checks retain their
existing credentials, environments, commands, and deployment-test behavior.

Baseline: `d1411724`, after the authoring refactor and runtime fixes merged.
The user requested closing the superseded synthetic-token proposal
[#99](https://github.com/Azure/azure-verified-modules-tools/pull/99) and creating
a new review. That proposal is closed; its branch and source are unchanged.

## Checklist

- [x] Read current contracts and inspect the merged refactor and previous proposal.
- [x] Implement generic exclusions and selected prerequisite resolution.
- [x] Preserve array arguments through the CLI dispatcher.
- [x] Add secret-free fork workflow paths while preserving normal branches.
- [x] Cover exclusions, array binding, default behavior, and workflow boundaries.
- [x] Update command help and directly related migration documentation.
- [x] Run focused checks and the prescribed local gate.
- [x] Close the superseded proposal at the user's request.

## Validation

Focused fork-workflow checks passed (14 tests), including execution of the
workflow's compatibility guard against old and current command surfaces.
The Terraform composition component suite passed (15 tests). Its fork case
clears Azure credential variables, runs the real command chain through local
subprocess stubs, and confirms unit tests execute without any Terraform plan,
show, apply, or destroy call.

The full `.\build.ps1 pre-commit` gate passed on 2026-10-07: layout, lint,
unit tests, and component tests. Lint finished without findings; the component
tier reported 1,448 passed and one skipped. No live Azure plans, deployments,
or registrations have been run.

## Blockers or dependencies

The fork workflow needs an Avm.Authoring release containing `-ExcludeSteps`.
An older selected release must fail clearly rather than fall back to policy
checks or silently omit the other checks. No release or production rollout is
authorized by this slice. The fork behavior should also be documented in
Azure-Verified-Modules-Docs when the compatible release is adopted.
