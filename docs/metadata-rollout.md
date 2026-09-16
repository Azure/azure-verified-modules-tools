# Module metadata rollout

**Status: core tools and Bicep metadata changes are merged. The full-standard
Terraform backfill follow-up requires review and fresh hosted checks.
Production runs still require explicit operator approval.**
This document is a plan, not approval to run production commands.

## What is being deployed

- Bicep's 572 `metadata.json` files were added directly through its merged
  repository change. The Bicep Sync workflow does not create them.
- Terraform's manual, default-off `metadata_backfill` input creates missing
  files before normal pre-commit. This is full repository sync, including
  managed files, formatting, CODEOWNERS, repository/Azure management and normal
  publication/merge on apply. Existing metadata is never overwritten, and no
  intermediate approval file is required.
- The catalog workflow reads module metadata and registry information, then
  proposes updated CSV/JSON indexes for review. It does not change tier lists
  or repository configuration.
  Only valid metadata produces rows; removals from source CSVs fail by default
  and require an explicit override.
  CSV outputs use `test-` filenames in the existing index folder; canonical CSVs
  remain unchanged. The new JSON catalog keeps `v1/modules.json`.
- Either engineering owners or module owners can satisfy metadata code-owner
  review. Backfill apply uses the already-authorized standard AVM App merge
  process, not a separate human-review-only lane. No new bypass or permission
  is granted; operator approval must cover the full sync scope.
- Avm.Authoring's metadata commands are permanent authoring tools, with no CSV
  input dependency. Both `pre-commit` and `pr-check` validate local metadata.
  Missing files warn during rollout; invalid existing files fail.
- CSV conversion and backfill-only inference are isolated in the temporary
  `repository-management/module-metadata` directory. Keep the permanent
  initializer in new-repository creation after the migration is removed.

## Changes and merge order

