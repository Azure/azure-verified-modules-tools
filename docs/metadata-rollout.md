# Module metadata rollout

**Status: core tools, Bicep metadata, and single-segment canonical support are
merged. The unused optional Terraform backfill hook has been removed.
Oracle.Database compatibility requires its tooling change and a compatible
authoring release.
Child helper adoption also requires compatible released/installed tooling;
this tools change does not release it or add helper files to module repositories.
The current one-off Terraform migration is agent-led and metadata-only.
Production runs still require explicit operator approval.**
This document is a plan, not approval to run production commands.

## What is being deployed

- Bicep's 572 `metadata.json` files were added directly through its merged
  repository change. The Bicep Sync workflow does not create them.
- Terraform's current one-off migration adds only reviewed `metadata.json`
  files. It uses an inclusion/exclusion inventory and explicit canonical
  decisions because source inference is ambiguous. It preserves valid existing
  metadata and owners, creates no Terraform wiring, and does not run full
  repository sync, settings changes, or Azure operations.
- Terraform Sync does not create missing metadata files. Existing repositories
  use owner-authored files or a reviewed one-off metadata-only migration.
  Ordinary sync still handles managed files, CODEOWNERS, repository/Azure
  management, and normal publication/merge on apply.
- The catalog workflow reads module metadata and registry information, then
  publishes and merges updated CSV/JSON indexes through the existing AVM App.
  Migration diagnostics stay in the workflow artifact, not the repository.
  It does not change tier lists
  or repository configuration.
  Only valid metadata produces rows. Deprecated, unpublished modules are excluded
  with a warning recommending deletion of unused source; nothing is deleted.
  Other source-row removals hold back affected outputs and require an explicit
  override.
  CSV outputs replace the six canonical files in the existing index folder.
  The JSON catalog keeps `v1/modules.json`, including
  selected helper submodules under canonical key `helper`; every generated CSV
  omits those helpers.
- Either engineering owners or module owners can satisfy metadata code-owner
  review. Ordinary sync retains the existing App publication/merge controls;
  this change grants no new bypass or permission.
- Avm.Authoring's metadata commands are permanent authoring tools, with no CSV
  input dependency. Both `pre-commit` and `pr-check` validate local metadata.
  Missing files warn during rollout; invalid existing files fail.
- The unused CSV-based backfill adapter and workflow input have been removed.
  Keep the permanent initializer in new-repository creation.

## Changes and merge order

