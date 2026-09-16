# Metadata review groups

**Status**: complete
**Started**: 2026-09-16
**Updated**: 2026-09-16
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Allow code-owner approval for metadata files from either the engineering owners
or module owners team. Both teams must appear on the same final basename rule;
approval from both is not required.

Both templates and the current-output validator require the exact final rule:

```text
metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners
```

The user approved adding module owners to the default Terraform teams with
`repositoryPermission: "push"` and `environmentApproval: false`. This keeps
ordinary repository sync from removing the access needed for code-owner review.
The existing engineering-only protection for the CODEOWNERS file, other teams,
environment approvals, and general review requirements remain unchanged.
Metadata's own owner list does not grant access or code-owner eligibility.

The earlier ownership branch is included in the consolidated implementation
commit `01bbe825dd59705d91135c8d5629dbc1560a3a9e`.
[#120](https://github.com/Azure/azure-verified-modules-tools/pull/120) is closed
as superseded, not merged; its branch is retained.
[#113](https://github.com/Azure/azure-verified-modules-tools/pull/113) remains
the sole tools review.

## Checklist

- [x] Update both templates, current-output validation, and policy regressions.
- [x] Coordinate the actual Bicep rule and public process documentation.
- [x] Keep path coverage, final precedence, and normal review enforcement.
- [x] Add the approved default-team access without environment-approval changes.
- [x] Pass focused repository-management tests and the full local gate.
- [x] Complete the Opus follow-up for the policy and configured-access changes.

## Validation

- `.\build.ps1 test-repository-management`: 439 passed, no failures or skips.
- `.\build.ps1 pre-commit` with `AVM_OFFLINE=1`: 1,513 unit tests passed,
  eight existing skips, and 473 component tests passed. Persisted NUnit reports
  record zero errors, failures, invalid cases, or unexecuted tests.
- Existing analyzer retries and warnings, plus expected mocked operational
  warnings, remain; no lint, test, or workflow controls were weakened.
- Regressions cover root, child, deep, and unindexed paths, final-rule precedence,
  and rejection of missing teams, extra owners, root-only patterns, duplicates,
  and misplaced rules. The existing team-precedence test now expects four teams
  and explicitly checks module-owners write access without environment approval.
- The narrow Claude Opus 5 follow-up found no issues. It exercised both real
  generators and the Bicep guard offline, including legacy/current phase
  boundaries, and confirmed that only the approved team access is added.
  CODEOWNERS-file protection, environment reviewers, BAMI controls, bypasses,
  and general approval counts remain unchanged.

## Coordinated changes

[Azure/bicep-registry-modules#7349](https://github.com/Azure/bicep-registry-modules/pull/7349)
has the same two-team rule at
`2fe528df6fe20f849fb79055589677098357680c`. Its owner reports 355
ownership/release regressions and all six exact-head hosted checks passing.
The metadata files, module sources, and release controls are unchanged.

[Azure/Azure-Verified-Modules#2936](https://github.com/Azure/Azure-Verified-Modules/pull/2936)
is a draft at `5ff656df746a0a3e1c213438cc56621959f55cec`, with all seven
exact-head hosted checks passing according to its owner. It documents either-team
approval, both teams' visible/write-access prerequisites, and unchanged
environment approvals. Final tools policy-head verification remains an explicit
draft adoption gate.

## Dependencies

Record publication and exact published-head hosted checks in the existing tools
review; operator approval is still required before rollout.
Keep Bicep Sync paused across the tools/Bicep governance changeover. Canonical
CSV cutover, proposals without a repository/source, and internal runbook alignment
remain separate adoption gates.

This changes repository files and the approved future team configuration only.
No live team membership, permissions, required approval count, workflow state,
or main-branch merge is changed.