| Order | Change | Last observed state | Why this order matters |
| --- | --- | --- | --- |
| Prerequisite | [#119: Terraform CODEOWNERS generation](https://github.com/Azure/azure-verified-modules-tools/pull/119) | Merged | Supplies the generator used by the ownership-policy change. |
| Prerequisite | [Azure/bicep-registry-modules#7343](https://github.com/Azure/bicep-registry-modules/pull/7343) | Merged | Required by the existing Bicep CODEOWNERS merge check. |
| 1 | [Azure/Azure-Verified-Modules#2929: pipeline template](https://github.com/Azure/Azure-Verified-Modules/pull/2929) | Merged; current main retains the exclusion | Makes future generated Bicep pipelines exclude metadata-only publishing. |
| 2 | [#113: metadata tooling and ownership](https://github.com/Azure/azure-verified-modules-tools/pull/113) | Merged | Includes schemas and ownership generators; [#120](https://github.com/Azure/azure-verified-modules-tools/pull/120) is closed as superseded. |
| 3 | [Azure/bicep-registry-modules#7349: Bicep files and release guards](https://github.com/Azure/bicep-registry-modules/pull/7349) | Merged | Adds metadata, the two-team ownership rule, compatible governance tests, and existing pipeline exclusions together. |
| 4 | [#125: checkout module import fix](https://github.com/Azure/azure-verified-modules-tools/pull/125) | Merged | Fixed the former metadata-only flow's import dependency. |
| Next | [Full-standard Terraform backfill](progress/2026-09-16-standard-metadata-backfill.md) | Pending review | Replaces the metadata-only flow with full normal sync and standard merge; removes Terraform source-reader generation. |
| After data adoption and CSV cutover | [Azure/Azure-Verified-Modules#2936: metadata maintenance processes](https://github.com/Azure/Azure-Verified-Modules/pull/2936) | Draft | Updates ownership, orphaning, adoption, and generated-index processes once the new sources and review protections are in use. |

The initial tools/Bicep compatibility window is complete because both changes
are merged. Do not infer current workflow enablement from that fact: verify
live state before an approved run. This Terraform follow-up does not require
another Bicep metadata merge.

Do not treat a successful CodeQL or CLA check as a completed build. Every required
check must have run successfully against the exact head being merged, with
required human approvals satisfied. Resolve outstanding merge conflicts and
address confirmed Opus findings first.
If an earlier merge causes conflicts in a later change, keep automation paused,
resolve the later branch, and obtain fresh checks before continuing.

## Before a Terraform rollout

Obtain operator approval for the merge/run window and for any pause or enable
operation below. Record the current workflow states and relevant variable values
so they can be restored deliberately.

- Confirm the merged Bicep governance tests and tools generator still accept
  the same ownership rules before authorizing Bicep Sync to resume, if paused.
- Disable Terraform Sync for the merge window if its automatic writes must
  pause. There is no pause variable; disabling also prevents manual dispatch.
  Re-enabling requires approval covering automatic applies as well as trials.
- Wait for active writers to finish and ensure queued writers cannot run during
  the pause. Do not cancel an active state writer or break its lease.
- The catalog workflow has no enable variable. Once merged and enabled, its
  daily schedule can publish review changes for preview CSVs and JSON.
  Disable it until ready if an operator-controlled first run is required.
- Check the protected `avm` environment, the existing App installation, and
  target permissions. Both review teams need the access GitHub requires for
  CODEOWNERS, and code-owner review must be required on target main branches.
  Verify the existing App bypass with an authorized operator; do not assume it
  from an incomplete API response.
- For a Terraform branch trial, verify the environment permits that exact branch.
  Do not broaden environment rules or weaken approval requirements as a shortcut.
- Save the current public index files and repository configuration, and record
  the main-branch commits in tools, the public docs repository, and Bicep.

The Bicep workflow no longer has `AVM_CODEOWNERS_SYNC_ENABLED`. Enabling that
workflow permits its scheduled CODEOWNERS apply runs; it is not a preview-only
switch. This change remains intentional; the required rollout pause uses
GitHub's workflow disable control rather than restoring that variable.

The separate BAMI activation gate, `AVM_BAMI_TEST_TENANT_SYNC_ENABLED`, is
retained. It controls test-tenant/identity propagation, not metadata backfill or
catalog publication. Bicep variable propagation additionally requires the
manual `enable_test_tenant_sync` input. Terraform backfill includes normal tenant
parsing and identity/state operations. A BAMI-selected repository with a disabled gate or pending identity
validation stops before file preparation, including metadata creation.

Ordinary installed authoring commands receive the new metadata checks through
a separately approved Avm.Authoring release. Merging tools does not update
users' installed module. Migration and repository creation load the trusted
tools checkout for metadata creation, so those APIs do not require that release
first. Full Terraform sync still installs and uses the normal released authoring
module. The temporary metadata worker imports checkout code in a separate
PowerShell process without replacing caller commands or changing `PSModulePath`.

## Bicep file adoption and CODEOWNERS

The Bicep files, compatible governance tests, ownership rule and tools generator
are already merged. Verify their current state rather than attempting to merge
the old branches again.

Confirm that all 572 intended files are present, including complete owner lists.
Keep empty owners genuinely empty. Nondeprecated unowned modules are Orphaned;
Deprecated modules retain their prior status. The 14 uninstrumented,
unpublished children legitimately omit telemetry under BCPFR4.

The change must not alter `main.bicep`, compiled templates, or version files.
Metadata-only edits must not select module releases. Mixed source/version edits
must still follow the normal release rules. Preserve the known budget and
Resource Graph telemetry values; correcting those belongs to a normal release.

If Bicep Sync is paused and the tools template, target CODEOWNERS and Bicep
governance tests agree, obtain explicit approval to re-enable it. That approval
must include scheduled applies, not just the next dry run.
Then run its strict dry run:

```powershell
gh workflow run repository-management-bicep-sync.yml `
    --repo Azure/azure-verified-modules-tools --ref main -f plan_only=true
```

Expect no change, or only the intended CODEOWNERS update. A plan never opens or
merges a change. If an apply is needed, obtain approval and use
`plan_only=false`; this ordinary CODEOWNERS apply may merge through the existing
App bypass. It is not a Bicep metadata backfill.

Resolve named-owner diagnostics before relying on successful synchronization.
Do not remove people or loosen review rules to make the run pass.

## First Terraform module

Use `avm-ptn-example-repo` first. The commands below are for an operator to run
after approval; none are executed by writing this plan.
If Terraform Sync was disabled for the merge window, obtain approval to enable
it before dispatching. That also permits its normal scheduled/repository-dispatch
applies; there is no variable-based manual-only mode.

```powershell
$tools = 'Azure/azure-verified-modules-tools'
$module = 'avm-ptn-example-repo'
$ref = 'main'
```

Before the follow-up is merged, `$ref` can be its approved feature branch if the
protected environment allows it. This still runs the full normal sync with
installed authoring; only the metadata worker loads the selected checkout.

The existing metadata-only
[Azure/terraform-azurerm-avm-ptn-example-repo#298](https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo/pull/298)
and its branch are not adopted, overwritten, merged or deleted by this follow-up.
Review that outstanding work before authorizing another production run; resolve
it through the normal operator-approved process, not automatic cleanup.

### Check the review rule in the full sync plan

Normal sync prepares CODEOWNERS in the same file change as metadata. Confirm
the final matching rule is:

```text
metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners
```

No later rule may replace it. Either listed team may provide the code-owner
approval; both are not required. Verify root, child, and deeper metadata paths,
both teams' write access, and the unchanged branch approval requirements.

### Preview metadata creation

```powershell
gh workflow run repository-management-sync.yml --repo $tools --ref $ref `
    -f repositories=$module -f metadata_backfill=true -f plan_only=true `
    -f sync_project_items=true
```

**Proceed only if:** the intended repository is selected; the run uses the
selected checkout's metadata code; metadata creation adds only missing
`metadata.json` files; and existing metadata and authored Terraform readers
are unchanged. Inspect all normal managed-file, formatting, CODEOWNERS,
repository/Azure and project plans too. No `main.metadata.tf` is generated.
Plan-only does not publish a branch or merge a file change.

### Apply through standard sync and merge

After inspecting the dry run and receiving approval:

```powershell
gh workflow run repository-management-sync.yml --repo $tools --ref $ref `
    -f repositories=$module -f metadata_backfill=true -f plan_only=false `
    -f sync_project_items=true
```

**This is an apply, not a request to open a review-only change.** It performs
normal repository/Azure management, runs pre-commit and CODEOWNERS preparation,
then uses the standard timestamped branch, commit/title/body and `[skip ci]`
publication followed by the existing authorized App squash merge with exact-head
matching. Merge behavior and failure handling are unchanged; no extra bypass
or failed-check override is introduced.

Review names, descriptions, canonical types, flat owner handles and telemetry
identifiers in the plan before approving apply. Metadata/script failure stops
file publication, but cannot roll back management steps already applied earlier.
Normal project synchronization still follows its existing input and conditions.
Terraform `-UpdateSource` is unsupported; future telemetry wiring belongs in
MaPoTF and is not part of this rollout.

After the change is merged, repeat the dry run. It should produce no metadata
changes, although ordinary sync may find other drift. There is no special stable
backfill branch or review-deferral path. Never force-update someone else's work.

## Expand Terraform in small groups

After the example passes, select a small explicit comma-separated repository
list. Verify the two-team CODEOWNERS rule on every target and review all normal
sync changes. Use the same full plan-then-apply sequence.
Include a resource module, a pattern module, and a repository with children.
Inspect every failed module rather than widening the run immediately.

Missing source information is a stop for that repository. Correct the existing
data or author the missing metadata values directly; never invent an owner,
canonical type, or telemetry identifier just to satisfy validation. Keep
`repositories=All` for a separately approved later run.
Disable Terraform Sync again if automatic writes must stop between batches.
Re-enable it only with approval covering normal automatic applies.

## Preview and publish the catalog

Catalog entries and CSV rows come only from valid module metadata. There are no
ecosystem mode options or full legacy-row fallback. Publication writes
the six `test-*.csv` previews beside the originals, not over them.
The catalog workflow does not trigger metadata backfill.

```powershell
gh workflow run module-metadata-sync.yml --repo $tools --ref main `
    -f plan_only=true
```

Generation and publication fail by default if a row from a source CSV would be
removed. The comparison uses module implementation identities, not just row counts:
adding another row does not hide a removal, and Terraform provider repositories
with the same module name are distinct. Existing preview-only rows are not protected
by this guard. Missing metadata for an unindexed module is reported and does not
create a row.

Resolve missing metadata first. If particular omissions are intentional and
approved, a manual `plan_only=true` run with `force=true` generates an artifact
for review without publishing. Review every listed removal; force permits all
listed removals for that run. A subsequent publication also needs explicit
`force=true`. Scheduled runs never select force.

Download the `module-metadata-catalog` artifact. Check:

- All six `test-` CSVs retain their required columns and expected rows, and no
  canonical CSV is included in the publication write list.
- Child CSV `AlternativeNames` and `Comments` are unchanged, including blank
  cells. They must not be replaced with the parent's values.
- `v1/modules.json` includes every owner, distinct implementations, and children
  with inherited ownership. Check representative deprecated/unowned modules.
- The migration report explains every missing/unresolved module and parity gap.
  Its `sourceCsvRows` contains the source identity snapshots, `csvRowRemovals`
  lists each removed `sourceFile`, `moduleName`, and `repoURL`, and
  `csvRowRemovalsForced` records whether generation used the override.
- Deprecation reflects Bicep `DEPRECATED.md` and descendants, or the Terraform
  repository archived flag. Existing Deprecated values are preserved during transition.
- Output files and destinations match the central configuration, and publication
  hashes/bases are complete. Errors or partial API results are not publishable.
  Publication rechecks source-row evidence against actual source CSVs on the
  unchanged main-branch base before writes. Force cannot bypass that check,
  invalid metadata, other validation, `WhatIf`, or approval requirements.

**Review the preview data before the later CSV cutover.** The review snapshot showed
488 of 508 resource display names and all 508 resource descriptions changing,
plus 45 of 48 pattern names and all 48 pattern descriptions. The new values come
from current Bicep source literals, not the older index wording. These are large
text changes even though metadata-only edits do not publish modules.

Recovered owners can move formerly Orphaned modules to Available. Genuinely
unowned metadata-backed modules stay Orphaned and prior Deprecated status is
preserved for matching metadata-backed entries. Rows without metadata are
subject to the removal guard, not silently retained. The six
CSVs gain `CanonicalType`, not a tier column. Compare fresh output against its
recorded inputs; these review counts are not permanent expected totals.
The JSON catalog retains family-level aliases/comments for children, while
their existing CSV cells remain separate.

The review comparison also found 508 Bicep `ModuleOwnersGHTeam` cells becoming
empty because deleted teams were replaced with individual owners. The full
owner list is in the JSON catalog; CSV owner columns still expose only the first
two people. Confirm this change is acceptable before replacing the live CSVs.
For 74 deep children, `ParentModule` changes from the family root to the immediate
parent. Confirm consumers accept that relationship; the JSON `familyModule`
still identifies the root. Include both changes in the first-index sign-off.

After approving a manual publication, run the same workflow with
`plan_only=false`. The daily schedule can also publish while the workflow is
enabled; no repository variable is required.

Catalog publication opens updates only in the public docs repository, without
automatic merging. It does not publish tools repository settings or tier changes.

## Replace the live CSVs later

A separate reviewed change will remove the `test-` output prefixes and replace
the canonical CSVs after the previews are accepted. Keep existing consumers on
the original files until then. Complete outstanding preview publication reviews
and collect a fresh snapshot after changing the manifest; old bundles are invalid.
The same source-row guard applies after replacement, when source and destination
are the same file. Changing filenames does not enable force or change the baseline.

## Finish the transition

There is no later mode switch or compatibility-window setting. Resolve every
missing or unresolved entry before declaring migration complete. Existing source
CSV proposals, retired modules, and repositories without source block default
generation if they have no metadata-backed replacement. Decide explicitly how
they are represented or whether their removal is intentional; do not use force
to hide unexplained omissions. Proposal approval and repository creation remain
separate processes and do not create catalog entries before valid metadata exists.

Retire manual metadata sources and old publication automation only after the
replacement outputs and consumers are verified. Then follow the
[migration cleanup instructions](../repository-management/module-metadata/README.md#removing-migration-after-reconciliation)
to remove the one-off scripts and sync switches, retaining normal authoring,
new-repository initialization, schemas, and catalog generation.
Keep source CSV collection and row-retention checks; they are permanent safeguards,
not disposable backfill code.
Update issue templates and the
internal [Azure-Verified-Modules-Docs](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs)
runbook before declaring rollout complete. Add to an existing open documentation
change where possible; record approved operators, run links, and recovery steps
there rather than copying generated catalogs.

## Stop and recovery rules

Stop on missing/stale checks, review findings, unexpected files, overwritten
metadata, truncated collection, unexplained row loss, owner omissions,
unexpected repository-setting changes, or a release selected by metadata-only changes.

Pause the relevant automation first. Keep run links, logs, artifacts, and commit
IDs. A metadata preparation failure does not undo earlier normal repository/Azure
management; inspect those results before retrying. Correct data/tooling and
generate again from fresh inputs. If an applied
change must be reverted, revert only its reviewed commits; do not bulk-delete
metadata or restore an old CSV over newer module-owned data.

Keep engineering-review protection and metadata-only release exclusions in
place during recovery unless their own separate defect is being corrected.