| Order | Change | Last observed state | Why this order matters |
| --- | --- | --- | --- |
| Prerequisite | [#119: Terraform CODEOWNERS generation](https://github.com/Azure/azure-verified-modules-tools/pull/119) | Merged | Supplies the generator used by the ownership-policy change. |
| Prerequisite | [Azure/bicep-registry-modules#7343](https://github.com/Azure/bicep-registry-modules/pull/7343) | Merged | Required by the existing Bicep CODEOWNERS merge check. |
| 1 | [Azure/Azure-Verified-Modules#2929: pipeline template](https://github.com/Azure/Azure-Verified-Modules/pull/2929) | Merged; current main retains the exclusion | Makes future generated Bicep pipelines exclude metadata-only publishing. |
| 2 | [#113: metadata tooling and ownership](https://github.com/Azure/azure-verified-modules-tools/pull/113) | Merged | Includes schemas and ownership generators; [#120](https://github.com/Azure/azure-verified-modules-tools/pull/120) is closed as superseded. |
| 3 | [Azure/bicep-registry-modules#7349: Bicep files and release guards](https://github.com/Azure/bicep-registry-modules/pull/7349) | Merged | Adds metadata, the two-team ownership rule, compatible governance tests, and existing pipeline exclusions together. |
| 4 | [#125: checkout module import fix](https://github.com/Azure/azure-verified-modules-tools/pull/125) | Merged | Fixed the former metadata-only flow's import dependency. |
| 5 | [#126: full-standard Terraform backfill](https://github.com/Azure/azure-verified-modules-tools/pull/126) | Merged; unused hook now removed | Replaced the metadata-only flow with full normal sync; the optional hook was never used. |
| 6 | [#127: single-segment canonical support](https://github.com/Azure/azure-verified-modules-tools/pull/127) | Merged | Supports pattern/utility canonical names such as `naming`; consumers still need a compatible installed/released authoring schema. |
| Next | [Oracle metadata compatibility](progress/2026-09-17-oracle-metadata-compatibility.md) | Pending review | Supports real `Oracle.Database` ARM types without inventing a Microsoft namespace; adoption requires a compatible authoring release. |
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
so they can be restored deliberately. These workflow controls remain separate
from the current metadata-only migration; that procedure does not dispatch
full sync or perform repository/Azure management.

- Confirm the merged Bicep governance tests and tools generator still accept
  the same ownership rules before authorizing Bicep Sync to resume, if paused.
- Disable Terraform Sync for the merge window if its automatic writes must
  pause. There is no pause variable; disabling also prevents manual dispatch.
  Re-enabling requires approval covering automatic applies as well as trials.
- Wait for active writers to finish and ensure queued writers cannot run during
  the pause. Do not cancel an active state writer or break its lease.
- The catalog workflow has no enable variable. Once merged and enabled, its
  four-hour schedule publishes and merges changes for canonical CSVs and JSON.
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

BAMI routing uses the existing central `testTenant` selections without a global
activation variable. Bicep variable propagation remains manual-only through
`enable_test_tenant_sync`, with `plan_only=false` required for publication.
Normal Terraform sync includes tenant parsing and identity/state operations.
A BAMI-selected repository with an incomplete bundle, untrusted
GitHub context, or pending identity validation stops before file preparation,
including pre-commit and CODEOWNERS. The agent-led migration does not invoke those
operations or bypass their safeguards.

Consumers must have a compatible released Avm.Authoring package installed before
adopting single-segment canonical values, `Oracle.Database` metadata, or child
helper markers. Merging tools, passing local checks, and green hosted CI do not publish a release or
update installed modules. Validators use their packaged schemas, not a runtime
download of the authored `$schema` URL.

Repository creation can load trusted checkout code for preparation. Full
Terraform sync installs and uses the normal released authoring module.
Successful preparation or validation with checkout code does not prove that
installed authoring/CI consumers accept the output. Do not skip normal
pre-commit or substitute checkout commands to bypass the compatible-release
prerequisite.

## Bicep file adoption and CODEOWNERS

> **Update:** Bicep CODEOWNERS synchronization has been removed from the
> `repository-management-bicep-sync.yml` workflow and the codebase (the
> `repository-management/bicep-codeowners-sync/` module is gone). That
> workflow now only runs the BAMI test-tenant variable sync
> (`sync-test-tenant-variables`). The historical notes below describe the
> retired feature and are kept for context only.

The Bicep files, compatible governance tests, ownership rule and tools generator
are already merged. Verify their current state rather than attempting to merge
the old branches again.

Confirm that all 572 intended files are present, including complete owner lists.
Keep empty owners genuinely empty. Nondeprecated, published modules without
owners are Orphaned; unpublished modules remain Proposed regardless of ownership.
Published deprecated modules retain their status; deprecated unpublished modules
are omitted from the generated indexes. The 14 uninstrumented,
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

## Current one-off Terraform migration

The initial canonical review covered 407 approved source-backed module paths
(225 roots and 182 children), with 20 explicit exclusions and no unresolved
canonical choices. These are historical review counts, not a promise of 407 new
files or an updated count after including helpers.
All selected helper submodules, including those previously omitted, now require
valid metadata marked with exact lowercase `canonicalType: "helper"`.
The excluded `test-repo5` root remains excluded.
Preserve valid existing metadata, including naming metadata and owner lists.
Archived repositories remain review-only; missing/proposed repositories and
the private Fabric repository are separate work.

The approved Oracle canonical values are:

- `Oracle.Database/cloudExadataInfrastructures`
- `Oracle.Database/cloudVmClusters`
- `Oracle.Database/autonomousDatabases`, including the approved intended type
  for the unfinished Terraform repository.

Do not invent a `Microsoft.Oracle` namespace or concatenate family and child
ARM types. For example,
`Microsoft.Storage/storageAccounts/Microsoft.Insights/diagnosticSettings` is
invalid. Pattern/utility single names and root-qualified taxonomy remain
distinct from resource types.

After approval and the compatible-release prerequisite, work from the reviewed
module-path inventory and supplied values. Validate existing metadata and add
only missing `metadata.json` files on included paths, using the permanent
authoring commands. Invalid existing metadata is a stop, not a reason to
overwrite it. Review the resulting metadata-only diffs and existing ownership
protections before publication.

The helper marker is child-only for both ecosystems and all resource, pattern,
and utility families. It does not introduce a new module kind or a synthetic
ARM type. Helpers keep the required schema/display/description fields and
inherit root owners. Their telemetry prefix is optional; any supplied prefix is
preserved and validated normally. Catalog JSON retains their stable
repository/module-path identities and family `moduleType` with null
`providerNamespace` and `resourceType`; no generated CSV includes helpers.
Existing helper rows in source CSVs still require the explicit removal override.
This supersedes only the helper omission policy, not repository access or
archived/missing/private restrictions.
The inventory and actual migration data stay outside the packaged module.
Normal authoring checks validate metadata on every module root and child.
Missing files warn during rollout; invalid existing files fail. Initialize
missing files with `avm metadata initialize` before adopting this authoring
release.

This procedure creates no `main.metadata.tf` or other Terraform wiring and does
not run full repository sync, managed-file updates, settings changes, App
authentication, or Azure operations. It introduces no execution switch, runner,
automatic merge path, release exception, or access-gate change.

## Terraform repository sync

Discovery reads validated root `metadata.json` from each repository's default
branch, not a tools-local inventory CSV. Missing metadata warns and leaves the
repository eligible for ordinary sync, but skips direct collaborator cleanup;
invalid metadata or API failures exclude the affected repository. GitHub
archive state is authoritative. Sync does not create missing metadata or offer
a `metadata_backfill` input. Use reviewed, owner-authored files for adoption,
not repository sync as a metadata migration tool.

Normal managed files, formatting, CODEOWNERS, repository/Azure management,
tenant gates, and selected project synchronization still run. A plan-only run
does not publish changes; an apply uses the existing standard publication and
merge controls. Production runs still require separate operator approval.

## Preview and publish the catalog

Catalog entries and CSV rows come only from valid module metadata. There are no
ecosystem mode options or full legacy-row fallback. Publication replaces
the six canonical CSV files; it no longer writes `test-*.csv` previews.
The catalog workflow never writes module metadata files.

```powershell
$tools = 'Azure/azure-verified-modules-tools'
gh workflow run module-metadata-sync.yml --repo $tools --ref main `
    -f plan_only=true
```

Generation holds back affected outputs, and publication enforces those holds,
if a source CSV row would be removed without verified deprecated/unpublished
evidence. The comparison uses module implementation identities, not just row counts:
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

- All six canonical CSVs retain their required columns and expected rows, and no
  `test-` CSV is included in the publication write list.
- Child CSV `AlternativeNames` and `Comments` are unchanged, including blank
  cells. They must not be replaced with the parent's values.
- `v1/modules.json` includes every owner as a `handle`, `type`, and nullable
  `displayName` object, distinct implementations, and children with inherited
  ownership. `user` display names are GitHub profile names; `team` display names
  are GitHub team descriptions. Check representative user, team,
  deprecated, and unowned modules.
- The artifact-only migration report explains every missing/unresolved module and parity gap.
  Its `sourceCsvRows` contains the source identity snapshots, `csvRowRemovals`
  lists other removed `sourceFile`, `moduleName`, and `repoURL` values, and
  `csvRowRemovalsForced` records whether generation used the override.
  `excludedModules` retains validated deprecated/unpublished records; only those
  exact identities can be removed without force. Review their repository/module
  warnings and deletion recommendations separately; no source deletion is automated.
- Deprecation reflects Bicep `DEPRECATED.md` and descendants, or the Terraform
  repository archived flag. Existing Deprecated values remain deprecation signals;
  published modules remain indexed and unpublished ones are excluded. The approved
  MAR registration mirror is preserved independently.
- Output files and destinations match the central configuration, and publication
  hashes/bases are complete. Errors or partial API results are not publishable.
  Publication rechecks source-row evidence against actual source CSVs on the
  unchanged main-branch base before writes. Force cannot bypass that check,
  invalid metadata, other validation, `WhatIf`, or approval requirements.

For a manual `plan_only=true` run, review the CSV change table and unified
diffs in the run summary. The `module-metadata-csv-diff` artifact always
contains the complete `all-csv.diff`, one patch per CSV, and exact `before/`
and `after/` copies even when the diff is too large to render inline.

**Review fresh data before publication.** The earlier preview snapshot showed
488 of 508 resource display names and all 508 resource descriptions changing,
plus 45 of 48 pattern names and all 48 pattern descriptions. The new values come
from current Bicep source literals, not the older index wording. These are large
text changes even though metadata-only edits do not publish modules.

Recovered owners can move published, formerly Orphaned modules to Available.
Nondeprecated unpublished metadata-backed modules remain Proposed even without owners.
Published unowned modules stay Orphaned and prior Deprecated status is preserved
for matching published metadata-backed entries. Deprecated unpublished entries
are excluded with actionable warnings. Rows without metadata are
subject to the removal guard, not silently retained. The six
CSVs keep their existing columns unchanged; no new column (such as a
`CanonicalType` or tier column) is added. Compare fresh output against its
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
`plan_only=false`. Scheduled runs publish and merge while the workflow is
enabled; the manual plan-only default does not apply to scheduled events.
The cron `33 1-23/4 * * *` starts at 01:33, 05:33, 09:33, 13:33, 17:33, and
21:33 UTC, between the tools repository's Terraform and Bicep sync starts.
Different start times do not guarantee non-overlapping runtimes.

Catalog publication opens and squash-merges updates only in the public docs
repository through the existing AVM App and verifies the merged head. It does
not publish tools repository settings or tier changes.

## Canonical CSV cutover

The manifest now uses matching `file` and `sourceFile` names for the six CSVs.
Existing consumers keep using those original paths. Collect a fresh snapshot
after changing the manifest; old preview bundles are invalid.
The same source-row guard applies after replacement, when source and destination
are the same file. Changing filenames does not enable force or change the baseline.
Removal of the old preview files is separate:
[Azure/Azure-Verified-Modules#2952](https://github.com/Azure/Azure-Verified-Modules/pull/2952)
must follow the tools filename cutover.

## Finish the transition

There is no later mode switch or compatibility-window setting. Resolve every
missing or unresolved entry before declaring migration complete. Existing source
CSV proposals, retired modules, and repositories without source block default
generation if they have no metadata-backed replacement. Decide explicitly how
they are represented or whether their removal is intentional; do not use force
to hide unexplained omissions. Proposal approval and repository creation remain
separate processes and do not create catalog entries before valid metadata exists.

Retire manual metadata sources and old publication automation only after the
replacement outputs and consumers are verified. The unused backfill scripts and
workflow switch have already been removed; retain normal authoring,
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
IDs. In ordinary full sync, a file preparation failure does not undo earlier
repository/Azure management; inspect those results before retrying. The current
metadata-only migration does not perform those management steps. Correct
data/tooling and generate again from fresh inputs. If an applied
change must be reverted, revert only its reviewed commits; do not bulk-delete
metadata or restore an old CSV over newer module-owned data.

Keep engineering-review protection and metadata-only release exclusions in
place during recovery unless their own separate defect is being corrected.
