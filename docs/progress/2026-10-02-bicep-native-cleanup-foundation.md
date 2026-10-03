# Bicep native cleanup foundation

**Status**: complete
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Package the registry's native Azure PowerShell cleanup handlers and
Create-operation discovery inside Avm.Authoring. This is the first
implementation slice of the
[workflow parity work](2026-10-02-bicep-workflow-parity.md), not a replacement
of the current runner or permission to switch registry CI.

The user selected adapting the existing Azure PowerShell handlers rather
than rewriting all resource handlers to Azure CLI or REST. The reference is
`Azure/bicep-registry-modules` commit
`89b1910d5d11e4f87579ae98e119effe9b7c9578`. The functions ship in
`Private/Tests/Cleanup`; no runtime registry checkout is required.

## Checklist

- [x] Adapt native resource deletion, post-removal processing, dependency
      ordering, locks, and timeout/cancellation classification.
- [x] Discover Create targets at exact nested deployment IDs, including
      all four deployment scopes, pagination, partial results and confirmed
      preflight rejection.
- [x] Preserve protected-vault and dependency-resource exceptions.
- [x] Fail explicitly for unsuccessful CLI commands, exhausted deletion
      waits, and failed post-removal operations.
- [x] Avoid deleting foreign inherited locks or similarly named soft-deleted
      resources and managed groups.
- [x] Finish focused offline controls on the merged main baseline.
- [x] Run the ordinary full development gate.
- [x] Commit and push the foundation.

## Validation

The expanded focused run passed all 72 selected unit controls with no
failures or skips on the merged main baseline.

The ordinary `./build.ps1 pre-commit` gate passed: layout and lint had no
findings; 2,606 unit tests passed with nine existing skips; 1,261 component
tests passed with one existing skip. The gate emitted 82 warnings from
exercised warning/error paths, with no failed tests or build errors. Lint
used its existing transient analyzer retry once; no retry settings or
lint rules were changed.

Azure cmdlets and external processes are replaced with fail-by-default
test commands and explicit mocks. No Azure dependencies were installed and
no Azure API was called by these tests.

## Boundaries and dependencies

The current e2e runner, its public parameters, deployment restrictions,
Terraform behavior, schemas, release version and workflows are unchanged.
Authentication/context isolation, cleanup state storage, batch removal and
runner wiring are subsequent implementation work. Passing the helper
controls is not evidence of live Azure qualification or complete workflow
parity.

The worktree is based on merged main
`b0ba22f2fca81e4e068414e7f20bb703acd37de4`, including the scaffold correction
from [tools #217](https://github.com/Azure/azure-verified-modules-tools/pull/217).
