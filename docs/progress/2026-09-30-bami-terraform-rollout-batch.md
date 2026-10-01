# BAMI default for managed Terraform repositories

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bami-terraform-rollout-batch`

## Outcome

The user's 2026-09-30 decision to switch all managed Terraform repositories to
BAMI supersedes this branch's earlier three-repository proposal and held-window
gates. Set the wildcard default to `bami` and remove this branch's redundant
`bami-rollout` group. New and otherwise unlisted repositories discovered by the
existing sync inherit BAMI. Existing precedence still supports explicit legacy
exceptions; none are added.

Configuration remains the single operational selection source. Preserve existing
canary memberships, orders, managed-file overlays, teams, topics, CODEOWNERS,
approvals, bypasses, and workflow references. Preserve the seven-resource identity
guard, no-delete/replacement rule, conditioned delegation restrictions, trusted
main boundary, safe plan summary, and all backend/state handling.

This session owns source and local validation only. The parent owns final review,
merge, and one normal reconciliation using the existing coupled candidate-identity
apply and consumer-secret update. No fleet-wide module deployment tests, temporary
shared-environment approval gate, manual-only workflow, or Bicep changes are part
of the decision.

## Checklist

- [x] Recheck the open draft, clean branch, and current main.
- [x] Merge main `e17d4a00dec32db6c23d382f834bbfb3395c097d` without
      rebase, amend, force, or conflicts; preserve the safe summary.
- [x] Change only the default tenant and remove the superseded rollout group.
- [x] Replace operational membership assertions with synthetic behavior cases
      and one actual configuration/default check.
- [x] Compare existing resolver output across managed and known repository IDs.
- [x] Run the existing focused pre-commit, configuration, and publication guards.
- [x] Prepare the validated source for commit, push, and the same draft handback.

## Validation

```powershell
.\build.ps1 pre-commit -TestName @(
    'Central test tenant group resolution*'
    'Resolve-AvmManagedFilesRepositorySetting file group ordering*'
    'Repository-specific Terraform ownership configuration*'
    'Complete BAMI input bundle*'
    'Tools repository federation context*'
    'Terraform test tenant selection*'
    'Candidate plan and output safety*'
    'Terraform effective contract and state wiring*'
    'Isolated candidate identity orchestration*'
    'BAMI candidate plan summary*'
    'Repository sync test tenant selection*'
    'Tools-owned Bicep configuration*'
    'Guarded nonsecret Bicep variable publication*'
    'Bicep test tenant entry point*'
)
```

Passed layout, lint, 150 unit tests and 100 component tests, with no failures or
skips. The nine warnings are existing pending-identity guard cases. The existing
analyzer retry recovered its known transient exception; lint had no findings.
The command used `AVM_OFFLINE=1` and the documented
`DOTNET_MultiCoreJitMinNumCpus=7fffffff` workaround. Configuration validation ran
through the existing `Test-RepositoryConfig.ps1` harness. Publication and identity
tests use mocked boundaries; no live operations or dependencies were needed.

A one-time comparison reused `Resolve-RepositorySettings`,
`Get-AvmManagedFilesKnownRepoId`, `ConvertTo-AvmManagedFilesRepoId`, and
`Resolve-AvmManagedFilesRepositorySetting`. It covered 259 distinct IDs: the
228 repositories in the completed App-discovered
[sync run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36702418700),
all 22 IDs configured across both baselines, 71 locally referenced IDs, and an
unlisted control, after deduplication. This is a completed-run inventory, not a
new live discovery or a permanent roster.

Against main `e17d4a00dec32db6c23d382f834bbfb3395c097d`, only the default
`testTenant` source value changes. Among the 228 managed IDs, 218 change from
legacy to BAMI and ten remain BAMI; all 228 resolve BAMI. Across all 259 inputs,
249 tenant values change. Against the prior draft, 215 managed tenant values
change and its three original additions remain BAMI through the default.
Managed-file, access, approval, topic, CODEOWNERS, bypass and workflow-ref
differences are zero. Group memberships and orders match main exactly; only
the redundant `bami-rollout` provenance disappears relative to the old draft.

`git diff --check` and UTF-8 without BOM/LF checks passed. The configuration
SHA-256 is `9394A5471A75864178CA063F41559C0F3C69EF6FC8B690A4F3E31EE8E5CC8342`.
No workflow, shared resolver/publisher, Bicep selector, identity guard, safe
summary, Terraform root, or backend/state file differs from main.

## Superseded source preparation

The original three-repository source at
`c1a906d5ac93c6e5bd72b73483ca478b923294dd` passed 20 focused tests and the full
pre-commit gate (1,850 unit and 831 component passes). Its 75-input resolver
comparison changed three tenant values, from 10 to 13 selected IDs. That evidence
describes the former proposal, not validation of the global default.

## Operational consequence and handoff

The user authorized global Terraform tenant selection through the existing
coupled apply/cutover, accepting individual repository failures without bypassing
safeguards. The active sync can provision per-repository candidate identities and
replace existing execution secrets once this source reaches main. A successful
source check is not proof of fleet-wide provisioning or runtime deployment.

Keep the review draft for the parent's final source verification. This source
session performs no live reconciliation, approvals, settings changes, state
access, or cloud tests. Individual failures must be reported rather than hidden
through permission changes, identity reuse, state repair, or automatic retries.

Rollback remains a separately reviewed selection change. Restoring a legacy
default does not override existing higher-precedence BAMI groups or itself
restore live credentials; no rollback operation is performed here.
