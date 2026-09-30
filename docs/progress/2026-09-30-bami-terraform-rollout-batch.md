# BAMI Terraform tenant-only rollout batch

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bami-terraform-rollout-batch`

## Outcome

Prepared and locally validated a source-only tenant selection for the next three
low-risk Terraform repositories. The new `bami-rollout` group has order `5`,
below the existing canary groups and above the legacy default. Its only
behavioral setting is `testTenant: bami`. This completes source preparation,
not activation.

The intended additions are `avm-res-network-applicationsecuritygroup`,
`avm-res-network-ipgroup`, and `avm-res-network-routetable`. Configuration remains
the only operational membership source; no README roster or membership test
snapshot is added.

Only `repository-management/repository-config/config.json`, minimal selection
guidance in `repository-management/README.md`, and this progress record are in
scope. Managed-file rings, access settings, workflows, identity and state
handling, credentials, and Bicep selection remain untouched.

## Checklist

- [x] Read the repository contract and active progress; verify a clean worktree
      and main at `1975550a6693a3c5817d80f8359c1a9370733fcd`.
- [x] Check existing reviews and branches; no suitable open batch review exists.
- [x] Add the tenant-only group without changing existing groups.
- [x] Use the existing resolvers to compare every configured or locally known
      repository ID before and after; only the three intended tenant values
      may change.
- [x] Run existing local configuration and resolver checks and the required
      pre-commit gate.
- [x] Prepare the validated source for commit, push, and a draft-only handoff
      with the merge dependencies below. Freeze source at publication.

## Validation

- `.\build.ps1 test -TestName @('Central test tenant group resolution*',
  'Resolve-AvmManagedFilesRepositorySetting file group ordering*',
  'Repository-specific Terraform ownership configuration*')`: 20 passed,
  none failed or skipped. This includes the existing
  `Test-RepositoryConfig.ps1` checks.
- `.\build.ps1 pre-commit`: layout and lint passed; 1,850 unit tests passed
  with nine skips; 831 component tests passed with no skips. Exit code 0,
  no failures, 50 warnings from existing test paths. The existing analyzer
  retry recovered its known transient exception; lint had no findings.
- Both commands used `AVM_OFFLINE=1` and the documented
  `DOTNET_MultiCoreJitMinNumCpus=7fffffff` workaround. No dependency installation,
  live Terraform execution, cloud API calls, or sync/test dispatch occurred.
- One-time comparison used `Resolve-RepositorySettings`,
  `Get-AvmManagedFilesKnownRepoId`, and
  `Resolve-AvmManagedFilesRepositorySetting`, not copied resolution logic.
  Against main `1975550a6693a3c5817d80f8359c1a9370733fcd`, all 22 configured
  IDs were covered within 74 distinct locally referenced IDs, plus a synthetic
  unlisted control: 75 comparisons. Local references include fixtures; this is
  not a live repository or App-installation inventory.
- Exactly the three intended `TestTenant` values changed from `legacy` to
  `bami`; selected count increased from 10 to 13. Every existing group is
  unchanged. The three selected IDs additionally report `bami-rollout` in
  group provenance, with all prior group records and names preserved.
- Managed-file results, teams and permissions, environment approvals, topics,
  CODEOWNERS teams, bypasses, and workflow-ref overrides are unchanged for all
  compared IDs. The unlisted control remains legacy. No tests were changed.
- `git diff --check` passed. All three changed files use UTF-8 without BOM
  and LF. Validated configuration SHA-256:
  `77ECDFEEEEDA9EE0313D83AA9B6971787CC4660F4C9225907E05C9C297FA6319`.

Public source assessment supplied by the coordinating session identifies small
networking examples without compute. It does not establish GitHub App
installation, applied candidate identities, runtime credentials, or BAMI
readiness. No cloud tests are permitted in this slice.

## Blockers or dependencies

This is not activation approval. Repository sync is active and recently failing;
merging selection can allow scheduled applies to provision candidate identities
and rewrite existing execution secrets for this batch.

Keep the draft unmerged until the independent sync repair is verified, the
bounded per-repository plan and candidate scope are reviewed, and cutover is
explicitly approved with only one writer. The coordinating session owns those
gates. Do not touch its state-repair files or queued run.

Rollback is selection-only: remove these additions from `bami-rollout` (or remove
the new group) to restore inherited legacy selection. Any operational rollback
requires its own reviewed plan and approval; reverting source does not itself
restore live identities or secrets.
