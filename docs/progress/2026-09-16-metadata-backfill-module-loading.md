# Metadata backfill module loading

**Status**: complete
**Started**: 2026-09-16
**Updated**: 2026-09-16
**Branch**: `jaredfholgate-metadata-backfill-module-loading`

## Outcome

Keep metadata-only repository backfill on the trusted checkout module throughout
preflight and preparation, without requiring a PowerShell Gallery release.
The first targeted [workflow run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/35146145916)
failed on the wrapper's unconditional by-name import before preparation.
Ordinary repository sync retains its released-module and upgrade behavior.

## Checklist

- [x] Trace module visibility through the wrapper and preparation callback.
- [x] Reproduce the real import failure without a discoverable installed module.
- [x] Fix metadata-only loading and cover plan-only, apply, and WhatIf behavior.
- [x] Run the focused tests and `.\build.ps1 pre-commit`.
- [x] Prepare the focused change for publication without changing workflow inputs.

## Validation

The new clean-process component cases failed before the fix in both plan-only
and apply mode with the exact hosted error: no valid `Avm.Authoring` module
could be found by name. Each process imports the real trusted manifest with only
PowerShell built-ins on `PSModulePath`, then runs the real standalone script and
preparation callback with GitHub/publication operations stubbed.

Focused `.\build.ps1 test,component -TestName ...` passed: 11 unit and
84 component cases, including the two previously failing clean-process cases,
standalone WhatIf, real metadata preparation, and ordinary sync import/upgrade
and publication controls. The fix only moves the by-name import into the
ordinary-sync branch; metadata keeps its capability-checked checkout module.

`.\build.ps1 pre-commit` passed: layout, lint, 1,513 unit tests (8 skipped),
and 495 component tests. Hosted checks are tracked on the feature-branch review
after publication so their evidence refers to the exact committed head.

No live backfill was run. After merge and separate operator approval, use a
fresh targeted workflow dispatch from the updated `main`, with metadata backfill
enabled, source updates disabled, and plan-only enabled first. Re-running the
failed run would still use its old commit.

## Blockers or dependencies

None. Based on `main` at `c77f97b11f0cb8aad9b2cdada686f650ccb7685e`;
the earlier implementation is merged and is not being modified.
