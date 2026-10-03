# BAMI default main reconciliation

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Integrate the separately approved BAMI default for all Terraform repositories
from `main` without changing its operational controls, while retaining the
telemetry branch's candidate-validation and plan-only guidance.

## Checklist

- [x] Resolve the repository-sync README conflict without reviving the prior
      three-repository cutover or dropping candidate-validation instructions.
- [x] Preserve main's configuration, guard, and test changes unmodified.
- [x] Pass the local pre-commit gate, commit, and push the merge.

## Validation

Seven focused repository-setting tests passed with the BAMI default. The
offline `./build.ps1 test-tenant-terraform` gate passed 11 mocked
repository-sync and four BAMI identity plans. `./build.ps1 pre-commit`
passed with 1,985 unit tests, nine platform skips, 965 component tests,
and no failures. No live sync, Azure plan, or deployment was run.

## Blockers or dependencies

[Azure/azure-verified-modules-tools#199](https://github.com/Azure/azure-verified-modules-tools/pull/199)
merged after the branch had incorporated an earlier `main` revision. Its
README change conflicts, but Terraform configuration and tests merge
automatically. Do not start a repository sync, grant a permission, or change
the user's BAMI cutover decision as part of this documentation reconciliation.
