# Bicep CODEOWNERS synchronization

The [Repository Management - Bicep Sync workflow](../.github/workflows/repository-management-bicep-sync.yml)
renders the [source template](../repository-management/bicep-codeowners-sync/CODEOWNERS.template)
from the official Bicep resource, pattern, and utility CSV indexes. Its CODEOWNERS
job targets only `Azure/bicep-registry-modules/.github/CODEOWNERS`.
Bicep metadata files are added directly through a repository change, not this
workflow.
The separate BAMI test-tenant job publishes nonsecret execution variables only
when both the manual input and `AVM_BAMI_TEST_TENANT_SYNC_ENABLED` allow it.

## Ownership and template

Each indexed top-level `avm/{res,ptn,utl}/{provider}/{module}` gets one rooted,
trailing-slash rule. Its primary and secondary GitHub handles are trimmed,
lowercased, validated, and deduplicated in that order, followed by
`@Azure/azure-verified-modules-module-owners`. Ownerless and orphaned modules use
only that group; orphaned modules ignore stale individual handles. Available,
proposed, and deprecated modules are included. Child modules have no separate
rows: their parent's directory rule applies recursively, regardless of child
index metadata. Retired `ModuleOwnersGHTeam` values are never used.

The template preserves the tooling catch-all, shared `/avm/` default, automation
header, and governance-test and `.e2eignore` overrides. Its final rule is
`metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners`. This unrooted
basename covers root and child metadata files, overriding module and tooling
owners for those files only. Approval from either listed team satisfies the
code-owner requirement; approval from both teams is not required.

Only the literal `__AVM_MODULE_OWNERS__` placeholder is replaced. Unknown target static rules or
comments cause failure rather than being lost. Base and old-candidate validation
permit the previous content without metadata protection, the original static
file without automation-header comments, and the old module-contributors
default. Generated content, new candidates, and merged output must use the
current template with the exact final metadata rule.

All three CSVs are read from `docs/static/module-indexes/Bicep*Modules.csv` at
one resolved commit in `Azure/Azure-Verified-Modules`. These are the files behind
the official `https://aka.ms/avm/index/bicep/{res,ptn,utl}/csv` links. Downloads
must have valid UTF-8, matching byte counts and Git blob hashes, required columns,
well-formed CSV, and at least one top-level module per index. CSV content is
never executed.

## Local export

PowerShell 7.4+ and GitHub CLI are required. This command reads only the public
index repository and writes the specified local file; it never writes a remote
branch, opens a pull request, or merges:

```powershell
.\repository-management\bicep-codeowners-sync\scripts\Export-BicepCodeowners.ps1 `
    -OutputPath (Join-Path $PWD 'out' 'CODEOWNERS')
```

The output directory must exist. Pass `-SourceSha <40-character-commit>` to
reproduce an earlier snapshot. The result includes the source commit, CSV blob
hashes, generated blob hash, module count, and template SHA-256.

## Workflow modes and schedule

Manual dispatch is available only from tools `main`. **`plan_only: true` is the
default and is a strict dry run.** It prepares changes in a disposable checkout
but never commits, pushes, opens, updates, or merges a remote candidate.
GitHub's diagnostics for the newly generated CODEOWNERS are checked only during
an apply run, when a candidate exists. Invalid owners leave that candidate open
without merging it.

After explicit approval for this production operation, a dry run is
dispatched with:

```powershell
gh workflow run repository-management-bicep-sync.yml `
    --repo Azure/azure-verified-modules-tools --ref main -f plan_only=true
```

Scheduled CODEOWNERS runs apply at `33 2-23/4 * * *`: 02:33, 06:33,
10:33, 14:33, 18:33, and 22:33 UTC every day. This is two hours after the existing
`Repository Management - Terraform Sync` slots (`repository-management-sync.yml`,
`33 */4 * * 1-5`), with weekend runs retained for an
every-four-hours cadence. Concurrency queues runs without cancelling an active
writer. CODEOWNERS has no separate repository-variable enable gate. Disable the
workflow through the normal operator controls when scheduled writes must stop.
There is no Bicep metadata-backfill mode.
The retained BAMI activation gate applies only to the separate test-tenant job.
`plan_only=true` also prevents that job from writing variables.
The initial metadata adoption required a pause until the target governance
tests and generated ownership rules agreed. Both changes are now merged;
check current workflow state and obtain approval for any pause or resumption.

## Operator setup and rollout

