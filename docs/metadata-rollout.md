# Module metadata rollout

**Status: review findings resolved; current hosted checks and operator approval
are required before rollout. No rollout operations have been performed.**
State last checked on 2026-09-15. Recheck each change immediately before merging.
This document is a plan, not approval to run production commands.

## What is being deployed

- Bicep receives 572 `metadata.json` files directly through its repository change.
  The Bicep Sync workflow does not create them.
- Terraform creates missing files through its existing sync workflow. Existing
  metadata is never overwritten, and no intermediate approval file is required.
- The catalog workflow reads module metadata and registry information, then
  proposes updated CSV/JSON indexes and tier lists for review.
  CSV outputs use `test-` filenames in the existing index folder; canonical CSVs
  remain unchanged. The new JSON catalog keeps `v1/modules.json`.
- Engineering owners must review metadata changes. The existing AVM App bypass
  is retained; this plan does not grant a new bypass or permission.
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
| Safety gate | [Disable Bicep Sync](../.github/workflows/repository-management-bicep-sync.yml) with operator approval | Required before either tools change merges | Removing the old enable-variable gate can activate six scheduled apply runs per day. Keep the workflow disabled until every change below is merged. |
| 1 | [Azure/Azure-Verified-Modules#2929: pipeline template](https://github.com/Azure/Azure-Verified-Modules/pull/2929) | Open; reported checks passed | Makes future generated Bicep pipelines exclude metadata-only publishing. |
| 2 | [#113: metadata implementation](https://github.com/Azure/azure-verified-modules-tools/pull/113) | Open; Opus follow-up and local gate passed | Makes the schemas available before Bicep files reference them. Bicep Sync must already be disabled. Require fresh full hosted checks before merging. |
| 3 | [Azure/bicep-registry-modules#7349: Bicep files and release guards](https://github.com/Azure/bicep-registry-modules/pull/7349) | Open; merge blocked pending completion of requirements | Adds metadata, its engineering-only ownership rule, compatible governance tests, and existing pipeline exclusions together. |
| 4 | [#120: engineering review for metadata](https://github.com/Azure/azure-verified-modules-tools/pull/120) | Open; conflicts resolved and local gate passed | Makes both tools generators preserve the new ownership rule, after the Bicep governance tests accept it. Obtain fresh checks after earlier tools changes merge. |

**Do not run the new Bicep generator before the Bicep repository change.** The
old governance tests reject the new final metadata rule and would fail across
all modules. Conversely, the old tools generator rejects the new target
CODEOWNERS. The mandatory pause covers both incompatible combinations.

Do not treat a successful CodeQL or CLA check as a completed build. Every required
check must have run successfully against the exact head being merged, with
required human approvals satisfied. Resolve outstanding merge conflicts and
address confirmed Opus findings first.
If an earlier merge causes conflicts in a later change, keep automation paused,
resolve the later branch, and obtain fresh checks before continuing.

## Before merging

Obtain operator approval for the merge/run window and for any pause or enable
operation below. Record the current workflow states and relevant variable values
so they can be restored deliberately.

- Disable `repository-management-bicep-sync.yml` in the tools repository before
  either tools change merges, even if its old enable variable appears absent.
  Verify the workflow is disabled and keep it disabled until both the Bicep
  governance tests and the tools generator accept the same ownership rules.
- Disable Terraform Sync for the merge window if its automatic writes must
  pause. There is no pause variable; disabling also prevents manual dispatch.
  Re-enabling requires approval covering automatic applies as well as trials.
- Wait for active writers to finish and ensure queued writers cannot run during
  the pause. Do not cancel an active state writer or break its lease.
- The catalog workflow has no enable variable. Once merged and enabled, its
  daily schedule can publish review changes for preview CSVs, JSON, and tiers.
  Disable it until ready if an operator-controlled first run is required.
- Check the protected `avm` environment, the existing App installation, and
  target permissions. The engineering team needs the access GitHub requires for
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

Ordinary installed authoring commands receive the new metadata checks through
a separately approved Avm.Authoring release. Merging tools does not update
users' installed module. Migration and repository creation load the trusted
tools checkout directly, so they do not require that release first.

## Bicep file adoption and CODEOWNERS

Follow the merge order above: tools schemas first, then the Bicep files,
governance tests and ownership rule, then the matching tools generator.
Keep Bicep Sync disabled throughout.

Confirm that all 572 intended files are present, including complete owner lists.
Keep empty owners genuinely empty. Nondeprecated unowned modules are Orphaned;
Deprecated modules retain their prior status. The 14 uninstrumented,
unpublished children legitimately omit telemetry under BCPFR4.

The change must not alter `main.bicep`, compiled templates, or version files.
Metadata-only edits must not select module releases. Mixed source/version edits
must still follow the normal release rules. Preserve the known budget and
Resource Graph telemetry values; correcting those belongs to a normal release.

After all listed changes are merged and the tools template, target CODEOWNERS,
and Bicep governance tests agree, obtain explicit approval to re-enable Bicep
Sync. That approval must include scheduled applies, not just the next dry run.
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

Before the implementation is merged, `$ref` can be the metadata feature branch
for the metadata-only trial, provided the protected environment allows it. The
metadata mode loads that checkout rather than relying on a Gallery release.

### Establish the review rule

After the ownership-policy change is merged, check the example repository's
current CODEOWNERS. If it has not adopted the engineering-only rule, run an
ordinary sync plan first:

```powershell
gh workflow run repository-management-sync.yml --repo $tools --ref main `
    -f repositories=$module -f plan_only=true -f sync_project_items=false
```

Ordinary sync includes GitHub/Azure management planning. Inspect all proposed
changes. Only after approval, repeat with `plan_only=false` to adopt the
ownership rule. Do not treat this ordinary apply as metadata-only work.

Confirm the final matching rule is:

```text
metadata.json @Azure/azure-verified-modules-engineering-owners
```

No later rule may replace it, and no alternative owner may satisfy it. Verify
root, child, and deeper metadata paths as well as required code-owner approval.

### Preview metadata creation

```powershell
gh workflow run repository-management-sync.yml --repo $tools --ref $ref `
    -f repositories=$module -f metadata_backfill=true -f plan_only=true `
    -f metadata_update_source=false -f sync_project_items=false
```

**Proceed only if:** the intended repository is selected; the run uses the
selected checkout's metadata code; changes are missing `metadata.json` files
only; existing files are unchanged; and Azure state/settings, ordinary
formatting/managed files, and project updates are skipped.

### Create the reviewable change

After inspecting the dry run and receiving approval:

```powershell
gh workflow run repository-management-sync.yml --repo $tools --ref $ref `
    -f repositories=$module -f metadata_backfill=true -f plan_only=false `
    -f metadata_update_source=false -f sync_project_items=false
```

This opens a file change; it does not automatically merge it. Inspect names,
descriptions, canonical types, owner handles, tier, and telemetry identifiers.
Require normal review/approval or the already-authorized App process; do not
self-approve or introduce new bypasses.

After the change is merged, repeat the dry run. It should produce no metadata
changes. If the completed backfill branch still exists, the tool deliberately
defers it: inspect and remove that specific completed branch through normal
approved controls before retrying. Never force-update someone else's work.

## Expand Terraform in small groups

After the example passes, select a small explicit comma-separated repository
list. Adopt and verify the engineering-only CODEOWNERS rule on every target
before creating metadata. Use the same plan-then-apply sequence, with source updates disabled.
Include a resource module, a pattern module, and a repository with children.
Inspect every failed module rather than widening the run immediately.

Missing source information is a stop for that repository. Correct the existing
data or author the missing metadata values directly; never invent an owner,
canonical type, or telemetry identifier just to satisfy validation. Keep
`repositories=All` for a separately approved later run.
Disable Terraform Sync again if automatic writes must stop between batches.
Re-enable it only with approval covering normal automatic applies.

## Preview and publish the catalog

Start in `dual-source` for both ecosystems. It uses valid module metadata and
retains existing rows for modules that do not yet have it. Publication writes
the six `test-*.csv` previews beside the originals, not over them.
The catalog workflow does not trigger metadata backfill.

```powershell
gh workflow run module-metadata-sync.yml --repo $tools --ref main `
    -f plan_only=true -f bicep_mode=dual-source -f terraform_mode=dual-source
```

Download the `module-metadata-catalog` artifact. Check:

- All six `test-` CSVs retain their required columns and expected rows, and no
  canonical CSV is included in the publication write list.
- Child CSV `AlternativeNames` and `Comments` are unchanged, including blank
  cells. They must not be replaced with the parent's values.
- `v1/modules.json` includes every owner, distinct implementations, and children
  with inherited ownership/tier. Check representative deprecated/unowned modules.
- The migration report explains every missing/unresolved module and parity gap.
- Tier changes are expected. Defaulting metadata to `maintained` must not
  accidentally downgrade a known core module's governance.
- Output files and destinations match the central configuration, and publication
  hashes/bases are complete. Errors or partial API results are not publishable.

**Review the preview data before the later CSV cutover.** The review snapshot showed
488 of 508 resource display names and all 508 resource descriptions changing,
plus 45 of 48 pattern names and all 48 pattern descriptions. The new values come
from current Bicep source literals, not the older index wording. These are large
text changes even though metadata-only edits do not publish modules.

Recovered owners can move formerly Orphaned modules to Available. Genuinely
unowned modules stay Orphaned and Deprecated modules stay Deprecated. The six
CSVs also gain `Tier` and `CanonicalType`. Compare fresh output against its
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

Catalog publication opens updates in the public docs and tools repositories;
neither is automatically merged. Review both, especially tier membership.
Cross-repository publication is not atomic: if one succeeds and the other fails,
inspect both before retrying rather than assuming neither changed.

## Replace the live CSVs later

A separate reviewed change will remove the `test-` output prefixes and replace
the canonical CSVs after the previews are accepted. Keep existing consumers on
the original files until then. Complete outstanding preview publication reviews
and collect a fresh snapshot after changing the manifest; old bundles are invalid.
This CSV replacement is separate from each ecosystem's metadata-only cutover.

## Finish the transition

Track the agreed 60-day compatibility window separately for Bicep and Terraform.
Do not switch simply because the calendar date has arrived.

`metadata-only` requires no missing or unresolved entries, including legacy
proposals, retired modules, and repositories without source. Decide explicitly
how those records are represented; do not delete rows to manufacture a clean
report. Run a metadata-only preview for one ecosystem before changing its
steady-state mode.

The current workflow's scheduled defaults remain `dual-source`; a manual
metadata-only run does not persist that choice. A reviewed configuration/workflow
change is required to make the later cutover permanent.

Retire manual metadata sources and old publication automation only after the
replacement outputs and consumers are verified. Then follow the
[migration cleanup instructions](../repository-management/module-metadata/README.md#removing-migration-after-reconciliation)
to remove the one-off scripts and sync switches, retaining normal authoring,
new-repository initialization, schemas, and catalog generation.
Update issue templates and the
internal [Azure-Verified-Modules-Docs](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs)
runbook before declaring rollout complete. Add to an existing open documentation
change where possible; record approved operators, run links, and recovery steps
there rather than copying generated catalogs.

## Stop and recovery rules

Stop on missing/stale checks, review findings, unexpected files, overwritten
metadata, truncated collection, unexplained row loss, owner omissions,
unexpected tier moves, or a release selected by metadata-only changes.

Pause the relevant automation first. Keep run links, logs, artifacts, and commit
IDs. Correct data/tooling and generate again from fresh inputs. If an applied
change must be reverted, revert only its reviewed commits; do not bulk-delete
metadata or restore an old CSV over newer module-owned data.

Keep engineering-review protection and metadata-only release exclusions in
place during recovery unless their own separate defect is being corrected.
