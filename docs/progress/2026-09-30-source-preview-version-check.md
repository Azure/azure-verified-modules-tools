# Source preview module version check

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Honor an explicit `-SkipModuleVersionCheck` throughout the authoring
pre-commit, pull-request check, and Terraform unit-test call chains so a
plan-only repository-sync preview can use its checked-out module source.
Normal released-module checks must remain enabled.

## Checklist

- [x] Forward the explicit version-check option through context resolution
      and every nested authoring step used by candidate preparation and
      validation.
- [x] Replace misleading caller-scope defaults with tests that verify the
      option reaches actual module commands.
- [x] Run focused regression tests and the full local pre-commit gate.
- [x] Commit and push the branch fix.

## Validation

The checked-out module's public commands now forward
`-SkipModuleVersionCheck` through their own context lookups, and pre-commit
and pull-request checks forward it to each nested step. A component test
calls the real pre-commit command across the repository-sync/module
boundary and fails if any inner version check is enabled; a unit guard
covers all public context calls. Without the flag, the Gallery check
remains enabled. Focused regression tests passed. `./build.ps1 pre-commit`
passed with 1,951 unit tests, 937 component tests, 9 platform skips, and
no errors.

## Blockers or dependencies

The first branch plan-only canary failed before producing an artifact:
[run 36710370456](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36710370456).
Its pre-commit composition ignored the source-preview version-check opt-out
in a nested public command. No second live run was started for this slice;
a retry needs separate user approval.
