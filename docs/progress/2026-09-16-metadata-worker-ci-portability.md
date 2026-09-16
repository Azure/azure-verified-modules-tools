# Metadata worker CI portability

**Status**: complete
**Started**: 2026-09-16
**Updated**: 2026-09-16
**Branch**: `jaredfholgate-standard-metadata-backfill`

## Outcome

Fix the confirmed hosted failures on
[#126](https://github.com/Azure/azure-verified-modules-tools/pull/126) at
`dda0edabcb5576b06940477464dc81952a71c859` without weakening assertions,
metadata path guards, or ordinary publication controls.

Linux's two negative tests receive correctly rejected metadata, but PowerShell
wraps the worker's diagnostic across lines. macOS additionally rejects its
standard `/var` temporary-directory alias as a linked checkout ancestor.
The separate macOS AzAPI integration failures are GitHub HTTP 500 responses
while downloading `azure/azapi` 2.12.0, not metadata or result-upload failures.

## Checklist

- [x] Preserve complete, unwrapped worker failure diagnostics and nonzero exits.
- [x] Resolve verified macOS system temporary aliases while rejecting linked
      checkouts and module content.
- [x] Exercise long diagnostics and rejected paths locally; add the real macOS
      positive regression for the hosted gate.
- [x] Pass the full local gate and incremental review.

## Validation

Initial evidence:
[exact-head CI run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/35157037020).
No workflow rerun, new permissions, production sync, or provider-policy change
is part of this fix.

`.\build.ps1 pre-commit` passed: 1,515 unit tests (8 existing skips), 530
component tests (1 macOS-only positive alias test skipped on Windows), layout
and lint with zero errors. Targeted checks passed 51 cases with the same
macOS-only skip. The existing exact failure-text assertions are unchanged.
The incremental Opus 5 review reported no findings and exercised actual worker
failures and negative Windows junctions.

## Hosted validation boundary

macOS-specific filesystem behavior requires the fresh hosted macOS checks;
local execution is Windows. External provider download failures remain separate.