**Metadata rollout prerequisites are merged:**
[Azure/bicep-registry-modules#7349](https://github.com/Azure/bicep-registry-modules/pull/7349)
and [#113](https://github.com/Azure/azure-verified-modules-tools/pull/113)
provide compatible governance tests and the metadata ownership rule.
Recheck current main and workflow state before an approved run.
`AVM_CODEOWNERS_SYNC_ENABLED` was removed, so setting it to `false` does not
pause writes. Disabling and re-enabling the workflow require operator approval;
this documentation does neither. See the [rollout plan](metadata-rollout.md).

- Use the existing `avm` environment's `AVM_APP_CLIENT_ID` and
  `AVM_APP_PRIVATE_KEY`. Restrict that environment to trusted tools `main`.
  The existing AVM App must be installed on the target with Contents and Pull
  requests write permissions. Its runtime token is restricted to that repository;
  the workflow's own `GITHUB_TOKEN` retains Contents read only.
- Every applicable protection rule must already permit the AVM App integration
  (`1049636`) to bypass through pull requests. No Administration permission,
  self-approval, ruleset edit, normal auto-merge, human PAT, or alternate identity
  is used. An unavailable bypass fails the run. Initial metadata backfill uses
  only this existing authorized App bypass; this policy adds no bypass actors.
- Keep required code owner reviews enabled on the target branch and ensure
  both `azure-verified-modules-engineering-owners` and
  `azure-verified-modules-module-owners` are visible teams with explicit
  repository write access. CODEOWNERS selects reviewers but does not itself
  establish review enforcement.
- Merge [Azure/bicep-registry-modules#7343](https://github.com/Azure/bicep-registry-modules/pull/7343)
  before automatic merging can succeed; runtime enforces this prerequisite.
- Ensure every named owner and the shared team have the repository write access
  GitHub requires for CODEOWNERS. Invalid-owner diagnostics must be resolved by
  authorized operators or corrected in the source CSVs. The sync never drops
  rejected individuals or changes access to make a merge succeed.

A production workflow invocation or configuration change requires operator
approval. Development and local regression tests do not dispatch this workflow,
modify rulesets, or synchronize the target.

## Change and merge guards

Both automation entry points use `Invoke-RepositoryFileSync` in the existing
shared library directory, in `repository-sync/scripts/lib/RepositoryFileSync.ps1`.
The Terraform driver still calls
`Invoke-AvmPreCommitForRepository`, which supplies its original preparation and
upgrade handling from `AvmPreCommit.ps1`. CODEOWNERS loads the shared library
directly, without importing or running the Terraform adapter, and supplies the
rendered file and its static-content/owner-diagnostics validation hook.

Clone, Git diff, branch/commit/push, candidate creation/reuse, and app merge are
implemented once there. Both use the existing `Invoke-GitHubCliWithRetry` and
`Invoke-CommandWithRetry` transport. Its opt-in literal-argv mode uses
`Avm.Authoring`'s `Invoke-AvmProcess`; existing legacy retry callers retain their
behavior. Repository file reads and blob checks use the shared `RepoTree.ps1`
helpers. No separate CODEOWNERS API, retry, diff, or publication engine exists.

The original Terraform contract is covered directly:

| Contract | Preserved behavior |
| --- | --- |
| Return value | Exactly `IssueLog` and `HasChanges`, with the caller's issue array retained |
| Preparation | Legacy `.avm` file handling, managed-file upgrade decision, and one `AVM1050` module-update retry |
| No change / plan | No candidate or remote writes; ordinary plans return before staging |
| Publication | Five transient clone retries, timestamped branch, original bot author, commit/title/body and `[skip ci]` |
| Merge | Squash/app bypass, original subject/empty body, branch deletion, and existing merge retry policy |
| Failure | Preparation/publication errors remain failures; cleanup errors warn without replacing the primary outcome |

`Avm.Authoring` is imported before the shared transport first runs, including
in a fresh PowerShell process. Intentional changes from the original publisher
are literal-argv Git/CLI calls, disposable-clone credential/hook configuration
instead of global authentication setup, a 300-second per-command transport
timeout, and exact-head `--match-head-commit` merging. Full candidate/base/tree/API verification is explicitly opt-in with
`-VerifyCandidate`; ordinary Terraform sync does not acquire the Bicep CODEOWNERS
prerequisites. Terraform metadata backfill now adds only missing-file preparation
before normal pre-commit. It uses the same installed authoring, management
steps, publisher options and authorized merge as ordinary Terraform sync.

CODEOWNERS opts into that verification and a sparse
default-branch checkout limited to its managed file, a stable branch, strict dry
runs, retained branch, and target-only app identity. There is no separate
Terraform metadata review-only lane and no Bicep workflow backfill adapter.
Neither path
checks out an existing candidate head. Git credential/hook configuration is
confined to the disposable clone rather than the user's global settings.

Compatibility tests use mocked remote APIs and a fresh `pwsh -NoProfile` local
Git probe. They do not establish live Terraform repository-sync or current
GitHub App/branch-policy behavior, or behavior on a transport operation exceeding
that timeout; production verification still requires
operator approval.

No branch or pull request mutation happens in plan-only mode or when main already matches. On apply,
the only branch is `avm-bot/bicep-codeowners-sync`, with at most one open candidate.
Existing candidate and commit authors must be the authenticated AVM App bot.
Candidates with auto-merge already enabled are rejected before any head update,
so synchronization cannot inadvertently advance a separately configured automatic merge.
Updates retain the old head and current main as ancestors and never force-push
or delete the branch. Unexpected user work is rejected, not overwritten.

Before bypass merging, the script checks exact repository IDs/names, main,
app/author identity, complete changed-file and commit pagination, the generated
blob and tree, current base/head SHAs, and GitHub's CODEOWNERS diagnostics for
that immutable head. It requests only `--squash --admin --match-head-commit`.
There is no approval or credential fallback. The merged actor, commit, parent,
tree, changed-file scope, and persisted main content are verified afterward.
GitHub pins the merge head atomically; an observed concurrent base update causes
failure and requires a fresh run, never an automatic rollback.

Offline regression commands are `.\build.ps1 test-repository-management` and
`.\build.ps1 pre-commit`. Internal team rollout/access documentation should also
be updated in
[Azure-Verified-Modules-Docs](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs)
when operators enable this workflow.
